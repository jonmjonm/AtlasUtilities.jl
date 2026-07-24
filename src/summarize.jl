# summarize.jl -- the `atlas summarize-map-data` subcommand.
#
# Like `extract-map-data-histogram`, builds a StreamHist per map-data field (or a
# StreamHist per index for a vector field, sorted ascending so index j holds the
# j-th order statistic), but instead of writing files, prints mean/std/quartiles
# straight to stdout. No --add/graph/config support -- this only summarizes the
# map data already present in the atlas.

# A field/index whose points fall out of the learned histogram range more than
# this often gets a warning: the min/max/tail-quantile estimates lean on a single
# coarse uniform-interpolation across the *entire* out-of-range bucket (not one of
# the histogram's regular bins), so they get materially less reliable.
const OUTOFRANGE_WARN_FRAC = 0.01

# A quartile estimate (from linear interpolation within its exact-histogram bin)
# whose implied probability, per the ASH density, disagrees with its target
# quantile by more than this many percentage points gets a warning: the
# within-bin-uniform assumption may not fit this field's actual shape.
const ASH_QUANTILE_WARN_TOL = 0.02

"""
    histQuantile(oh, q) -> (value, inRange)

Estimate the `q`-quantile (`0 <= q <= 1`) of `oh`'s data from its exact histogram
(`exactHistogram`), linearly interpolating within whichever bin the target rank
falls in. `q = 0`/`q = 1` return the exact min/max (`datarange`) directly. If the
target rank falls in the underflow or overflow bucket instead of a regular bin,
interpolates uniformly across that whole bucket (exact min/max to the nearest bin
edge) -- a much coarser estimate, since that bucket is not one of the histogram's
even bins -- and returns `inRange = false` so callers know not to trust it (or try
to corroborate it against the ASH density, which is zero outside the histogram
range and so cannot corroborate a tail estimate anyway).
"""
function histQuantile(oh::StreamHist, q::Real)
    n = nobs(oh)
    mn, mx = datarange(oh)
    q <= 0 && return mn, true
    q >= 1 && return mx, true

    uf, of = outofrange(oh)
    eh = exactHistogram(oh)
    edges = collect(eh.edges[1])
    weights = eh.weights
    target = q * n

    if target <= uf
        frac = uf == 0 ? 0.0 : target / uf
        return mn + frac * (edges[1] - mn), false
    end

    cum = uf
    for b in eachindex(weights)
        cumNext = cum + weights[b]
        if target <= cumNext
            lo, hi = edges[b], edges[b + 1]
            frac = weights[b] == 0 ? 0.0 : (target - cum) / weights[b]
            return lo + frac * (hi - lo), true
        end
        cum = cumNext
    end

    frac = of == 0 ? 0.0 : (target - cum) / of
    return edges[end] + frac * (mx - edges[end]), false
end

"""
    ashQuantileGap(oh, q, xhat) -> Union{Float64,Nothing}

The disagreement (`impliedProb - q`) between target quantile `q` and the
probability the ASH density assigns to `[exact min, xhat]` (underflow mass plus
the ASH-integrated mass up to `xhat`, via `histogram`), for a `histQuantile`
estimate `xhat` known to fall inside the histogram's regular bin range.
`nothing` when there is no ASH to check against (`oh.integer`) or `oh` is empty.
"""
function ashQuantileGap(oh::StreamHist, q::Real, xhat::Real)
    oh.integer && return nothing
    n = nobs(oh)
    n == 0 && return nothing
    uf, _ = outofrange(oh)
    lo = first(exactHistogram(oh).edges[1])
    ashMass = histogram(oh, [lo, xhat]).weights[1]
    impliedProb = (uf + ashMass) / n
    return impliedProb - q
end

"""
    fieldSummaryLines(oh) -> Vector{String}

`mean`/`std`/`[min, 25%, median, 75%, max]` lines for one `StreamHist`, plus a
warning line if too much of its data fell out of the histogram range
(`OUTOFRANGE_WARN_FRAC`) and/or its worst quartile-vs-ASH disagreement exceeds
`ASH_QUANTILE_WARN_TOL` (see `histQuantile`/`ashQuantileGap`).
"""
function fieldSummaryLines(oh::StreamHist)
    n = nobs(oh)
    uf, of = outofrange(oh)
    mn, mx = datarange(oh)

    quartiles = Float64[]
    worstGap = nothing
    for q in (0.25, 0.5, 0.75)
        x, inRange = histQuantile(oh, q)
        push!(quartiles, x)
        if inRange
            gap = ashQuantileGap(oh, q, x)
            if gap !== nothing && (worstGap === nothing || abs(gap) > abs(worstGap))
                worstGap = gap
            end
        end
    end

    lines = String[
        "mean: $(mean(oh))   std: $(std(oh))",
        "[min, 25%, median, 75%, max]: [$mn, $(quartiles[1]), $(quartiles[2]), $(quartiles[3]), $mx]",
    ]

    oorFrac = n == 0 ? 0.0 : (uf + of) / n
    if oorFrac > OUTOFRANGE_WARN_FRAC
        push!(lines, "WARNING: $(round(100 * oorFrac; digits = 1))% of points fell out of the " *
                      "histogram range (underflow=$uf, overflow=$of of $n) -- tail quantile " *
                      "estimates may be inaccurate.")
    end
    if worstGap !== nothing && abs(worstGap) > ASH_QUANTILE_WARN_TOL
        push!(lines, "WARNING: a quartile estimate disagrees with the ASH density by " *
                      "$(round(100 * abs(worstGap); digits = 1)) percentage points -- the " *
                      "within-bin interpolation may not fit this field's shape.")
    end
    return lines
end

"""
    run_summarize_map_data(Atlas1; max_maps = 0, cores = Threads.nthreads(),
                           quiet = false)

Print the number of maps considered, then for every map-data field of atlas
`Atlas1`: `mean`, `std`, and `[min, 25% quartile, median, 75% quartile, max]`, each
computed from a `StreamHist` (a `Vector{StreamHist}` per index for a vector
field, with each map's vector sorted ascending first -- see `mapDataHistograms`).
`max_maps` (0 = unlimited, the default) considers only the atlas's first `n` maps.
"""
function run_summarize_map_data(Atlas1::AbstractString; max_maps::Int = 0,
                                cores::Int = Threads.nthreads(), quiet::Bool = false)
    max_maps < 0 && error("atlas summarize-map-data: --max-maps must be ≥ 0, got $max_maps.")

    hists, nMaps = mapDataHistograms(Atlas1; max_maps = max_maps, sortVals = true,
                                     cores = cores, quiet = quiet)

    println("Maps considered: ", nMaps)
    for field in sort(collect(keys(hists)))
        entry = hists[field]
        println()
        println(field, ":")
        if entry isa StreamHist
            for line in fieldSummaryLines(entry)
                println("  ", line)
            end
        else
            for (j, oh) in enumerate(entry)
                println("  [", j, "]")
                for line in fieldSummaryLines(oh)
                    println("    ", line)
                end
            end
        end
    end
    return nothing
end
