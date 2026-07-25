# extractHistogram.jl -- the `atlas extract-map-data-histogram` subcommand.
#
# Like `extract-map-data`, but instead of writing each map's data to a CSV row, it
# accumulates every map's data (after skipping `burn_in` maps) into a
# StreamHistogram `StreamHist` per field -- one `StreamHist` for a scalar field, a
# `Vector{StreamHist}` (one per index) for a vector field. `sortVals` sorts a
# vector field's values ascending before feeding, so histogram `j` holds the `j`-th
# order statistic across maps rather than raw index `j` (index identity is not
# generally comparable across maps -- see e.g. district relabeling).
#
# `mapDataHistograms` is the library entry point (returns the
# `Dict{String,Union{StreamHist,Vector{StreamHist}}}`); `run_extract_map_data_histogram`
# is the CLI driver, which also writes each field's histogram(s) to a pair of files
# (`<field>-histogram.csv[.gz]` + `<field>-histogram.json[.gz]`) in the same output
# directory `extract-map-data` uses. The CSV holds only the exact per-bin edges and
# counts (a plain numeric table for loading straight into a histogram plot in
# Python/Julia); the JSON holds everything else -- per-index summary statistics,
# moment errors, the ASH-density bin counts, and the bin edges again (so the JSON is
# self-contained) -- as a human-readable dictionary keyed by index.

# ---------------------------------------------------------------------------
# Library entry point
# ---------------------------------------------------------------------------

