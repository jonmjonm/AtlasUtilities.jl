# assignments.jl -- the `atlas extract-assignments` subcommand.
#
# Read every map in atlas Atlas1 and write a single wide CSV: one row per map, first column the map name, then
# one column per unit holding the unit's district number in that map.
#
# Which units are the columns:
#   * With `--graph <graph.json>`: the finest units of the dual graph (e.g. precincts), read with the atlas's
#     "levels in graph" parameter, as `atlas relabel` does. Each map's district for a unit is the district of
#     the longest key covering it: the unit itself if its county is split in that map, or the whole county if
#     not. This is the true finest scale, including units whose county is never split.
#   * Without a graph: the first map's nodes, as long as every map has the same node set -- the usual
#     single-level atlas, written exactly as before. If a later map's node set differs (a multiscale atlas,
#     whose maps mix whole counties and split ones), the atlas is read once more to collect every key, and the
#     columns become the finest regions seen in it: a region never split in any map stays one column.
# A node id with several components is written with them joined by `:` (e.g. `MECKLENBURG:052`), as
# `atlas list-nodes` does.
#
# `assignmentMatrix` returns the same table as data (map names, weights, units, and a maps x units matrix of
# districts); `eachAssignmentRow` is the reading both share.
#
# Output is `<atlas-basename>-assignments.csv.gz` (gzip) by default, or `.csv` with `--no-compression`, next to
# the input atlas; skipped (with a message) if the target file already exists, unless `--force`. It is written to
# a temporary file and moved into place only on success, so an error never leaves a partial file behind.

"A later map's node set differs from the first map's: restart, covering the finest regions seen in the atlas."
struct NodeSetChanged <: Exception end

"""
    assignmentMatrix(Atlas1; graph = nothing, quiet = true, cores = Threads.nthreads())
        -> (names, weights, units, unitNames, districts)

Every map's district assignment in atlas `Atlas1`, as data: `districts[i, j]` is the district number of unit `j`
in map `i` (a `Matrix{Int}`, maps x units), `names[i]` and `weights[i]` the map's name and weight, `units[j]` the
unit's node key (as in a `Districting`) and `unitNames[j]` its name as `atlas extract-assignments` writes it (the
key's components joined by `:`).

The units are those of `atlas extract-assignments`: the finest units of the dual graph `graph` if given (read
with the atlas's "levels in graph" parameter); else the first map's nodes when every map has the same ones; else,
for a multiscale atlas, the finest regions seen anywhere in it (reading the atlas a second time). A unit's
district in a map is that of the map's longest key covering it: the unit itself, or the region (e.g. a whole
county) that contains it. Errors name the map and node when a map covers some unit with no key, or has a key
that is not a unit or region of the graph.

The matrix holds `8 * maps * units` bytes (e.g. 800 MB for 100,000 maps of 1,000 units). With `quiet = false`,
a progress bar and a note when the multiscale columns are used. An atlas with no maps gives empty results.
"""
function assignmentMatrix(Atlas1::AbstractString; graph::Union{AbstractString,Nothing} = nothing,
                          quiet::Bool = true, cores::Int = Threads.nthreads())
    names, weights, rows = String[], Float64[], Vector{Int}[]
    result = eachAssignmentRow(String(Atlas1); graph = graph, quiet = quiet, cores = cores,
                               start = units -> (empty!(names); empty!(weights); empty!(rows)),
                               render = (name, weight, districts) -> (name, weight, districts),
                               consume = r -> (push!(names, r[1]); push!(weights, r[2]); push!(rows, r[3])))
    units = result === nothing ? Tuple{Vararg{String}}[] : result.units
    districts = Matrix{Int}(undef, length(rows), length(units))
    for (i, row) in enumerate(rows)
        districts[i, :] = row
    end
    return (names = names, weights = weights, units = units, unitNames = nodeIdString.(units),
            districts = districts)
end

