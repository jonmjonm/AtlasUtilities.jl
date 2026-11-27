# summarize.jl -- summary statistics of the map data (`summarizeMapData`, `mapatlas summarize-map-data`).
#
# Like `extract-map-data-histogram`, builds a StreamingHistogram per map-data field (or a
# StreamingHistogram per index for a vector field, sorted ascending so index j holds the
# j-th order statistic), but instead of writing files, returns mean/std/quartiles
# (a `MapDataSummary`, which prints as the command's text). No --add/graph/config support -- this only summarizes the
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
    StatSummary

One field's statistics for one weighting (each map counting once, or counting its weight): `mean`, `std`, the
`quartiles` (25%, median, 75%), `worst_gap` (the largest disagreement of a quartile with the ASH density, or
`nothing`; see [`quartiles`](@ref)), and `total` (the number of maps, or their total weight) with the part of it
that fell below (`underflow`) and above (`overflow`) the histogram's range.
"""
struct StatSummary
    mean::Real
    std::Real
    quartiles::NTuple{3,Float64}
    worst_gap::Union{Nothing,Float64}
    total::Real
    underflow::Real
    overflow::Real
end

"""
    FieldSummary

The summary of one field (or one index of a vector field) from its `StreamingHistogram`: `nobs` maps, the exact
`min` and `max`, the `unweighted` statistics, and, when the maps' weights vary, the `weighted` ones (else
`nothing`), with `effective_sample_size` and `total_weight`.
"""
struct FieldSummary
    nobs::Int
    min::Real
    max::Real
    unweighted::StatSummary
    weighted::Union{Nothing,StatSummary}
    effective_sample_size::Real
    total_weight::Real
end

function StatSummary(oh::StreamingHistogram; weighted::Bool)
    qs, worstGap = quartiles(oh; weighted = weighted)
    μ, σ = weighted ? (weightedMean(oh), weightedStd(oh)) : (mean(oh), std(oh))
    total = weighted ? totalweight(oh) : nobs(oh)
    uf, of = weighted ? outofrangeweight(oh) : outofrange(oh)
    return StatSummary(μ, σ, (qs[1], qs[2], qs[3]), worstGap, total, uf, of)
end

function FieldSummary(oh::StreamingHistogram)
    mn, mx = datarange(oh)
    tw = totalweight(oh)
    weighted = tw != 0 && weightsVary(oh) ? StatSummary(oh; weighted = true) : nothing
    return FieldSummary(nobs(oh), mn, mx, StatSummary(oh; weighted = false), weighted, effectivesamplesize(oh), tw)
end

"""
    fieldSummaryLines(s::FieldSummary) -> Vector{String}
    fieldSummaryLines(oh::StreamingHistogram) -> Vector{String}

`mean`/`std`/`[min, 25%, median, 75%, max]` lines for one field (index), plus a
warning line if too much of its data fell out of the histogram range
(`OUTOFRANGE_WARN_FRAC`) and/or its worst quartile-vs-ASH disagreement exceeds
`ASH_QUANTILE_WARN_TOL` (see `quartiles`/`ashQuantileGap`). When the maps'
weights vary (`weightsVary`), the same lines for the weighted data follow, with the
effective sample size, and the same warnings for it; when every weight is 0, a line
saying so.
"""
fieldSummaryLines(oh::StreamingHistogram) = fieldSummaryLines(FieldSummary(oh))

function fieldSummaryLines(s::FieldSummary)
    n = s.nobs
    mn, mx = s.min, s.max
    lines = String[]

    function summarize!(st::StatSummary, weighted)
        qs, worstGap = st.quartiles, st.worst_gap
        μ, σ = st.mean, st.std
        label = weighted ? "weighted " : ""
        push!(lines, "$(label)mean: $μ   $(label)std: $σ" *
                     (weighted ? "   (effective sample size: $(s.effective_sample_size) of $n maps)" : ""))
        push!(lines, "$(label)[min, 25%, median, 75%, max]: [$mn, $(qs[1]), $(qs[2]), $(qs[3]), $mx]")

        total = st.total
        uf, of = st.underflow, st.overflow
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

    summarize!(s.unweighted, false)
    if s.total_weight == 0
        push!(lines, "weighted: every map has weight 0, so there are no weighted statistics")
    elseif s.weighted !== nothing
        summarize!(s.weighted, true)
    end
    return lines
end

"""
    MapDataSummary

What [`summarizeMapData`](@ref) returns: `nmaps`, the number of maps considered, and `fields`, each field's
[`FieldSummary`](@ref) (a `Vector{FieldSummary}`, one per index, for a vector field). Printing it gives the text
`mapatlas summarize-map-data` prints.
"""
struct MapDataSummary
    nmaps::Int
    fields::Dict{String,Union{FieldSummary,Vector{FieldSummary}}}
end

function Base.show(io::IO, s::MapDataSummary)
    println(io, "Maps considered: ", s.nmaps)
    for field in sort(collect(keys(s.fields)))
        entry = s.fields[field]
        println(io)
        println(io, field, ":")
        if entry isa FieldSummary
            for line in fieldSummaryLines(entry)
                println(io, "  ", line)
            end
        else
            for (j, fs) in enumerate(entry)
                println(io, "  [", j, "]")
                for line in fieldSummaryLines(fs)
                    println(io, "    ", line)
                end
            end
        end
    end
end

"""
    summarizeMapData(atlas; max_maps = 0, cores = Threads.nthreads(), progress = false) -> MapDataSummary

For every map-data field of the atlas at `atlas`: `mean`, `std`, and `[min, 25% quartile, median, 75% quartile,
max]`, each computed from a `StreamingHistogram` (one per index for a vector field, with each map's vector
sorted ascending first -- see `mapDataHistograms`). When the maps' weights vary, the weighted mean, std and
quartiles (each map counting its weight) and the effective sample size too (see `fieldSummaryLines`).
`max_maps` (0 = unlimited, the default) considers only the atlas's first `max_maps` maps. `progress` shows a
progress bar. Print the result for the text `mapatlas summarize-map-data` prints.
"""
function summarizeMapData(atlas::AbstractString; max_maps::Int = 0, cores::Int = Threads.nthreads(),
                          progress::Bool = false)
    max_maps < 0 && error("summarizeMapData: max_maps = $max_maps must be ≥ 0.")
    hists, nMaps = mapDataHistograms(atlas; max_maps = max_maps, sort_values = true, cores = cores,
                                     progress = progress)
    fields = Dict{String,Union{FieldSummary,Vector{FieldSummary}}}(
        field => (h isa StreamingHistogram ? FieldSummary(h) : FieldSummary.(h)) for (field, h) in hists)
    return MapDataSummary(nMaps, fields)
end