"""
    mapDataHistograms(Atlas1; add, vote_cols, config, graph, pop_col, node_col,
                      area_col, border_col, edge_perimeter_col, node_data,
                      burn_in = 0, max_maps = 0, sortVals = true,
                      cores = Threads.nthreads(), quiet = false, integer = false,
                      bin_range = nothing, bin_num = 50, bins = nothing,
                      moment_powers = [1, 2, 4, 8])
    -> (Dict{String,Union{StreamHist,Vector{StreamHist}}}, Int)

Read every map in atlas `Atlas1` after skipping the first `burn_in` maps,
computing any `add` writer fields (exactly as `extract-map-data`/`add` do -- see
`setupAddComputation`), and accumulate each field's values into a `StreamHist`
(scalar field) or a `Vector{StreamHist}` (vector field, one histogram per index).
`sortVals` sorts a vector field's values ascending before feeding (a no-op for
scalars), so histogram `j` holds the `j`-th order statistic across maps.
`max_maps` (0 = unlimited, the default) stops after accumulating that many maps
past the burn-in.

`integer`, `bin_range`, `bin_num`, `bins`, and `moment_powers` are forwarded to
every `StreamHist` constructed (see `StreamHist`); a bin range is otherwise learned
independently per histogram from its own data. `integer` may also be `:auto`, in
which case each `StreamHist` independently decides integer-ness from its own
learn-phase sample (so a scalar field and a vector field's different indices can
resolve differently); `:auto` requires `bin_range`/`bins` to be left unset (see
`StreamHist`).

Returns the histogram dict alongside the number of maps actually accumulated
(past the burn-in, capped by `max_maps`).
"""
function mapDataHistograms(Atlas1::AbstractString;
                           add::AbstractString = "", vote_cols::AbstractString = "",
                           config::AbstractString = "", graph::AbstractString = "",
                           pop_col::AbstractString = "", node_col::AbstractString = "",
                           area_col::AbstractString = "", border_col::AbstractString = "",
                           edge_perimeter_col::AbstractString = "",
                           node_data::AbstractString = "",
                           burn_in::Int = 0, max_maps::Int = 0, sortVals::Bool = true,
                           cores::Int = Threads.nthreads(), quiet::Bool = false,
                           integer::Union{Bool,Symbol} = false,
                           bin_range::Union{Nothing,Tuple{<:Real,<:Real}} = nothing,
                           bin_num::Int = 50,
                           bins::Union{Nothing,AbstractVector{<:Real}} = nothing,
                           moment_powers::AbstractVector{<:Integer} = [1, 2, 4, 8])
    max_maps < 0 && error("atlas extract-map-data-histogram: --max-maps must be ≥ 0, got $max_maps.")
    addNames = isempty(add) ? String[] : parseFunctionNames(add)
    votePairs = parseVotePairs(vote_cols)
    fns, addFields, addedSet, g = setupAddComputation(addNames, votePairs;
        config = config, graph = graph, pop_col = pop_col, node_col = node_col,
        area_col = area_col, border_col = border_col,
        edge_perimeter_col = edge_perimeter_col, node_data = node_data)
    treeless = allTreeless(fns)
    computeAdded(m) = isempty(fns) ? Dict{String,Any}() : evalWriters(g, m, fns; treeless = treeless)
    valueOf(m, field, added) = field in addedSet ? added[field] : get(m.data, field, nothing)

    atlas = openAtlas(smartOpen(String(Atlas1), "r"))
    mpt, wt = atlas.mapParamType, atlas.weightType

    n_burned = 0
    try
        skipMap(atlas; numSkip = burn_in)
        n_burned = burn_in
    catch e
        e isa EOFError || rethrow()
    end
    if eof(atlas)
        close(atlas)
        error("atlas extract-map-data-histogram: $Atlas1 has no maps left after " *
              "--burn-in $burn_in.")
    end

    first = nextMap(atlas)
    firstAdded = computeAdded(first)
    fieldNames = vcat(sort([k for k in keys(first.data) if !(k in addedSet)]), addFields)
    widths = [length(flattenVal(valueOf(first, f, firstAdded))) for f in fieldNames]

    mkHist() = StreamHist(; integer = integer, momentPowers = moment_powers,
                          binRange = bin_range, binNum = bin_num, bins = bins)
    hists = Vector{Union{StreamHist,Vector{StreamHist}}}(undef, length(fieldNames))
    for k in eachindex(fieldNames)
        hists[k] = widths[k] == 1 ? mkHist() : [mkHist() for _ in 1:widths[k]]
    end

    """Flatten `val` to `Float64`s, sorted ascending when `sortVals` (a no-op for a
    single value); `nothing` (a missing field on this map) becomes an empty vector."""
    function extractVals(val)
        val === nothing && return Float64[]
        vals = Float64.(flattenVal(val))
        sortVals && length(vals) > 1 && sort!(vals)
        return vals
    end

    """Feed one map's already-extracted per-field value vectors into `hists`."""
    function feedRow!(rr)
        for k in eachindex(fieldNames)
            vals = rr[k]
            isempty(vals) && continue
            if widths[k] == 1
                add!(hists[k]::StreamHist, vals[1])
            else
                hv = hists[k]::Vector{StreamHist}
                for j in 1:min(widths[k], length(vals))
                    add!(hv[j], vals[j])
                end
            end
        end
    end

    feedRow!([extractVals(valueOf(first, f, firstAdded)) for f in fieldNames])

    # `fns` empty means `computeAdded` never touches `m.districting` (it
    # short-circuits to an empty dict), so parse a `MapData` instead of a full
    # `Map` to skip reconstructing districting, which otherwise dominates the
    # parse cost (see AtlasIO's `MapData`).
    parseMap = isempty(fns) ? (line -> parseMapData(line, mpt, wt)) :
                              (line -> JSON3.read(line, Map{mpt,wt}))
    progress = quiet ? nothing :
               ProgressUnknown(desc = "Building histograms:", spinner = true)
    written = 1                    # maps accumulated past burn-in (for --max-maps)
    processed = 1 + n_burned       # total maps read from the start (for the progress bar)
    remaining() = max_maps == 0 ? typemax(Int) : max_maps - written
    with_serial_blas() do
        while !eof(atlas) && remaining() > 0
            lines = readBatch(atlas.io, min(BATCH, remaining()))
            n = length(lines)
            n == 0 && break

            # rows[i][k] is map i's extracted (flattened, possibly sorted) value
            # vector for field k.
            rows = Vector{Vector{Vector{Float64}}}(undef, n)
            parallelDo!(n, cores) do i
                m = parseMap(lines[i])
                added = computeAdded(m)
                rows[i] = [extractVals(valueOf(m, field, added)) for field in fieldNames]
            end

            # Order does not matter for histogram accumulation (unlike the CSV
            # writer, which must preserve map order), so rather than feed map by
            # map, transpose to one batch `add!` per (field, index) across the
            # whole read batch -- far cheaper than one scalar `add!` per map.
            for k in eachindex(fieldNames)
                if widths[k] == 1
                    batch = [rows[i][k][1] for i in 1:n if !isempty(rows[i][k])]
                    isempty(batch) || add!(hists[k]::StreamHist, batch)
                else
                    hv = hists[k]::Vector{StreamHist}
                    for j in 1:widths[k]
                        batch = Float64[rows[i][k][j] for i in 1:n if length(rows[i][k]) >= j]
                        isempty(batch) || add!(hv[j], batch)
                    end
                end
            end

            written += n
            processed += n
            progress === nothing ||
                next!(progress; showvalues = [("maps processed", processed)])
        end
    end
    progress === nothing ||
        finish!(progress; showvalues = [("maps processed", processed)])

    close(atlas)
    for h in hists
        h isa StreamHist ? finalize!(h) : foreach(finalize!, h)
    end

    return Dict{String,Union{StreamHist,Vector{StreamHist}}}(
        fieldNames[k] => hists[k] for k in eachindex(fieldNames)), written
