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
# Output is `<atlas-basename>-assignments.csv.gz` (gzip) by default, or `.csv` with `--no-compression`, next to
# the input atlas; skipped (with a message) if the target file already exists, unless `--force`. It is written to
# a temporary file and moved into place only on success, so an error never leaves a partial file behind.

"A later map's node set differs from the first map's: restart, covering the finest regions seen in the atlas."
struct NodeSetChanged <: Exception end

"""
    run_extract_assignments(Atlas1; graph = nothing, compress = true, force = false, quiet = false,
                            cores = Threads.nthreads())

Write `<Atlas1 basename>-assignments.csv[.gz]`: one row per map (map name, then each unit's district number in
that map). The units are the finest units of the dual graph `graph` if given, else the first map's nodes when
every map shares them, else the finest regions seen anywhere in the atlas (for multiscale atlases). See the top
of assignments.jl.
"""
function run_extract_assignments(Atlas1::AbstractString; graph::Union{AbstractString,Nothing} = nothing,
                                 compress::Bool = true, force::Bool = false,
                                 quiet::Bool = false, cores::Int = Threads.nthreads())
    Atlas1 = String(Atlas1)
    ext = compress ? ".csv.gz" : ".csv"
    outpath = stripAtlasExt(Atlas1) * "-assignments" * ext

    if isfile(outpath) && !force
        println("atlas extract-assignments: $outpath already exists; ",
                "pass --force to overwrite.")
        return nothing
    end

    # The header (for "levels in graph") and the first map.
    atlas = openAtlas(smartOpen(Atlas1, "r"))
    if eof(atlas)
        close(atlas)
        println("atlas extract-assignments: $Atlas1 has no maps; nothing written.")
        return nothing
    end
    params = atlas.atlasParam
    first = nextMap(atlas)
    close(atlas)

    tmppath = stripAtlasExt(Atlas1) * "-assignments.tmp" * ext
    local written, units, scale
    try
        if graph !== nothing
            levels = get(params, "levels in graph", nothing)
            levels === nothing && error("atlas extract-assignments: --graph was given but the atlas has no " *
                                        "\"levels in graph\" parameter to say which graph attributes its node " *
                                        "keys are.")
            units = sort!(unique(loadHierarchy(graph, levels).finest); by = nodeIdString)
            known = regionsOf(units)
            source = "the graph $(basename(graph))"
            written = writeAssignmentRows(Atlas1, tmppath, units, quiet, cores) do m
                coverRow(m, units, known, source)
            end
            scale = "the finest units of $(basename(graph)) (levels $(join(levels, ", ")))"
        else
            units = sort!(collect(keys(first.districting)); by = nodeIdString)
            unitSet = Set(units)
            try
                written = writeAssignmentRows(Atlas1, tmppath, units, quiet, cores) do m
                    Set(keys(m.districting)) == unitSet || throw(NodeSetChanged())
                    plainRow(m, units)
                end
                scale = nothing
            catch e
                e isa NodeSetChanged || rethrow()
                # Multiscale: the node set varies from map to map. Cover the finest regions seen in the atlas.
                quiet || println("atlas extract-assignments: the maps' node sets differ (a multiscale atlas); " *
                                 "using the finest regions seen in the atlas as columns.")
                allKeys = atlasKeys(Atlas1, cores)
                units = sort!(collect(finestKeys(allKeys)); by = nodeIdString)
                written = writeAssignmentRows(Atlas1, tmppath, units, quiet, cores) do m
                    coverRow(m, units, allKeys, "the atlas")
                end
                scale = "the finest regions seen in the atlas (a region never split in any map stays one " *
                        "column; pass --graph for the graph's finest units)"
            end
        end
        mv(tmppath, outpath; force = true)
    catch
        rm(tmppath; force = true)
        rethrow()
    end

    if !quiet
        println("Wrote ", written, " map(s) to ", outpath)
        scale === nothing || println("Columns (", length(units), "): ", scale, ".")
    end
    return nothing
end

"""Write the CSV for `Atlas1` to `path`: the header (`name`, then `units`), then `rowFor(m)` for every map, in
order (computed in parallel batches). Returns the number of maps written."""
function writeAssignmentRows(rowFor, Atlas1::String, path::String, units, quiet::Bool, cores::Int)
    atlas = openAtlas(smartOpen(Atlas1, "r"))
    mpt, wt = atlas.mapParamType, atlas.weightType
    written = 0
    try
        io = smartOpen(path, "w")
        try
            write(io, "name," * join((csvcell(nodeIdString(u)) for u in units), ",") * "\n")
            progress = quiet ? nothing :
                       ProgressUnknown(desc = "Extracting district assignments:", spinner = true)
            while !eof(atlas)
                lines = readBatch(atlas.io)
                n = length(lines)
                n == 0 && break
                rows = Vector{String}(undef, n)
                parallelDo!(n, cores) do i
                    rows[i] = rowFor(parseMap(lines[i], mpt, wt))
                end
                foreach(r -> write(io, r), rows)
                written += n
                progress === nothing || next!(progress; showvalues = [("maps written", written)])
            end
            progress === nothing || finish!(progress; showvalues = [("maps written", written)])
        finally
            close(io)
        end
    finally
        close(atlas)
    end
    return written
end

"A row when every map has exactly the columns' node set."
plainRow(m, units) = csvcell(m.name) * "," * join((string(m.districting[u]) for u in units), ",") * "\n"

"""A row of each unit's district: that of the longest key of `m` covering it. Errors if `m` has a key that is
not one of `known` (a unit or a region containing units of `source`), or covers some unit with no key."""
function coverRow(m, units, known, source)
    d = m.districting
    for k in keys(d)
        k in known || error("atlas extract-assignments: map \"$(m.name)\" has node \"$(nodeIdString(k))\", " *
                            "which is not a unit or region of $source.")
    end
    buf = IOBuffer()
    print(buf, csvcell(m.name))
    for u in units
        print(buf, ',', coverDistrict(m, u))
    end
    print(buf, '\n')
    return String(take!(buf))
end

"The district of the longest key of map `m` that covers unit `u` (`u` itself, or a region containing it)."
function coverDistrict(m, u)
    d = m.districting
    for L in length(u):-1:1
        key = u[1:L]
        haskey(d, key) && return d[key]
    end
    error("atlas extract-assignments: map \"$(m.name)\" assigns no district to \"$(nodeIdString(u))\" or to " *
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
