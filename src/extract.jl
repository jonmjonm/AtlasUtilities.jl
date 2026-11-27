# extract.jl -- extracting map data to CSV (`extractMapData`, `mapatlas extract-map-data`).
#
# Read every map in an input atlas and write its map data out as CSV: one CSV
# file per data field, inside a directory named after the atlas (its path with the
# `.jsonl`/`.jsonl.gz`/`.jsonl.bz2` extension stripped). Each map is one row --
# first column the map name, then the field's value (a scalar is one column, a vector
# is one column per entry), and last the map's weight (`map_weight`). A header row
# names the columns.
#
# By default every field already present in the maps' data is extracted. `writers`
# (a `WriterSet`, `--add` on the command line) additionally computes CycleWalk "pushable writer"
# functions (exactly as `addMapData` does -- reconstructing each map's partition on a supplied graph) and
# extracts those too; a writer field that collides with an existing field takes
# precedence (its freshly computed value is written).
#
# Output CSVs are gzip-compressed by default (`.csv.gz`); `compress = false`
# writes plain `.csv`. A field whose output file already exists is skipped unless
# `force = true`. One stream is kept open per output file for the whole pass,
# so each file is opened and closed exactly once.
#
# Alongside the CSVs an `about.md` is written describing the extraction: the source
# atlas name, the extraction date, and the atlas's header info (everything `atlas
# info` shows except the bulky embedded generating script).

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

"""Header for a field's CSV: `name`, then either the bare field (width 1) or
`field_1 … field_w`, then `map_weight`."""
function headerRow(field::AbstractString, width::Int)
    cols = width == 1 ? [field] : ["$(field)_$i" for i in 1:width]
    return "name," * join((csvcell(c) for c in cols), ",") * ",map_weight\n"
end

"""Row for map `name` with field value `val` laid out in `width` columns
(missing/`nothing` becomes empty cells), then the map's `weight`."""
function valueRow(name::AbstractString, val, width::Int, weight::Real)
    cells = val === nothing ? String[] : [string(x) for x in flattenVal(val)]
    length(cells) < width && append!(cells, fill("", width - length(cells)))
    return csvcell(name) * "," * join(cells, ",") * "," * string(weight) * "\n"
end

# ---------------------------------------------------------------------------
# About file
# ---------------------------------------------------------------------------

"""
    writeAboutFile(outdir, Atlas1, atlas, fieldNames; burnIn = 0, maxMaps = 0) -> String

Write an `about.md` into `outdir` describing the extraction: the source atlas name,
the extraction date, and the atlas's header information -- everything `mapatlas info`
shows except the bulky embedded sources -- the generating script, its includes, and
the TOML config (see `atlasHeaderInfo`) -- including
`fieldNames` (the data field names found in the first map, e.g.
`log_spanning_trees`). When `burnIn`/`maxMaps` are nonzero (a `--burn-in`/`--max-maps`
run), a line noting each is added -- `maxMaps` in particular marks the extraction as
partial (see the output files' `-partial` suffix). Returns the path written.
"""
function writeAboutFile(outdir::AbstractString, Atlas1::AbstractString, atlas,
                        fieldNames::AbstractVector{<:AbstractString};
                        burnIn::Int = 0, maxMaps::Int = 0)
    path = joinpath(outdir, "about.md")
    open(path, "w") do io
        println(io, "# ", basename(String(Atlas1)), " — extracted map data")
        println(io)
        println(io, "- **Source atlas:** `", String(Atlas1), "`")
        println(io, "- **Extraction date:** ", string(Dates.now()))
        burnIn > 0 && println(io, "- **Burn-in:** first ", burnIn,
                              " map(s) skipped (`--burn-in ", burnIn, "`).")
        maxMaps > 0 && println(io, "- **Partial extraction:** at most ", maxMaps,
                              " map(s) extracted", burnIn > 0 ? " after burn-in" : "",
                              " (`--max-maps ", maxMaps, "`); output files are ",
                              "suffixed `-partial`.")
        println(io)
        println(io, "Atlas header below (the same information `mapatlas info` prints; the ",
                    "embedded generating script is omitted):")
        println(io)
        println(io, "```")
        print(io, atlasHeaderInfo(atlas, fieldNames))
        println(io, "```")
    end
    return path
end

# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------

