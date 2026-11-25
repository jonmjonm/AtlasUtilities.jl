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
# directory `extract-map-data` uses. The CSV holds only the exact per-bin edges,
# counts and sums of map weights (a plain numeric table for loading straight into a
# histogram plot in Python/Julia); the JSON holds everything else -- per-index summary
# statistics, unweighted and weighted, moment errors, the ASH-density bin counts and
# weights, and the bin edges again (so the JSON is self-contained) -- as a
# human-readable dictionary keyed by index.
#
# Every value is added with its map's weight. StreamHistogram keeps each tally both
# unweighted and weighted, so the unweighted results are the same as without weights.

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

Each value is added with its map's weight (`add!(oh, x, w)`), so every histogram
has both the unweighted results (each map counts once) and the weighted ones (each
map counts its weight; see StreamHistogram's `weighted*` functions). A map whose
weight is negative or not finite is an error.

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

    """Feed one map's already-extracted per-field value vectors into `hists`, with
    the map's weight `w`."""
    function feedRow!(rr, w)
        for k in eachindex(fieldNames)
            vals = rr[k]
            isempty(vals) && continue
            if widths[k] == 1
                add!(hists[k]::StreamHist, vals[1], w)
            else
                hv = hists[k]::Vector{StreamHist}
                for j in 1:min(widths[k], length(vals))
                    add!(hv[j], vals[j], w)
                end
            end
        end
    end

    feedRow!([extractVals(valueOf(first, f, firstAdded)) for f in fieldNames], mapWeight(first))

    # Per map, parse + compute (--add) + extract the values in parallel (AtlasIO's
    # `eachMap(f, ...)`). `fns` empty means `computeAdded` never touches
    # `m.districting` (it short-circuits to an empty dict), so read a `MapData`
    # instead of a full `Map` to skip reconstructing districting, which otherwise
    # dominates the parse cost (see AtlasIO's `MapData`).
    # A map with a bad weight is an error meant for the user: returned as a
    # `CapturedError` and raised in the loop below, without AtlasIO's error log.
    valuesOf(m) = begin
        w = try
            mapWeight(m)
        catch e
            return CapturedError(e)
        end
        added = computeAdded(m)
        ([extractVals(valueOf(m, field, added)) for field in fieldNames], w)
    end
    each = isempty(fns) ? eachMapData : eachMap
    progress = quiet ? nothing :
               ProgressUnknown(desc = "Building histograms:", spinner = true)
    written = 1                    # maps accumulated past burn-in (for --max-maps)
    processed = 1 + n_burned       # total maps read from the start (for the progress bar)

    # rows[i][k] is buffered map i's extracted (flattened, possibly sorted) value
    # vector for field k; ws[i] is its weight. Order does not matter for histogram
    # accumulation (unlike the CSV writer, which must preserve map order), so rather
    # than feed map by map, transpose BATCH maps at a time to one batch `add!` per
    # (field, index) -- far cheaper than one scalar `add!` per map.
    rows = Vector{Vector{Float64}}[]
    ws = Float64[]
    function flush!()
        n = length(rows)
        for k in eachindex(fieldNames)
            if widths[k] == 1
                has = [i for i in 1:n if !isempty(rows[i][k])]
                isempty(has) || add!(hists[k]::StreamHist, [rows[i][k][1] for i in has], ws[has])
            else
                hv = hists[k]::Vector{StreamHist}
                for j in 1:widths[k]
                    has = [i for i in 1:n if length(rows[i][k]) >= j]
                    isempty(has) || add!(hv[j], [rows[i][k][j] for i in has], ws[has])
                end
            end
        end
        empty!(rows)
        empty!(ws)
    end
    with_serial_blas() do
        for r in each(valuesOf, atlas; max = max_maps == 0 ? typemax(Int) : max_maps - 1, ntasks = cores)
            raiseCaptured(r)
            rr, w = r
            push!(rows, rr)
            push!(ws, w)
            length(rows) == BATCH && flush!()
            written += 1
            processed += 1
            progress === nothing ||
                next!(progress; showvalues = [("maps processed", processed)])
        end
        flush!()
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

"""
    mapWeight(m) -> Float64

Map `m`'s weight, which must be finite and nonnegative; otherwise an error naming
the map.
"""
function mapWeight(m)
    w = Float64(m.weight)
    (isfinite(w) && w >= 0) ||
        error("atlas: map \"$(m.name)\" has weight $(m.weight); map weights must be finite and nonnegative.")
    return w
end

# ---------------------------------------------------------------------------
# CSV + JSON rendering
# ---------------------------------------------------------------------------

"""The bins of one `StreamHist`: its `edges`, each bin's map count (`counts`) and
sum of map weights (`weights`), and the same two from the ASH density integrated
over the edges (`ashCounts`, `ashWeights`; `nothing` in `integer` mode, which has no
ASH)."""
function histBins(oh::StreamHist)
    eh = exactHistogram(oh)
    edges = collect(eh.edges[1])
    ashCounts = oh.integer ? nothing : histogram(oh, edges).weights
    ashWeights = oh.integer ? nothing : weightedHistogram(oh, edges).weights
    return (edges = edges, counts = eh.weights, weights = weightedHistogram(oh).weights,
            ashCounts = ashCounts, ashWeights = ashWeights)
end

"""Write the exact bins of one field's histogram(s) (`entry`, a `StreamHist` or
`Vector{StreamHist}`) to `path` as a plain numeric CSV table:
`index,edge_lo,edge_hi,exact_count,weight_sum` (`index` is the position within
`entry`, `1` for a scalar field; `exact_count` the number of maps in the bin,
`weight_sum` the sum of their weights)."""
function writeHistogramCSV(path::AbstractString, entry)
    ohs = entry isa StreamHist ? [entry] : entry
    io = smartOpen(path, "w")
    write(io, "index,edge_lo,edge_hi,exact_count,weight_sum\n")
    for (idx, oh) in enumerate(ohs)
        b = histBins(oh)
        for k in eachindex(b.counts)
            write(io, join((idx, b.edges[k], b.edges[k + 1], b.counts[k], b.weights[k]), ",") * "\n")
        end
    end
    close(io)
    return path
end

"""JSON has no NaN/Inf literal (JSON.jl errors on them); a `StreamHist` can produce
either -- e.g. skewness/kurtosis on a zero-variance (constant-valued) field --
so map non-finite floats to `null` on the way out."""
jsonFloat(x::AbstractFloat) = isfinite(x) ? x : nothing
jsonFloat(x) = x

"""Everything about one `StreamHist` other than its exact bins, as a plain `Dict`
suitable for `JSON.json`: summary statistics, moment errors, whether it learned
integer-ness, its bin edges and ASH-density-derived counts (`nothing` in `integer`
mode), and the same for the weighted data (`total_weight`, `effective_sample_size`,
`underflow_weight`/`overflow_weight`, `weighted_*`, `ash_weight`). A statistic needs
moments up to its order -- variance and std 2, skewness 3, kurtosis 4 -- and a
`StreamHist` tracks them only up to its highest moment power, so a lower
`--moment-powers` gives `nothing` (null) for the ones it cannot compute."""
function histSummaryDict(oh::StreamHist)
    maxp = maximum(oh.momentPowers)
    upto(order, stat) = maxp >= order ? jsonFloat(stat(oh)) : nothing
    relerrDict(errs) = errs === nothing ? nothing :
        Dict(string(p) => jsonFloat(e) for (p, e) in zip(oh.momentPowers, errs))
    uf, of = outofrange(oh)
    ufw, ofw = outofrangeweight(oh)
    mn, mx = datarange(oh)
    b = histBins(oh)
    return Dict{String,Any}(
        "nobs" => nobs(oh), "underflow" => uf, "overflow" => of,
        "exact_min" => jsonFloat(mn), "exact_max" => jsonFloat(mx),
        "mean" => jsonFloat(mean(oh)), "variance" => upto(2, variance), "std" => upto(2, std),
        "skewness" => upto(3, skewness), "kurtosis" => upto(4, kurtosis),
        "integer" => oh.integer,
        "relerr_moments" => relerrDict(oh.integer ? nothing : densityQuality(oh)),
        "edges" => jsonFloat.(b.edges), "ash_count" => b.ashCounts,
        "total_weight" => totalweight(oh), "effective_sample_size" => effectivesamplesize(oh),
        "underflow_weight" => ufw, "overflow_weight" => ofw,
        "weighted_mean" => jsonFloat(weightedMean(oh)), "weighted_variance" => upto(2, weightedVariance),
        "weighted_std" => upto(2, weightedStd), "weighted_skewness" => upto(3, weightedSkewness),
        "weighted_kurtosis" => upto(4, weightedKurtosis),
        "weighted_relerr_moments" => relerrDict(oh.integer ? nothing : weightedDensityQuality(oh)),
        "ash_weight" => b.ashWeights)
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
    JSON.json(io, doc)
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