"""
    run_extract_assignments(Atlas1; graph = nothing, compress = true, force = false, quiet = false,
                            cores = Threads.nthreads())

Write `<Atlas1 basename>-assignments.csv[.gz]`: one row per map (map name, then each unit's district number in
that map), with the units of `assignmentMatrix`. See the top of assignments.jl.
"""
function run_extract_assignments(Atlas1::AbstractString; graph::Union{AbstractString,Nothing} = nothing,
                                 compress::Bool = true, force::Bool = false,
                                 quiet::Bool = false, cores::Int = Threads.nthreads())
    Atlas1 = String(Atlas1)
    ext = compress ? ".csv.gz" : ".csv"
    outpath = stripAtlasExt(Atlas1) * "-assignments" * ext
    if isfile(outpath) && !force
        println("atlas extract-assignments: $outpath already exists; pass --force to overwrite.")
        return nothing
    end

    # Written to a temporary file, moved into place only on success. A multiscale restart starts it over.
    tmppath = stripAtlasExt(Atlas1) * "-assignments.tmp" * ext
    io = nothing
    function start(units)
        io === nothing || close(io)
        io = smartOpen(tmppath, "w")
        write(io, "name," * join((csvcell(nodeIdString(u)) for u in units), ",") * "\n")
    end
    local result
    try
        result = eachAssignmentRow(Atlas1; graph = graph, quiet = quiet, cores = cores, start = start,
                                   render = (name, _, districts) -> csvcell(name) * "," * join(districts, ",") * "\n",
                                   consume = row -> write(io, row))
        io === nothing || close(io)
        result === nothing || mv(tmppath, outpath; force = true)
    catch
        io === nothing || close(io)
        rm(tmppath; force = true)
        rethrow()
    end

    if result === nothing
        println("atlas extract-assignments: $Atlas1 has no maps; nothing written.")
    elseif !quiet
        println("Wrote ", result.nmaps, " map(s) to ", outpath)
        result.scale === nothing || println("Columns (", length(result.units), "): ", result.scale, ".")
    end
    return nothing
end

"""
    eachAssignmentRow(Atlas1; graph, quiet, cores, start, render, consume) -> (units, nmaps, scale) or nothing

Read every map of `Atlas1` and produce each one's districts, one per unit (the units of `assignmentMatrix`):
`start(units)` is called first, then `consume(render(name, weight, districts))` for every map in order, with
`render` run in parallel batches. In a multiscale atlas without `graph`, the first pass stops at the first map
whose node set differs; `start` is then called again with the finest regions as units and every map is read
again. Returns the units, the number of maps and a description of the columns (`nothing` when they are simply
the maps' nodes), or `nothing` for an atlas with no maps.
"""
function eachAssignmentRow(Atlas1::String; graph::Union{AbstractString,Nothing}, quiet::Bool, cores::Int,
                           start, render, consume)
    atlas = openAtlas(smartOpen(Atlas1, "r"))
    if eof(atlas)
        close(atlas)
        return nothing
    end
    params = atlas.atlasParam
    first = nextMap(atlas)
    close(atlas)
    pass(districtsOf, units) = (start(units); readAssignmentRows(districtsOf, render, consume, Atlas1, quiet, cores))

    if graph !== nothing
        levels = get(params, "levels in graph", nothing)
        levels === nothing && error("a graph was given, but the atlas has no \"levels in graph\" parameter to say " *
                                    "which graph attributes its node keys are.")
        units = sort!(unique(loadHierarchy(graph, levels).finest); by = nodeIdString)
        known = regionsOf(units)
        source = "the graph $(basename(graph))"
        n = pass(m -> coverDistricts(m, units, known, source), units)
        return (units = units, nmaps = n,
                scale = "the finest units of $(basename(graph)) (levels $(join(levels, ", ")))")
    end

    units = sort!(collect(keys(first.districting)); by = nodeIdString)
    unitSet = Set(units)
    try
        n = pass(units) do m
            Set(keys(m.districting)) == unitSet || throw(NodeSetChanged())
            [m.districting[u] for u in units]
        end
        return (units = units, nmaps = n, scale = nothing)
    catch e
        e isa NodeSetChanged || rethrow()
    end
    # Multiscale: the node set varies from map to map. Cover the finest regions seen in the atlas.
    quiet || println("The maps' node sets differ (a multiscale atlas); using the finest regions seen in the " *
                     "atlas as columns.")
    allKeys = atlasKeys(Atlas1, cores)
    units = sort!(collect(finestKeys(allKeys)); by = nodeIdString)
    n = pass(m -> coverDistricts(m, units, allKeys, "the atlas"), units)
    return (units = units, nmaps = n,
            scale = "the finest regions seen in the atlas (a region never split in any map stays one column; " *
                    "pass --graph for the graph's finest units)")
