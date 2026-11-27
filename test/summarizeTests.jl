# Tests for the `atlas summarize-map-data` subcommand (src/summarize.jl):
# the histogram-based quantile estimator, its ASH cross-check, the
# warning-producing summary lines, and an end-to-end run against a real atlas.
# capture_stdout is defined in infoTests.jl, included before this file (see
# runtests.jl).

using Test
using AtlasIO
using StreamHistogram: StreamingHistogram, add!, finalize!, nobs, datarange, outofrange, mean, std, quantile
using AtlasUtilities: summarizeMapData, MapDataSummary, FieldSummary, quartiles, ashQuantileGap, fieldSummaryLines,
                      mapDataHistograms

@testset "summarize-map-data" begin

    # The quantile estimates themselves are StreamHistogram's (tested there); `quartiles` adds the ASH check.
    @testset "quartiles: StreamHistogram's quantiles, the ASH checked only inside the range" begin
        oh = StreamingHistogram(; binRange = (1.0, 100.0), binNum = 99)
        add!(oh, collect(1.0:100.0))
        finalize!(oh)
        qs, gap = quartiles(oh)
        @test qs == quantile(oh, [0.25, 0.5, 0.75])
        @test isapprox(qs[2], 50.5; atol = 2.0)
        @test gap !== nothing && abs(gap) < 0.05

        # every quartile among the out-of-range values: nothing for the density to check
        out = StreamingHistogram(; binRange = (1000.0, 2000.0), binNum = 10)
        add!(out, collect(1.0:100.0))
        finalize!(out)
        qs, gap = quartiles(out)
        @test all(<(1000.0), qs) && gap === nothing
    end

    @testset "ashQuantileGap: nothing in integer mode, small for a symmetric sample" begin
        ohInt = StreamingHistogram(; integer = true, binRange = (1.0, 10.0))
        add!(ohInt, collect(1.0:10.0))
        finalize!(ohInt)
        @test ashQuantileGap(ohInt, 0.5, quantile(ohInt, 0.5)) === nothing

        oh = StreamingHistogram(; binRange = (0.0, 100.0), binNum = 50)
        add!(oh, collect(0.5:1.0:99.5))   # evenly spaced, no under/overflow
        finalize!(oh)
        gap = ashQuantileGap(oh, 0.5, quantile(oh, 0.5))
        @test gap !== nothing
        @test abs(gap) < 0.05
    end

    @testset "fieldSummaryLines: warns when out-of-range fraction exceeds threshold" begin
        oh = StreamingHistogram(; binRange = (10.0, 95.0), binNum = 50)
        add!(oh, collect(1.0:100.0))   # 9 below lo, 6 at/above hi -- 15% out of range
        finalize!(oh)

        lines = fieldSummaryLines(oh)
        @test any(occursin("out of the histogram range", l) for l in lines)
    end

    @testset "fieldSummaryLines: no warnings for a well-behaved uniform sample" begin
        oh = StreamingHistogram(; binRange = (0.0, 100.0), binNum = 50)
        add!(oh, collect(0.5:1.0:99.5))
        finalize!(oh)

        lines = fieldSummaryLines(oh)
        @test !any(occursin("WARNING", l) for l in lines)
    end

    @testset "summarizeMapData: end-to-end against the atlas own field data" begin
        src = joinpath(@__DIR__, "..", "examples", "cycleWalk_ct_slice.jsonl.gz")

        a = openAtlas(smartOpen(src, "r"))
        total = 0; while !eof(a); nextMap(a); total += 1; end; close(a)

        hists, nMaps = mapDataHistograms(src; sort_values = true)
        @test nMaps == total

        out = capture_stdout() do
            show(stdout, MIME"text/plain"(), summarizeMapData(src))
        end
        @test occursin("Maps considered: $total", out)
        s = summarizeMapData(src)                                    # the result, as data
        @test s isa MapDataSummary && s.nmaps == total && Set(keys(s.fields)) == Set(keys(hists))
        @test s.fields["get_log_spanning_forests"] isa FieldSummary
        @test s.fields["get_log_spanning_forests"].unweighted.mean == mean(hists["get_log_spanning_forests"])
        @test length(s.fields["get_isoperimetric_scores"]) == length(hists["get_isoperimetric_scores"])
        @test sprint(show, MIME"text/plain"(), s) == out
        @test sprint(print, s) == "MapDataSummary($total maps, $(length(hists)) fields)"   # one line
        @test repr([s]) == "MapDataSummary[MapDataSummary($total maps, $(length(hists)) fields)]"   # not the report
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
            show(stdout, MIME"text/plain"(), summarizeMapData(src; max_maps = 5))
        end
        @test occursin("Maps considered: 5", out)

        @test_throws ErrorException summarizeMapData(src; max_maps = -1)
    end

    @testset "vector field indices are printed sorted (order-statistic order)" begin
        src = joinpath(@__DIR__, "..", "examples", "cycleWalk_ct_slice.jsonl.gz")
        hists, _ = mapDataHistograms(src; sort_values = true)
        field = "get_isoperimetric_scores"
        w = length(hists[field])

        out = capture_stdout() do
            show(stdout, MIME"text/plain"(), summarizeMapData(src))
        end
        for j in 1:w
            @test occursin("[$j]", out)
        end
        # sort_values means the per-index minimums are nondecreasing across the width.
        mins = [datarange(hists[field][j])[1] for j in 1:w]
        @test issorted(mins)
    end

end
