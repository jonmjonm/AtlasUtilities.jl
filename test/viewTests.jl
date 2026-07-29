# Tests for the `atlas view` subcommand (src/view.jl). Only the pieces that run
# before any GLMakie window is created are exercised here (`loadAllMaps`, and
# `run_view`'s upfront validation/matching) -- actually opening an interactive window
# is exercised manually, not in the automated suite.

using Test
using AtlasUtilities: run_view, loadAllMaps

const CT_ATLAS = joinpath(@__DIR__, "..", "examples", "cycleWalk_ct_slice.jsonl.gz")
const GRID_GRAPH = joinpath(@__DIR__, "..", "Data", "grid_graph_10_by_10.json")

@testset "view" begin

    @testset "loadAllMaps: reads every map, in order" begin
        dir = mktempdir()
        atlasPath = joinpath(dir, "three.jsonl")
        io = smartOpen(atlasPath, "w")
        newAtlas(io, AtlasHeader("t", "2026-01-02T03:04:05", Dict{String,Any}, Dict{String,Any}),
                 Dict{String,Any}("districts" => 1))
        for k in 1:3
            addMap(io, Map("m$k", Districting(("a",) => 1), 1, Dict{String,Any}()))
        end
        close(io)

        maps = loadAllMaps(atlasPath)
        @test length(maps) == 3
        @test [m.name for m in maps] == ["m1", "m2", "m3"]
    end

    @testset "loadAllMaps: errors on an atlas with no maps" begin
        dir = mktempdir()
        atlasPath = joinpath(dir, "empty.jsonl")
        io = smartOpen(atlasPath, "w")
        newAtlas(io, AtlasHeader("t", "2026-01-02T03:04:05", Dict{String,Any}, Dict{String,Any}),
                 Dict{String,Any}("districts" => 1))
        close(io)
        @test_throws ErrorException loadAllMaps(atlasPath)
    end

    @testset "run_view: --map must be >= 1" begin
        @test_throws ErrorException run_view(CT_ATLAS, GRID_GRAPH; key = "node_name", map = 0)
    end

    @testset "run_view: --delay must be >= 10" begin
        @test_throws ErrorException run_view(CT_ATLAS, GRID_GRAPH; key = "node_name", delay = 1)
    end

    @testset "run_view: requires --key" begin
        @test_throws ErrorException run_view(CT_ATLAS, GRID_GRAPH; map = 1)
    end

    @testset "run_view: --map out of range for the atlas errors before opening a window" begin
        @test_throws ErrorException run_view(CT_ATLAS, GRID_GRAPH; key = "node_name", map = 10_000)
    end

    @testset "run_view: no node id matches any geometry record errors before opening a window" begin
        # The CT atlas's node ids don't match the grid graph's "(r,c)" node names at all.
        @test_throws ErrorException run_view(CT_ATLAS, GRID_GRAPH; key = "node_name")
    end

end
