# `convertAtlas`, and `relabelAtlas` on format v2 atlases (AtlasIO 0.2.2). Uses NODES/mkmap/labelsof from
# runtests.jl.
using AtlasUtilities: relabelAtlas

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
        n = convertAtlas(ct, v2; formatVersion = 2)
        a1, m1 = readall(ct)
        a2, m2 = readall(v2)
        @test n == length(m1) > 0
        @test a1.formatVersion == "1" && a2.formatVersion == "2"
        @test [m.districting for m in m2] == [m.districting for m in m1]
        @test [m.data for m in m2] == [m.data for m in m1]
        @test a2.atlasParam == a1.atlasParam
        convertAtlas(v2, back; formatVersion = 1)
        a3, m3 = readall(back)
        @test a3.formatVersion == "1"
        @test [m.districting for m in m3] == [m.districting for m in m1]
        @test_throws Exception convertAtlas(ct, joinpath(dir, "x.jsonl"); formatVersion = 3)
    end

    @testset "relabel keeps a v2 atlas in v2 (not a mixed file)" begin
        src1, src2 = joinpath(dir, "r_v1.jsonl"), joinpath(dir, "r_v2.jsonl")
        io = smartOpen(src1, "w")
        newAtlas(io, AtlasHeader("t", Dict{String,Any}, Dict{String,Any}), Dict{String,Any}("districts" => 2))
        for (k, l) in enumerate([[1, 1, 2, 2], [2, 2, 1, 1], [1, 2, 2, 1]])
            addMap(io, mkmap("m$k", l))
        end
        close(io)
        convertAtlas(src1, src2; formatVersion = 2)
        out1, out2 = joinpath(dir, "r_out_v1.jsonl"), joinpath(dir, "r_out_v2.jsonl.gz")
        relabelAtlas(src1, out1; cores = 1)
        relabelAtlas(src2, out2; cores = 1)
        a2, m2 = readall(out2)                   # reading a mixed file would raise AtlasFormatError
        @test a2.formatVersion == "2"
        @test [labelsof(m) for m in m2] == [labelsof(m) for m in readall(out1)[2]]
        @test labelsof(m2[2]) == [1, 1, 2, 2]    # the label swap was undone
    end

end
