# `atlas convert`, and `relabel`/`add` on format v2 atlases (AtlasIO 0.2.2). Uses NODES/mkmap/labelsof from
# runtests.jl.
using AtlasUtilities: run_convert, run_relabel, run_add, command_main

"Every map of the atlas at `path`, and the atlas itself (for its header fields)."
function readall(path)
    io = smartOpen(path, "r")
    atlas = openAtlas(io)
    out = Map[]
    while !eof(atlas)
        push!(out, nextMap(atlas))
    end
    close(io)
    return atlas, out
end

@testset "convert and format v2" begin
    dir = mktempdir()
    ct = joinpath(@__DIR__, "..", "examples", "cycleWalk_ct_slice.jsonl.gz")

    @testset "atlas convert: v1 -> v2 -> v1 keeps every map" begin
        v2, back = joinpath(dir, "ct_v2.jsonl.gz"), joinpath(dir, "ct_back.jsonl")
        n = run_convert(ct, v2; to = 2, quiet = true)
        a1, m1 = readall(ct)
        a2, m2 = readall(v2)
        @test n == length(m1) > 0
        @test a1.formatVersion == "1" && a2.formatVersion == "2"
        @test [m.districting for m in m2] == [m.districting for m in m1]
        @test [m.data for m in m2] == [m.data for m in m1]
        @test a2.atlasParam == a1.atlasParam
        run_convert(v2, back; to = 1, quiet = true)
        a3, m3 = readall(back)
        @test a3.formatVersion == "1"
        @test [m.districting for m in m3] == [m.districting for m in m1]
        @test_throws ErrorException run_convert(ct, joinpath(dir, "x.jsonl"); to = 3, quiet = true)
    end

    @testset "atlas convert: the command line" begin
        out = joinpath(dir, "cli_v2.jsonl")
        @test command_main(["convert", ct, out, "--to", "2", "--quiet"]) == 0
        @test readall(out)[1].formatVersion == "2"
        out1 = joinpath(dir, "cli_v1.jsonl.bz2")
        @test command_main(["convert", out, out1, "--to", "1", "--quiet"]) == 0
        @test [m.districting for m in readall(out1)[2]] == [m.districting for m in readall(ct)[2]]
    end

    @testset "relabel keeps a v2 atlas in v2 (not a mixed file)" begin
        src1, src2 = joinpath(dir, "r_v1.jsonl"), joinpath(dir, "r_v2.jsonl")
        io = smartOpen(src1, "w")
        newAtlas(io, AtlasHeader("t", Dict{String,Any}, Dict{String,Any}), Dict{String,Any}("districts" => 2))
        for (k, l) in enumerate([[1, 1, 2, 2], [2, 2, 1, 1], [1, 2, 2, 1]])
            addMap(io, mkmap("m$k", l))
        end
        close(io)
        run_convert(src1, src2; to = 2, quiet = true)
        out1, out2 = joinpath(dir, "r_out_v1.jsonl"), joinpath(dir, "r_out_v2.jsonl.gz")
        run_relabel(src1, out1; quiet = true, cores = 1)
        run_relabel(src2, out2; quiet = true, cores = 1)
        a2, m2 = readall(out2)                   # reading a mixed file would raise AtlasFormatError
        @test a2.formatVersion == "2"
        @test [labelsof(m) for m in m2] == [labelsof(m) for m in readall(out1)[2]]
        @test labelsof(m2[2]) == [1, 1, 2, 2]    # the label swap was undone
    end

    @testset "add keeps a v2 atlas in v2 (not a mixed file)" begin
        graph = joinpath(@__DIR__, "..", "Data", "CT_pct20.json")
        ct2 = joinpath(dir, "ct2.jsonl.gz")
        run_convert(ct, ct2; to = 2, quiet = true)
        kw = (graph = graph, pop_col = "POP20", node_col = "NAME", vote_cols = "G20PREDEM,G20PREREP",
              overwrite = true, quiet = true)
        out1, out2 = joinpath(dir, "add_v1.jsonl.gz"), joinpath(dir, "add_v2.jsonl.gz")
        run_add("get_partisan_margins", ct, out1; kw...)
        run_add("get_partisan_margins", ct2, out2; kw...)
        a2, m2 = readall(out2)
        _, m1 = readall(out1)
        @test a2.formatVersion == "2"
        @test [m.districting for m in m2] == [m.districting for m in m1]
        @test [m.data for m in m2] == [m.data for m in m1]
    end
end
