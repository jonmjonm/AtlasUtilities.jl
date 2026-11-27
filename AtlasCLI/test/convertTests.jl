# `mapatlas convert`.

"Every map of the atlas at `path`, and the atlas itself (for its header fields)."
function convertReadall(path)
    io = smartOpen(path, "r")
    atlas = openAtlas(io)
    out = Map[]
    while !eof(atlas)
        push!(out, nextMap(atlas))
    end
    close(io)
    return atlas, out
end

@testset "mapatlas convert" begin
    dir = mktempdir()
    ct = joinpath(@__DIR__, "..", "..", "examples", "cycleWalk_ct_slice.jsonl.gz")

    @testset "v1 <-> v2" begin
        out = joinpath(dir, "cli_v2.jsonl")
        @test command_main(["convert", ct, out, "--to", "2", "--quiet"]) == 0
        @test convertReadall(out)[1].formatVersion == "2"
        out1 = joinpath(dir, "cli_v1.jsonl.bz2")
        @test command_main(["convert", out, out1, "--to", "1", "--quiet"]) == 0
        @test [m.districting for m in convertReadall(out1)[2]] == [m.districting for m in convertReadall(ct)[2]]
    end

    @testset "--to must be 1 or 2" begin
        @test_throws ErrorException command_main(["convert", ct, joinpath(dir, "x.jsonl"), "--to", "3"])
    end
end