end

# ---------------------------------------------------------------------------
# CSV + JSON rendering
# ---------------------------------------------------------------------------

"""Bin edges, exact histogram counts, and ASH-density-derived counts (integrated
over those same edges; `nothing` in `integer` mode, where the ASH is disabled) for
one `StreamHist`."""
function histBins(oh::StreamHist)
    eh = exactHistogram(oh)
    edges = collect(eh.edges[1])
    weights = eh.weights
    ashWeights = oh.integer ? nothing : histogram(oh, edges).weights
    return edges, weights, ashWeights
end

"""Write the exact per-bin edges/counts for one field's histogram(s) (`entry`, a
`StreamHist` or `Vector{StreamHist}`) to `path` as a plain numeric CSV table:
`index,edge_lo,edge_hi,exact_count` (`index` is the position within `entry`, `1` for
a scalar field)."""
function writeHistogramCSV(path::AbstractString, entry)
    ohs = entry isa StreamHist ? [entry] : entry
    io = smartOpen(path, "w")
    write(io, "index,edge_lo,edge_hi,exact_count\n")
    for (idx, oh) in enumerate(ohs)
        edges, weights, _ = histBins(oh)
        for b in eachindex(weights)
            write(io, join((idx, edges[b], edges[b + 1], weights[b]), ",") * "\n")
        end
    end
    close(io)
    return path
end

"""JSON has no NaN/Inf literal (JSON3 errors on them); a `StreamHist` can produce
either -- e.g. skewness/kurtosis on a zero-variance (constant-valued) field --
so map non-finite floats to `null` on the way out."""
jsonFloat(x::AbstractFloat) = isfinite(x) ? x : nothing
jsonFloat(x) = x

"""Everything about one `StreamHist` other than its exact bin counts, as a plain
`Dict` suitable for `JSON3.write`: summary statistics, moment errors, whether it
learned integer-ness, and its bin edges + ASH-density-derived counts (`nothing` in
`integer` mode)."""
function histSummaryDict(oh::StreamHist)
    uf, of = outofrange(oh)
    mn, mx = datarange(oh)
    edges, _, ashWeights = histBins(oh)
    relerrs = oh.integer ? nothing : densityQuality(oh)
    return Dict{String,Any}(
        "nobs" => nobs(oh), "underflow" => uf, "overflow" => of,
        "exact_min" => jsonFloat(mn), "exact_max" => jsonFloat(mx),
        "mean" => jsonFloat(mean(oh)), "variance" => jsonFloat(variance(oh)),
        "std" => jsonFloat(std(oh)),
        "skewness" => jsonFloat(skewness(oh)), "kurtosis" => jsonFloat(kurtosis(oh)),
        "integer" => oh.integer,
        "relerr_moments" => relerrs === nothing ? nothing :
            Dict(string(p) => jsonFloat(e) for (p, e) in zip(oh.momentPowers, relerrs)),
        "edges" => jsonFloat.(edges), "ash_count" => ashWeights)
end

"""Write one field's histogram(s) (`entry`, a `StreamHist` or `Vector{StreamHist}`)
to `path` as a human-readable JSON dictionary: `moment_powers` (shared across every
index) and `histograms`, a dictionary keyed by index (as a string, `"1"` for a
scalar field) of `histSummaryDict` entries."""
function writeHistogramJSON(path::AbstractString, entry)
    ohs = entry isa StreamHist ? [entry] : entry
    doc = Dict{String,Any}(
        "moment_powers" => ohs[1].momentPowers,
        "histograms" => Dict(string(idx) => histSummaryDict(oh)
                              for (idx, oh) in enumerate(ohs)))
    io = smartOpen(path, "w")
    JSON3.write(io, doc)
    close(io)
    return path
end

# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------

