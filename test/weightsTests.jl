# Map weights in extract-map-data-histogram, summarize-map-data and extract-map-data: each value is added to its
# histogram with its map's weight, so the weighted results are those of the weighted map values, while the
# unweighted results are unchanged. capture_stdout is defined in infoTests.jl, included before this file.

using Test
import JSON
using AtlasIO
using StreamHistogram
using AtlasUtilities: mapDataHistograms, writeHistograms, extractMapData, summarizeMapData,
                      ashQuantileGap, fieldSummaryLines, weightsVary, stripAtlasExt

const WCT = joinpath(@__DIR__, "..", "examples", "cycleWalk_ct_slice.jsonl.gz")

"""A copy of the CT slice in a fresh directory, map `k` given weight `weightOf(k)` (of type `T`) and written
`repeats(k)` times."""
function reweighted(weightOf; T = Float64, repeats = k -> 1)
    dst = joinpath(mktempdir(), "w.jsonl.gz")
    io = smartOpen(WCT, "r")
    a = openAtlas(io)
    out = smartOpen(dst, "w")
    newAtlas(out, AtlasHeader("reweighted CT slice", Dict{String,Any}, Dict{String,Any}; weightType = T),
             a.atlasParam)
    k = 0
    while !eof(a)
        m = nextMap(a)
        k += 1
        for _ in 1:repeats(k)
            addMap(out, Map(m.name, m.districting, T(weightOf(k)), m.data))
        end
    end
    close(out); close(io)
    return dst
end

allmaps(path) = (io = smartOpen(path, "r"); a = openAtlas(io); ms = Map[]; while !eof(a) push!(ms, nextMap(a)) end;
                 close(io); ms)
wreadtext(p) = (io = smartOpen(p, "r"); s = read(io, String); close(io); s)

"Every histogram of a `mapDataHistograms` result, as (field, index, StreamingHistogram)."
everyHist(hs) = [(f, j, oh) for f in sort(collect(keys(hs)))
                 for (j, oh) in enumerate(hs[f] isa StreamingHistogram ? [hs[f]] : hs[f])]