"""
    extractMapData(atlas, outdir = <atlas path minus its extension>; writers = nothing, compress = true,
                   force = false, max_maps = 0, cores = Threads.nthreads(), progress = false)
        -> (outdir, written, skipped, nmaps)

Extract the map data of the atlas at `atlas` to per-field CSV files in `outdir` (by default a directory named
after the atlas: its path minus the atlas extension), plus an `about.md` describing the atlas. Every existing
data field is extracted; the fields of `writers` (a [`WriterSet`](@ref)) are computed on each map and extracted
too (a computed field replaces an existing one of the same name). `compress` gzips the CSVs (`.csv.gz`); with
`compress = false` they are plain `.csv`. A field whose output file already exists is skipped, and its writer
not computed, unless `force = true`. `max_maps` (0 = unlimited, the default) stops after extracting that many
maps; when set, output filenames get a `-partial` suffix (before the extension) so a partial run never collides
with a full one's output, and `about.md` notes the limit. `progress` shows a progress bar.

Returns the output directory, the paths `written` (`about.md` first, then a CSV per field), the paths `skipped`
(files that already existed), and the number of maps extracted. An atlas with no maps writes nothing (`written`
is empty); when every CSV already exists, `written` holds only `about.md` and no map is read past the first.
"""
function extractMapData(atlas::AbstractString, outdir::AbstractString = stripAtlasExt(String(atlas));
                        writers::Union{Nothing,WriterSet} = nothing, compress::Bool = true,
                        force::Bool = false, max_maps::Int = 0,
                        cores::Int = Threads.nthreads(), progress::Bool = false)
    max_maps < 0 && error("extractMapData: max_maps = $max_maps must be ≥ 0.")
    Atlas1 = String(atlas)
    outdir = String(outdir)
    addFields = writers === nothing ? String[] : writerFields(writers)
    addedSet = Set(addFields)

    isdir(outdir) || mkpath(outdir)
    # A max_maps run gets its own filenames so it never collides with (or is
    # silently mistaken for) a full extraction's output in the same directory.
    ext = (max_maps > 0 ? "-partial" : "") * (compress ? ".csv.gz" : ".csv")

    written = String[]
    a = openAtlas(smartOpen(Atlas1, "r"))
    if eof(a)
        close(a)
        return (outdir = outdir, written = written, skipped = String[], nmaps = 0)
    end

    # --- set up output streams from the first map ------------------------------
    first = nextMap(a)

    # Always (re)write about.md, regardless of which CSV fields are actually
    # written below -- it should describe the atlas even on a re-run where every
    # target CSV already exists and is skipped.
    push!(written, writeAboutFile(outdir, Atlas1, a, sort(collect(keys(first.data))); maxMaps = max_maps))

    shouldWrite(field) = force || !isfile(joinpath(outdir, field * ext))

    # Field order: existing data keys (sorted, minus any overridden by `writers`),
    # then the writer fields. Only write fields whose file doesn't already exist
    # (unless `force`); compute only the writer fields we will actually write.
    existingFields = sort([k for k in keys(first.data) if !(k in addedSet)])
    activeExisting = [f for f in existingFields if shouldWrite(f)]
    activeAddedNames = [f for f in addFields if shouldWrite(f)]
    activeAddedSet = Set(activeAddedNames)

    # The writers to evaluate, chosen once for the run (and with them the fast path).
    active = isempty(activeAddedSet) ? nothing : writerSubset(writers, activeAddedSet)
    computeAdded(m) = active === nothing ? Dict{String,Any}() : computeWriters(active, m)
    valueOf(m, field, added) = field in addedSet ? added[field] : get(m.data, field, nothing)

    skipped = [joinpath(outdir, f * ext) for f in vcat(existingFields, addFields) if !shouldWrite(f)]

    firstAdded = computeAdded(first)
    # (field, io, width), in output order.
    streams = Tuple{String,IO,Int}[]
    for field in vcat(activeExisting, activeAddedNames)
        val = valueOf(first, field, firstAdded)
        width = length(flattenVal(val))
        # smartOpen selects gzip vs. plain from the filename extension, matching
        # `ext` (.csv.gz vs. .csv), so no codec import is needed here.
        path = joinpath(outdir, field * ext)
        io = smartOpen(path, "w")
        write(io, headerRow(field, width))
        write(io, valueRow(first.name, val, width, first.weight))
        push!(streams, (field, io, width))
        push!(written, path)
    end

    if isempty(streams)
        close(a)
        return (outdir = outdir, written = written, skipped = skipped, nmaps = 0)
    end

    # --- stream the remaining maps --------------------------------------------
    # Per map, parse + compute (writers) + render each field's row in parallel (AtlasIO's
    # `eachMap(f, ...)`), then write the rows to their streams serially in map order.
    #
    # No active writer field means no writer will actually be evaluated this run (either
    # no `writers` were given, or every writer field was skipped as already
    # existing), so `computeAdded` never touches `m.districting` -- read a
    # `MapData` instead of a full `Map` to skip reconstructing it, which otherwise
    # dominates the parse cost (see AtlasIO's `MapData`).
    rowsOf(m) = begin
        added = computeAdded(m)
        [valueRow(m.name, valueOf(m, field, added), width, m.weight) for (field, _, width) in streams]
    end
    each = isempty(activeAddedSet) ? eachMapData : eachMap
    bar = progress ? ProgressUnknown(desc = "Extracting map data:", spinner = true) : nothing
    nmaps = 1
    try
        with_serial_blas() do
            for rows in each(rowsOf, a; max = max_maps == 0 ? typemax(Int) : max_maps - 1, ntasks = cores)
                for k in eachindex(streams)
                    write(streams[k][2], rows[k])
                end
                nmaps += 1
                bar === nothing || next!(bar; showvalues = [("maps written", nmaps)])
            end
        end
        bar === nothing || finish!(bar; showvalues = [("maps written", nmaps)])
    finally
        close(a)
        for (_, io, _) in streams
            close(io)
        end
    end
    return (outdir = outdir, written = written, skipped = skipped, nmaps = nmaps)
end
