# `addMapData` on a format v2 atlas. Uses `readall` from ../convertTests.jl.

using AtlasUtilities: addMapData

@testset "addMapData and format v2" begin
    dir = mktempdir()
    ct = joinpath(@__DIR__, "..", "..", "examples", "cycleWalk_ct_slice.jsonl.gz")

    @testset "add keeps a v2 atlas in v2 (not a mixed file)" begin
        graph = joinpath(@__DIR__, "..", "..", "Data", "CT_pct20.json")
        ct2 = joinpath(dir, "ct2.jsonl.gz")
        convertAtlas(ct, ct2; formatVersion = 2)
        kw = (graph = graph, pop_col = "POP20", node_col = "NAME", vote_cols = [("G20PREDEM", "G20PREREP")],
              overwrite = true)
        out1, out2 = joinpath(dir, "add_v1.jsonl.gz"), joinpath(dir, "add_v2.jsonl.gz")
        addMapData(ct, out1, ["get_partisan_margins"]; kw...)
        addMapData(ct2, out2, ["get_partisan_margins"]; kw...)
        a2, m2 = readall(out2)
        _, m1 = readall(out1)
        @test a2.formatVersion == "2"
        @test [m.districting for m in m2] == [m.districting for m in m1]
        @test [m.data for m in m2] == [m.data for m in m1]
    end
end