end

"""`consume(render(m.name, m.weight, districtsOf(m)))` for every map of `Atlas1`, in order (`districtsOf` and
`render` run in parallel batches). Returns the number of maps."""
function readAssignmentRows(districtsOf, render, consume, Atlas1::String, quiet::Bool, cores::Int)
    atlas = openAtlas(smartOpen(Atlas1, "r"))
    mpt, wt = atlas.mapParamType, atlas.weightType
    count = 0
    try
        progress = quiet ? nothing : ProgressUnknown(desc = "Reading district assignments:", spinner = true)
        while !eof(atlas)
            lines = readBatch(atlas.io)
            n = length(lines)
            n == 0 && break
            rendered = Vector{Any}(undef, n)
            parallelDo!(n, cores) do i
                m = parseMap(lines[i], mpt, wt)
                rendered[i] = render(m.name, Float64(m.weight), districtsOf(m))
            end
            foreach(consume, rendered)
            count += n
            progress === nothing || next!(progress; showvalues = [("maps read", count)])
        end
        progress === nothing || finish!(progress; showvalues = [("maps read", count)])
    finally
        close(atlas)
    end
    return count
end

"""Each unit's district in map `m`: that of the longest key of `m` covering it. Errors if `m` has a key that is
not one of `known` (a unit or a region containing units of `source`), or covers some unit with no key."""
function coverDistricts(m, units, known, source)
    for k in keys(m.districting)
        k in known || error("map \"$(m.name)\" has node \"$(nodeIdString(k))\", which is not a unit or region " *
                            "of $source.")
    end
    return [coverDistrict(m, u) for u in units]
end

"The district of the longest key of map `m` that covers unit `u` (`u` itself, or a region containing it)."
function coverDistrict(m, u)
    d = m.districting
    for L in length(u):-1:1
        key = u[1:L]
        haskey(d, key) && return d[key]
    end
    error("map \"$(m.name)\" assigns no district to \"$(nodeIdString(u))\" or to " *
          "any region containing it.")
end

"Every unit in `units` and every region (proper prefix) containing one."
regionsOf(units) = Set(u[1:L] for u in units for L in 1:length(u))

"The keys in `ks` that are not a region containing another key (not a proper prefix of one): the finest."
function finestKeys(ks)
    regions = Set(k[1:L] for k in ks for L in 1:(length(k) - 1))
    return setdiff(ks, regions)
end

"Every node key used by any map of `Atlas1`."
function atlasKeys(Atlas1::String, cores::Int)
    atlas = openAtlas(smartOpen(Atlas1, "r"))
    mpt, wt = atlas.mapParamType, atlas.weightType
    allKeys = Set{Tuple{Vararg{String}}}()
    try
        while !eof(atlas)
            lines = readBatch(atlas.io)
            isempty(lines) && break
            keysets = Vector{Vector{Tuple{Vararg{String}}}}(undef, length(lines))
            parallelDo!(length(lines), cores) do i
                keysets[i] = collect(keys(parseMap(lines[i], mpt, wt).districting))
            end
            foreach(ks -> union!(allKeys, ks), keysets)
        end
    finally
        close(atlas)
    end
    return allKeys
end
