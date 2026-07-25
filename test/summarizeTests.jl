# Tests for the `atlas summarize-map-data` subcommand (src/summarize.jl):
# the histogram-based quantile estimator, its ASH cross-check, the
# warning-producing summary lines, and an end-to-end run against a real atlas.
# capture_stdout is defined in infoTests.jl, included before this file (see
# runtests.jl).

using Test
using AtlasIO
using StreamHistogram: StreamHist, add!, finalize!, nobs, datarange, outofrange, mean, std
using AtlasUtilities: run_summarize_map_data, histQuantile, ashQuantileGap, fieldSummaryLines,
                      mapDataHistograms

@testset "summarize-map-data" begin

    @testset "histQuantile: quartiles of a uniform 1:100 sample" begin
        oh = StreamHist(; binRange = (1.0, 100.0), binNum = 99)
        add!(oh, collect(1.0:100.0))
        finalize!(oh)

        mn, inRangeMin = histQuantile(oh, 0.0)
        md, inRangeMd = histQuantile(oh, 0.5)
        mx, inRangeMax = histQuantile(oh, 1.0)
        @test mn == 1.0
        @test mx == 100.0
        @test isapprox(md, 50.5; atol = 2.0)
        @test inRangeMin && inRangeMd && inRangeMax
    end

    @testset "histQuantile: a quantile landing in the tail bucket is flagged inRange = false" begin
        # lo = 10 is fixed narrower than the data, so the 9 points below it
        # (1..9) land in the underflow bucket rather than a regular bin.
        oh = StreamHist(; binRange = (10.0, 95.0), binNum = 50)
        add!(oh, collect(1.0:100.0))
        finalize!(oh)

        uf, of = outofrange(oh)
        @test uf == 9
        @test of == 6   # 95..100 fall at/above hi = 95 (closed = :left, so hi itself is out of range)

        val, inRange = histQuantile(oh, 0.03)   # target rank 3, inside the 9-point underflow bucket
        @test !inRange
        @test 1.0 <= val <= 10.0
    end

    @testset "ashQuantileGap: nothing in integer mode, small for a symmetric sample" begin
        ohInt = StreamHist(; integer = true, binRange = (1.0, 10.0))
        add!(ohInt, collect(1.0:10.0))
        finalize!(ohInt)
        val, _ = histQuantile(ohInt, 0.5)
        @test ashQuantileGap(ohInt, 0.5, val) === nothing

        oh = StreamHist(; binRange = (0.0, 100.0), binNum = 50)
        add!(oh, collect(0.5:1.0:99.5))   # evenly spaced, no under/overflow
        finalize!(oh)
        val, inRange = histQuantile(oh, 0.5)
        @test inRange
        gap = ashQuantileGap(oh, 0.5, val)
        @test gap !== nothing
        @test abs(gap) < 0.05
    end

    @testset "fieldSummaryLines: warns when out-of-range fraction exceeds threshold" begin
        oh = StreamHist(; binRange = (10.0, 95.0), binNum = 50)
        add!(oh, collect(1.0:100.0))   # 9 below lo, 6 at/above hi -- 15% out of range
        finalize!(oh)

        lines = fieldSummaryLines(oh)
        @test any(occursin("out of the histogram range", l) for l in lines)
    end

    @testset "fieldSummaryLines: no warnings for a well-behaved uniform sample" begin
        oh = StreamHist(; binRange = (0.0, 100.0), binNum = 50)
        add!(oh, collect(0.5:1.0:99.5))
        finalize!(oh)

        lines = fieldSummaryLines(oh)
        @test !any(occursin("WARNING", l) for l in lines)
    end

    @testset "run_summarize_map_data: end-to-end against the atlas own field data" begin
        src = joinpath(@__DIR__, "..", "examples", "cycleWalk_ct_slice.jsonl.gz")

        a = openAtlas(smartOpen(src, "r"))
        total = 0; while !eof(a); nextMap(a); total += 1; end; close(a)

        hists, nMaps = mapDataHistograms(src; sortVals = true, quiet = true)
        @test nMaps == total

        out = capture_stdout() do
            run_summarize_map_data(src; quiet = true)
        end
        @test occursin("Maps considered: $total", out)
        for field in keys(hists)
            @test occursin(field * ":", out)
        end

        # The printed scalar-field mean matches the histogram's own mean exactly
        # (the CLI prints it, it does not recompute it).
        field = "get_log_spanning_forests"
        @test occursin("mean: $(mean(hists[field]))", out)
    end

    @testset "--max-maps limits the maps considered" begin
        src = joinpath(@__DIR__, "..", "examples", "cycleWalk_ct_slice.jsonl.gz")
        out = capture_stdout() do
            run_summarize_map_data(src; max_maps = 5, quiet = true)
        end
        @test occursin("Maps considered: 5", out)

        @test_throws ErrorException run_summarize_map_data(src; max_maps = -1, quiet = true)
    end

    @testset "vector field indices are printed sorted (order-statistic order)" begin
        src = joinpath(@__DIR__, "..", "examples", "cycleWalk_ct_slice.jsonl.gz")
        hists, _ = mapDataHistograms(src; sortVals = true, quiet = true)
        field = "get_isoperimetric_scores"
        w = length(hists[field])

        out = capture_stdout() do
            run_summarize_map_data(src; quiet = true)
        end
        for j in 1:w
            @test occursin("[$j]", out)
        end
        # sortVals means the per-index minimums are nondecreasing across the width.
        mins = [datarange(hists[field][j])[1] for j in 1:w]
        @test issorted(mins)
    end

end
