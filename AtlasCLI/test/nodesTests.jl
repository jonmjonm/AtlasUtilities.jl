# `mapatlas list-nodes`.

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

@testset "mapatlas list-nodes" begin

    @testset "mapatlas list-nodes: prints sorted JSON array for the first map by default" begin
        dir = mktempdir()
        path = joinpath(dir, "a.jsonl")
        writeNodesAtlas(path, [Districting(("c",) => 1, ("a",) => 1, ("b",) => 2)])

        out = capture_stdout() do
            cli_list_nodes(path)
        end

        @test JSON.parse(out) == ["a", "b", "c"]
    end

    @testset "mapatlas list-nodes: --map selects the k-th map (1-based)" begin
        dir = mktempdir()
        path = joinpath(dir, "a.jsonl")
        writeNodesAtlas(path, [
            Districting(("a",) => 1, ("b",) => 2),
            Districting(("x",) => 1, ("y",) => 2, ("z",) => 1),
        ])

        out = capture_stdout() do
            cli_list_nodes(path; map = 2)
        end

        @test JSON.parse(out) == ["x", "y", "z"]
    end

    @testset "mapatlas list-nodes: multiscale node ids joined with ':'" begin
        dir = mktempdir()
        path = joinpath(dir, "a.jsonl")
        writeNodesAtlas(path, [Districting(("X", "2") => 1, ("X", "1") => 1, ("Y", "1") => 2)])

        out = capture_stdout() do
            cli_list_nodes(path)
        end

        @test JSON.parse(out) == ["X:1", "X:2", "Y:1"]
    end

    @testset "mapatlas list-nodes: errors when map index exceeds the atlas's map count" begin
        dir = mktempdir()
        path = joinpath(dir, "a.jsonl")
        writeNodesAtlas(path, [Districting(("a",) => 1, ("b",) => 2)])

        @test_throws ErrorException cli_list_nodes(path; map = 2)
    end

    @testset "mapatlas list-nodes: errors on an atlas with no maps" begin
        dir = mktempdir()
        path = joinpath(dir, "a.jsonl")
        writeNodesAtlas(path, Districting[])

        @test_throws ErrorException cli_list_nodes(path)
    end

    @testset "mapatlas list-nodes: --map must be >= 1" begin
        dir = mktempdir()
        path = joinpath(dir, "a.jsonl")
        writeNodesAtlas(path, [Districting(("a",) => 1)])

        @test_throws ErrorException cli_list_nodes(path; map = 0)
    end

end
