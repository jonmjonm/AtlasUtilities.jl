# Tests for the node ids of a map (src/nodes.jl).

using Test
using AtlasIO
using AtlasUtilities: nodeIdString, listNodes

"""Write an atlas at `path` with one map per entry of `districtings`
(named m1, m2, ...)."""
function writeNodesAtlas(path, districtings)
    io = smartOpen(path, "w")
    newAtlas(io, AtlasHeader("desc", "2026-01-02T03:04:05", Dict{String,Any}, Dict{String,Any}),
             Dict{String,Any}("districts" => 2))
    for (k, dist) in enumerate(districtings)
        addMap(io, Map("m$k", dist, 1, Dict{String,Any}()))
    end
    close(io)
end

@testset "list-nodes" begin

    @testset "nodeIdString: joins tuple components with ':'" begin
        @test nodeIdString(("41063",)) == "41063"
        @test nodeIdString(("county", "tract")) == "county:tract"
    end

    @testset "listNodes: sorted ids of the first map, or of map `map`; multiscale ids joined with ':'" begin
        path = joinpath(mktempdir(), "a.jsonl")
        writeNodesAtlas(path, [Districting(("c",) => 1, ("a",) => 1, ("b",) => 2),
                               Districting(("X", "2") => 1, ("X", "1") => 1, ("Y", "1") => 2)])
        @test listNodes(path) == ["a", "b", "c"]
        @test listNodes(path; map = 2) == ["X:1", "X:2", "Y:1"]
    end

    @testset "listNodes: errors past the last map, for map < 1, and on an atlas with no maps" begin
        dir = mktempdir()
        path, none = joinpath(dir, "a.jsonl"), joinpath(dir, "none.jsonl")
        writeNodesAtlas(path, [Districting(("a",) => 1)])
        writeNodesAtlas(none, Districting[])
        @test_throws ErrorException listNodes(path; map = 2)
        @test_throws ErrorException listNodes(path; map = 0)
        @test_throws ErrorException listNodes(none)
    end

end
