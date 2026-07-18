# extract.jl -- the `atlas extract-map-data` subcommand.
#
# Read every map in an input atlas A1 and write its map data out as CSV: one CSV
# file per data field, inside a directory named after the atlas (its path with the
# `.jsonl`/`.jsonl.gz`/`.jsonl.bz2` extension stripped). Each map is one row --
# first column the map name, remaining columns the field's value (a scalar is one
# column, a vector is one column per entry). A header row names the columns.
#
# By default every field already present in the maps' data is extracted. `--add`
# additionally computes CycleWalk "pushable writer" functions (exactly as
# `atlas add` does -- reconstructing each map's partition on a supplied graph) and
# extracts those too; an `--add` name that collides with an existing field takes
# precedence (its freshly computed value is written).
#
# Output CSVs are gzip-compressed by default (`.csv.gz`); `--no-compression`
# writes plain `.csv`. A field whose output file already exists is skipped unless
# `--force` is given. One stream is kept open per output file for the whole pass,
# so each file is opened and closed exactly once.

# ---------------------------------------------------------------------------
# CSV / value helpers
# ---------------------------------------------------------------------------

"""Strip the atlas extension (`.jsonl`, `.jsonl.gz`, `.jsonl.bz2`) from a path."""
function stripAtlasExt(path::AbstractString)
    for e in (".jsonl.gz", ".jsonl.bz2", ".jsonl")
        endswith(path, e) && return String(path[1:(end - length(e))])
    end
    return String(first(splitext(path)))
end

"""A field value as a flat list of cells: a vector spreads across columns, a
scalar is a single column."""
flattenVal(v) = v isa AbstractVector ? collect(v) : Any[v]

"""Quote a CSV cell if it contains a comma, quote or newline (values are numbers,
so this really only matters for map names)."""
function csvcell(s::AbstractString)
    (occursin(',', s) || occursin('"', s) || occursin('\n', s)) || return String(s)
    return '"' * replace(s, '"' => "\"\"") * '"'
end

"""Header for a field's CSV: `name` then either the bare field (width 1) or
`field_1 … field_w`."""
function headerRow(field::AbstractString, width::Int)
    cols = width == 1 ? [field] : ["$(field)_$i" for i in 1:width]
    return "name," * join((csvcell(c) for c in cols), ",") * "\n"
end

"""Row for map `name` with field value `val` laid out in `width` columns
(missing/`nothing` becomes empty cells)."""
function valueRow(name::AbstractString, val, width::Int)
    cells = val === nothing ? String[] : [string(x) for x in flattenVal(val)]
    length(cells) < width && append!(cells, fill("", width - length(cells)))
    return csvcell(name) * "," * join(cells, ",") * "\n"
end

# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------

