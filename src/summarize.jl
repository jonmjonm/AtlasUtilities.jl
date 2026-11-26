# summarize.jl -- the `atlas summarize-map-data` subcommand.
#
# Like `extract-map-data-histogram`, builds a StreamingHistogram per map-data field (or a
# StreamingHistogram per index for a vector field, sorted ascending so index j holds the
# j-th order statistic), but instead of writing files, prints mean/std/quartiles
# straight to stdout. No --add/graph/config support -- this only summarizes the
# map data already present in the atlas. When the maps' weights vary, the weighted
# mean/std/quartiles (each map counting its weight) are printed too.

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
    ashQuantileGap(oh, q, xhat; weighted = false) -> Union{Float64,Nothing}

The disagreement (`impliedProb - q`) between target quantile `q` and the
probability the ASH density assigns to `[exact min, xhat]` (underflow mass plus
the ASH-integrated mass up to `xhat`, via `histogram`), for a quantile estimate
`xhat` (StreamHistogram's `quantile`/`weightedQuantile`) inside the histogram's
range. With
`weighted`, the same for the weighted data and density (`weightedHistogram`).
`nothing` when there is no ASH to check against (`oh.integer`) or nothing to
check (no maps, or total weight 0).
"""
function ashQuantileGap(oh::StreamingHistogram, q::Real, xhat::Real; weighted::Bool = false)
    oh.integer && return nothing
    total = weighted ? totalweight(oh) : nobs(oh)
    total == 0 && return nothing
    uf = weighted ? outofrangeweight(oh).underflow : outofrange(oh).underflow
    lo = first(exactHistogram(oh).edges[1])
    bins = [lo, xhat]
    ashMass = (weighted ? weightedHistogram(oh, bins) : histogram(oh, bins)).weights[1]
    return (uf + ashMass) / total - q
end

"""
    weightsVary(oh) -> Bool

Whether the maps in `oh` have different weights: their effective sample size is
then below the number of maps. Equal weights (e.g. an unweighted atlas, every
weight 1) give the same weighted and unweighted results.
"""
weightsVary(oh::StreamingHistogram) = effectivesamplesize(oh) < nobs(oh) * (1 - 1e-9)

"""The quartiles of `oh` (unweighted, or `weighted`; StreamHistogram's `quantile`
and `weightedQuantile`) and the largest disagreement of one inside the histogram's
range with the ASH density (`nothing` if none could be checked). One outside the
range was interpolated across the out-of-range values, and the density, zero there,
can't corroborate it."""
function quartiles(oh::StreamingHistogram; weighted::Bool = false)
    lo, hi = extrema(only(exactHistogram(oh).edges))
    qs = Float64[]
    worstGap = nothing
    for q in (0.25, 0.5, 0.75)
        x = weighted ? weightedQuantile(oh, q) : quantile(oh, q)
        push!(qs, x)
        if lo <= x <= hi
            gap = ashQuantileGap(oh, q, x; weighted = weighted)
            if gap !== nothing && (worstGap === nothing || abs(gap) > abs(worstGap))
                worstGap = gap
            end
        end
    end
    return qs, worstGap
end

"""
    fieldSummaryLines(oh) -> Vector{String}

`mean`/`std`/`[min, 25%, median, 75%, max]` lines for one `StreamingHistogram`, plus a
warning line if too much of its data fell out of the histogram range
(`OUTOFRANGE_WARN_FRAC`) and/or its worst quartile-vs-ASH disagreement exceeds
`ASH_QUANTILE_WARN_TOL` (see `quartiles`/`ashQuantileGap`). When the maps'
weights vary (`weightsVary`), the same lines for the weighted data follow, with the
effective sample size, and the same warnings for it; when every weight is 0, a line
saying so.
"""
function fieldSummaryLines(oh::StreamingHistogram)
    n = nobs(oh)
    mn, mx = datarange(oh)
    lines = String[]

    function summarize!(weighted)
        qs, worstGap = quartiles(oh; weighted = weighted)
        μ, σ = weighted ? (weightedMean(oh), weightedStd(oh)) : (mean(oh), std(oh))
        label = weighted ? "weighted " : ""
        push!(lines, "$(label)mean: $μ   $(label)std: $σ" *
                     (weighted ? "   (effective sample size: $(effectivesamplesize(oh)) of $n maps)" : ""))
        push!(lines, "$(label)[min, 25%, median, 75%, max]: [$mn, $(qs[1]), $(qs[2]), $(qs[3]), $mx]")

        total = weighted ? totalweight(oh) : n
        uf, of = weighted ? outofrangeweight(oh) : outofrange(oh)
        oorFrac = total == 0 ? 0.0 : (uf + of) / total
        if oorFrac > OUTOFRANGE_WARN_FRAC
            what = weighted ? "of the weight" : "of points"
            counts = weighted ? "underflow weight=$uf, overflow weight=$of of $total" :
                                "underflow=$uf, overflow=$of of $n"
            push!(lines, "WARNING: $(round(100 * oorFrac; digits = 1))% $what fell out of the " *
                         "histogram range ($counts) -- tail quantile estimates may be inaccurate.")
        end
        if worstGap !== nothing && abs(worstGap) > ASH_QUANTILE_WARN_TOL
            push!(lines, "WARNING: a $(label)quartile estimate disagrees with the $(label)ASH density by " *
                         "$(round(100 * abs(worstGap); digits = 1)) percentage points -- the " *
                         "within-bin interpolation may not fit this field's shape.")
        end
    end

    summarize!(false)
    if totalweight(oh) == 0
        push!(lines, "weighted: every map has weight 0, so there are no weighted statistics")
    elseif weightsVary(oh)
        summarize!(true)
    end
    return lines
end

"""
    run_summarize_map_data(Atlas1; max_maps = 0, cores = Threads.nthreads(),
                           quiet = false)

Print the number of maps considered, then for every map-data field of atlas
`Atlas1`: `mean`, `std`, and `[min, 25% quartile, median, 75% quartile, max]`, each
computed from a `StreamingHistogram` (a `Vector{StreamingHistogram}` per index for a vector
field, with each map's vector sorted ascending first -- see `mapDataHistograms`).
When the maps' weights vary, the weighted mean, std and quartiles (each map counting
its weight) and the effective sample size follow (see `fieldSummaryLines`).
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
        if entry isa StreamingHistogram
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