"""
    run_extract_map_data_histogram(Atlas1; add, vote_cols, config, graph, pop_col,
                                   node_col, area_col, border_col,
                                   edge_perimeter_col, node_data, burn_in, max_maps,
                                   sortVals, compress, force, integer, bin_range,
                                   bin_num, bins, moment_powers, quiet, cores)

Build `mapDataHistograms` for atlas `Atlas1` and write each field's histogram(s) to
a `<field>-histogram.csv[.gz]` + `<field>-histogram.json[.gz]` pair in a directory
named after `Atlas1` (the same directory `extract-map-data` uses), plus an
`about.md` (as `extract-map-data` writes). The CSV holds the exact per-bin edges
and counts; the JSON holds everything else (see `writeHistogramCSV`/
`writeHistogramJSON`). `compress` gzips both files; a field whose CSV or JSON
output file already exists is skipped unless `force = true`. `max_maps` (0 =
unlimited, the default) stops after accumulating that many maps past the burn-in;
when set, output filenames get a `-histogram-partial` suffix so a partial run
never collides with a full one's output, and `about.md` notes the limit.
"""
function run_extract_map_data_histogram(Atlas1::AbstractString;
                                        add::AbstractString = "",
                                        vote_cols::AbstractString = "",
                                        config::AbstractString = "",
                                        graph::AbstractString = "",
                                        pop_col::AbstractString = "",
                                        node_col::AbstractString = "",
                                        area_col::AbstractString = "",
                                        border_col::AbstractString = "",
                                        edge_perimeter_col::AbstractString = "",
                                        node_data::AbstractString = "",
                                        burn_in::Int = 0, max_maps::Int = 0,
                                        sortVals::Bool = true,
                                        compress::Bool = true, force::Bool = false,
                                        integer::Union{Bool,Symbol} = false,
                                        bin_range::Union{Nothing,Tuple{<:Real,<:Real}} = nothing,
                                        bin_num::Int = 50,
                                        bins::Union{Nothing,AbstractVector{<:Real}} = nothing,
                                        moment_powers::AbstractVector{<:Integer} = [1, 2, 4, 8],
                                        quiet::Bool = false, cores::Int = Threads.nthreads())
    outdir = stripAtlasExt(String(Atlas1))
    isdir(outdir) || mkpath(outdir)

    peek = openAtlas(smartOpen(String(Atlas1), "r"))
    if eof(peek)
        close(peek)
        println("atlas extract-map-data-histogram: $Atlas1 has no maps; nothing written.")
        return nothing
    end
    firstMap = nextMap(peek)
    writeAboutFile(outdir, String(Atlas1), peek, sort(collect(keys(firstMap.data)));
                  burnIn = burn_in, maxMaps = max_maps)
    close(peek)

    hists, _ = mapDataHistograms(Atlas1; add = add, vote_cols = vote_cols, config = config,
        graph = graph, pop_col = pop_col, node_col = node_col, area_col = area_col,
        border_col = border_col, edge_perimeter_col = edge_perimeter_col,
        node_data = node_data, burn_in = burn_in, max_maps = max_maps, sortVals = sortVals,
        cores = cores, quiet = quiet, integer = integer, bin_range = bin_range,
        bin_num = bin_num, bins = bins, moment_powers = moment_powers)

    # A --max-maps run gets its own filenames so it never collides with (or is
    # silently mistaken for) a full run's output in the same directory.
    partial = max_maps > 0 ? "-partial" : ""
    csvExt = partial * (compress ? ".csv.gz" : ".csv")
    jsonExt = partial * (compress ? ".json.gz" : ".json")
    written = String[]
    skipped = String[]
    for field in sort(collect(keys(hists)))
        csvPath = joinpath(outdir, field * "-histogram" * csvExt)
        jsonPath = joinpath(outdir, field * "-histogram" * jsonExt)
        if !force && (isfile(csvPath) || isfile(jsonPath))
            append!(skipped, filter(isfile, [csvPath, jsonPath]))
            continue
        end
        writeHistogramCSV(csvPath, hists[field])
        writeHistogramJSON(jsonPath, hists[field])
        append!(written, [csvPath, jsonPath])
    end
    isempty(skipped) || @info "extract-map-data-histogram: skipping existing file(s) " *
        "(use --force to overwrite): " * join(skipped, ", ")

    quiet || println("Wrote ", length(written), " file(s) + about.md to ", outdir, "/")
    return nothing
end