@testset "map weights" begin
    src = reweighted(k -> 0.25 * k)
    ms = allmaps(src)
    w = [m.weight for m in ms]
    hs, nmaps = mapDataHistograms(src)
    hu, _ = mapDataHistograms(WCT)            # the same maps, every weight 1

    @testset "the weighted statistics are those of the weighted map values" begin
        @test nmaps == length(ms) && w[3] === 0.75
        f = "get_log_spanning_forests"
        x = [Float64(m.data[f]) for m in ms]
        μ = sum(w .* x) / sum(w)
        @test totalweight(hs[f]) ≈ sum(w)
        @test weightedMean(hs[f]) ≈ μ rtol = 1e-12
        @test weightedVariance(hs[f]) ≈ sum(w .* (x .- μ) .^ 2) / sum(w) rtol = 1e-10
        @test effectivesamplesize(hs[f]) ≈ sum(w)^2 / sum(w .^ 2)
        @test weightsVary(hs[f])

        # a vector field, sorted: histogram j holds the j-th smallest value of each map
        g = "get_isoperimetric_scores"
        X = [sort(Float64.(m.data[g])) for m in ms]
        for j in eachindex(hs[g])
            xj = [v[j] for v in X]
            @test weightedMean(hs[g][j]) ≈ sum(w .* xj) / sum(w) rtol = 1e-12
            @test sum(weightedHistogram(hs[g][j]).weights) + sum(outofrangeweight(hs[g][j])) ≈ sum(w)
        end
    end

    @testset "the unweighted results don't change with the weights" begin
        for ((f, j, a), (_, _, b)) in zip(everyHist(hs), everyHist(hu))
            @test nobs(a) == nobs(b) && datarange(a) == datarange(b)
            @test mean(a) == mean(b) && variance(a) == variance(b)
            @test exactHistogram(a).weights == exactHistogram(b).weights
            @test densityGrid(a).density == densityGrid(b).density
        end
        # and with every weight 1, the weighted results are the unweighted ones
        for (_, _, b) in everyHist(hu)
            @test !weightsVary(b)
            @test weightedMean(b) ≈ mean(b) rtol = 1e-12
            @test weightedHistogram(b).weights == exactHistogram(b).weights
        end
    end

    @testset "an integer weight k counts like the map repeated k times" begin
        times(k) = 1 + k % 3
        weighted, _ = mapDataHistograms(reweighted(times; T = Int))
        repeated, _ = mapDataHistograms(reweighted(k -> 1; T = Int, repeats = times))
        for ((_, _, a), (_, _, b)) in zip(everyHist(weighted), everyHist(repeated))
            @test totalweight(a) == nobs(b)
            @test weightedHistogram(a).weights == exactHistogram(b).weights   # the same learned range
            @test weightedMean(a) ≈ mean(b) rtol = 1e-12
            @test weightedVariance(a) ≈ variance(b) rtol = 1e-9
            @test densityGrid(a; weighted = true).density ≈ densityGrid(b).density rtol = 1e-12
        end
    end

    @testset "extract-map-data-histogram writes the weighted bins and statistics" begin
        for (path, hists) in ((src, hs), (reweighted(k -> 1; T = Int), hu))
            histogramFiles(path; compress = false)
            dir = stripAtlasExt(path)
            for f in ("get_log_spanning_forests", "get_isoperimetric_scores")
                lines = filter(!isempty, split(wreadtext(joinpath(dir, f * "-histogram.csv")), '\n'))
                @test lines[1] == "index,edge_lo,edge_hi,exact_count,weight_sum"
                cells = [split(l, ',') for l in lines[2:end]]
                doc = JSON.parse(wreadtext(joinpath(dir, f * "-histogram.json")); dicttype = Dict{String,Any})
                ohs = hists[f] isa StreamingHistogram ? [hists[f]] : hists[f]
                for (j, oh) in enumerate(ohs)
                    h = doc["histograms"][string(j)]
                    mine = [c for c in cells if c[1] == string(j)]
                    @test parse.(Float64, getindex.(mine, 5)) ≈ weightedHistogram(oh).weights
                    @test sum(parse.(Float64, getindex.(mine, 5))) + h["underflow_weight"] + h["overflow_weight"] ≈
                          h["total_weight"]
                    @test h["total_weight"] ≈ totalweight(oh)
                    @test h["effective_sample_size"] ≈ effectivesamplesize(oh)
                    @test h["weighted_mean"] ≈ weightedMean(oh)
                    @test h["weighted_std"] ≈ weightedStd(oh)
                    @test h["weighted_excess_kurtosis"] ≈ weightedKurtosis(oh)
                    @test Set(keys(h["weighted_relerr_moments"])) == Set(string.(oh.momentPowers))
                    @test length(h["ash_weight"]) == length(h["ash_count"]) == length(h["edges"]) - 1
                    @test sum(h["ash_weight"]) ≈ h["total_weight"] - h["underflow_weight"] - h["overflow_weight"]
                end
            end
        end
        # with every weight 1, the weighted entries repeat the unweighted ones
        dir = stripAtlasExt(reweighted(k -> 1; T = Int))
        histogramFiles(dir * ".jsonl.gz"; compress = false)
        h = JSON.parse(wreadtext(joinpath(dir, "get_log_spanning_forests-histogram.json")))["histograms"]["1"]
        @test h["total_weight"] == h["effective_sample_size"] == h["nobs"]
        @test h["weighted_mean"] ≈ h["mean"] && h["weighted_std"] ≈ h["std"]
        @test h["ash_weight"] ≈ h["ash_count"]
    end

    @testset "extract-map-data ends each row with the map's weight" begin
        extractMapData(src; compress = false)
        for f in ("get_log_spanning_trees", "get_isoperimetric_scores")
            lines = filter(!isempty, split(wreadtext(joinpath(stripAtlasExt(src), f * ".csv")), '\n'))
            @test endswith(lines[1], ",map_weight")
            @test [parse(Float64, last(split(l, ','))) for l in lines[2:end]] == w
        end
    end

    @testset "summarize-map-data prints the weighted statistics when the weights vary" begin
        out = capture_stdout(() -> print(summarizeMapData(src)))
        f = "get_log_spanning_forests"
        @test occursin("weighted mean: $(weightedMean(hs[f]))", out)
        @test occursin("effective sample size: $(effectivesamplesize(hs[f])) of $(length(ms)) maps", out)
        @test occursin("weighted [min, 25%, median, 75%, max]:", out)
        @test occursin("mean: $(mean(hs[f]))", out)                  # the unweighted lines are still there
        # with every weight 1 the output is unweighted only
        plain = capture_stdout(() -> print(summarizeMapData(WCT)))
        @test !occursin("weighted", plain)
        # with every weight 0 it says so
        zero = capture_stdout(() -> print(summarizeMapData(reweighted(k -> 0.0))))
        @test occursin("every map has weight 0", zero) && !occursin("NaN", zero)
    end

    @testset "weighted quartiles and their summary lines" begin
        xs = collect(0.5:1.0:99.5)
        tilted = StreamingHistogram(; binRange = (0.0, 100.0), binNum = 100)
        add!(tilted, xs, xs)                       # weight ∝ x: the weighted CDF is (x/100)², median 100/√2
        finalize!(tilted)
        med = weightedQuantile(tilted, 0.5)
        @test isapprox(med, 100 / sqrt(2); atol = 0.5)
        @test isapprox(quantile(tilted, 0.5), 50; atol = 0.5)
        @test abs(ashQuantileGap(tilted, 0.5, med; weighted = true)) < 0.02
        @test weightsVary(tilted)
        lines = fieldSummaryLines(tilted)
        @test any(startswith("weighted mean:"), lines) && !any(contains("WARNING"), lines)

        equal = StreamingHistogram(; binRange = (0.0, 100.0), binNum = 100)
        add!(equal, xs, fill(2.5, length(xs)))
        finalize!(equal)
        @test !weightsVary(equal)
        for q in (0.0, 0.1, 0.25, 0.5, 0.9, 1.0)
            @test weightedQuantile(equal, q) ≈ quantile(equal, q)
        end
        @test !any(contains("weighted"), fieldSummaryLines(equal))

        # heavy weights outside the range: the weighted out-of-range warning, not the unweighted one
        heavy = StreamingHistogram(; binRange = (0.0, 100.0), binNum = 100)
        add!(heavy, [xs; 150.0], [ones(length(xs)); 50.0])
        finalize!(heavy)
        lines = fieldSummaryLines(heavy)
        @test any(contains("of the weight fell out of the histogram range"), lines)
        @test !any(contains("of points fell out"), lines)
        @test weightedQuantile(heavy, 0.9) > 100                           # among the overflow

        nothingThere = StreamingHistogram(; binRange = (0.0, 1.0))
        add!(nothingThere, 0.5, 0.0)
        finalize!(nothingThere)
        @test isnan(weightedQuantile(nothingThere, 0.5))
        @test ashQuantileGap(nothingThere, 0.5, 0.5; weighted = true) === nothing
    end

    @testset "a negative weight is an error naming the map" begin
        for bad in (1, 3)                            # the first map is read apart from the rest
            path = reweighted(k -> k == bad ? -1.0 : 1.0)
            name = allmaps(path)[bad].name
            logs, err = Test.collect_test_logs() do
                try
                    mapDataHistograms(path)
                    nothing
                catch e
                    e
                end
            end
            @test err !== nothing
            @test !any(l -> l.level >= Base.CoreLogging.Error, logs)    # meant for the user: no AtlasIO log
            msg = sprint(showerror, err)
            @test occursin("map \"$name\" has weight -1.0", msg) && occursin("nonnegative", msg)
        end
    end
end