"""
    run_extract(A1; add, compress, force, config, graph, pop_col, node_col,
                area_col, border_col, edge_perimeter_col, node_data, quiet)

Extract the map data of atlas `A1` to per-field CSV files in a directory named
after `A1` (its path minus the atlas extension). Every existing data field is
extracted; `add` (a writer-function name, or comma-separated / bracketed list) is
additionally computed via the graph described by `config` and/or the column
keyword arguments (see `resolveGraphSpec`) and extracted too. `compress` gzips the
CSVs (`.csv.gz`); with `compress = false` they are plain `.csv`. A field whose
output file already exists is skipped unless `force = true`. `quiet` suppresses the
progress bar.
"""
function run_extract(A1::AbstractString;
                     add::AbstractString = "", compress::Bool = true,
                     force::Bool = false, config::AbstractString = "",
                     graph::AbstractString = "", pop_col::AbstractString = "",
                     node_col::AbstractString = "", area_col::AbstractString = "",
                     border_col::AbstractString = "",
                     edge_perimeter_col::AbstractString = "",
                     node_data::AbstractString = "", vote_cols::AbstractString = "",
                     quiet::Bool = false, cores::Int = Threads.nthreads())
    addNames = isempty(add) ? String[] : parseFunctionNames(add)
    votePairs = parseVotePairs(vote_cols)
    fns = resolveFunctions(addNames, votePairs)   # validate + expand partisan names
    addFields = [desc for (desc, _) in fns]       # actual field names (partisan names expand)
    addedSet = Set(addFields)

    # The graph (and its columns) is only needed when computing `--add` functions.
    g = nothing
    if !isempty(addNames)
        spec = resolveGraphSpec(; config = config, graph = graph, pop_col = pop_col,
                                node_col = node_col, area_col = area_col,
                                border_col = border_col,
                                edge_perimeter_col = edge_perimeter_col,
                                node_data = node_data)
        union!(spec.node_data, Set(voteColumns(votePairs)))   # keep vote columns on the graph
        g = buildGraph(spec)
    end

    outdir = stripAtlasExt(String(A1))
    isdir(outdir) || mkpath(outdir)
    ext = compress ? ".csv.gz" : ".csv"

    atlas = openAtlas(smartOpen(String(A1), "r"))
    mpt, wt = atlas.mapParamType, atlas.weightType
    if eof(atlas)
        close(atlas)
        println("atlas extract-map-data: $A1 has no maps; nothing written.")
        return nothing
    end

    # --- set up output streams from the first map ------------------------------
    first = nextMap(atlas)

    shouldWrite(field) = force || !isfile(joinpath(outdir, field * ext))

    # Field order: existing data keys (sorted, minus any overridden by --add),
    # then the --add functions. Only write fields whose file doesn't already exist
    # (unless --force); compute only the --add functions we will actually write.
    existingFields = sort([k for k in keys(first.data) if !(k in addedSet)])
    activeExisting = [f for f in existingFields if shouldWrite(f)]
    activeAddedNames = [f for f in addFields if shouldWrite(f)]
    activeAddedSet = Set(activeAddedNames)
    activeFns = [(n, f) for (n, f) in fns if n in activeAddedSet]
    treeless = allTreeless(activeFns)   # fast-path decision depends only on activeFns

    computeAdded(m) = isempty(activeFns) ? Dict{String,Any}() :
                      evalWriters(g, m, activeFns; treeless = treeless)
    valueOf(m, field, added) = field in addedSet ? added[field] : get(m.data, field, nothing)

    skipped = [f for f in vcat(existingFields, addFields) if !shouldWrite(f)]
    isempty(skipped) || @info "extract-map-data: skipping existing file(s) " *
        "(use --force to overwrite): " * join(string.(skipped) .* ext, ", ")

    firstAdded = computeAdded(first)
    # (field, io, width), in output order.
    streams = Tuple{String,IO,Int}[]
    for field in vcat(activeExisting, activeAddedNames)
        val = valueOf(first, field, firstAdded)
        width = length(flattenVal(val))
        # smartOpen selects gzip vs. plain from the filename extension, matching
        # `ext` (.csv.gz vs. .csv), so no codec import is needed here.
        io = smartOpen(joinpath(outdir, field * ext), "w")
        write(io, headerRow(field, width))
        write(io, valueRow(first.name, val, width))
        push!(streams, (field, io, width))
    end

    if isempty(streams)
        close(atlas)
        println("atlas extract-map-data: nothing to write (all target files exist; " *
                "pass --force to overwrite).")
        return nothing
    end

    # --- stream the remaining maps in batches ---------------------------------
    # Read serially, then per map parse + compute (--add) + render each field's row
    # in parallel, then write the rows to their streams serially in map order.
    progress = quiet ? nothing :
               ProgressUnknown(desc = "Extracting map data:", spinner = true)
    written = 1
    with_serial_blas() do
        while !eof(atlas)
            lines = String[]
            while length(lines) < BATCH && !eof(atlas)
                push!(lines, readline(atlas.io))
            end
            n = length(lines)
            n == 0 && break

            # rows[i][k] is map i's row string for stream k.
            rows = Vector{Vector{String}}(undef, n)
            parallelDo!(n, cores) do i
                m = JSON3.read(lines[i], Map{mpt,wt})
                added = computeAdded(m)
                rr = Vector{String}(undef, length(streams))
                for (k, (field, _, width)) in enumerate(streams)
                    rr[k] = valueRow(m.name, valueOf(m, field, added), width)
                end
                rows[i] = rr
            end

            for i in 1:n, k in eachindex(streams)
                write(streams[k][2], rows[i][k])
            end
            written += n
            progress === nothing ||
                next!(progress; showvalues = [("maps written", written)])
        end
    end
    progress === nothing ||
        finish!(progress; showvalues = [("maps written", written)])

    close(atlas)
    for (_, io, _) in streams
        close(io)
    end
    quiet || println("Wrote ", length(streams), " file(s) to ", outdir, "/")
    return nothing
end
