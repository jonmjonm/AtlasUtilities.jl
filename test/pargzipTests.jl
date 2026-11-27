# Integration tests for AtlasUtilities' use of AtlasIO's parallel byte-targeted gzip
# atlas output. The invariant: a `.gz` result from `relabelAtlas` is a valid
# multi-member gzip that the system `gunzip` accepts and that AtlasIO reads back with
# the same maps as an uncompressed (`.jsonl`) run. (The low-level writer -- AtlasOutput,
# writeGzipMembers!, groupByBytes -- is unit-tested in AtlasIO itself.)

using Test
using AtlasIO
using AtlasUtilities: relabelAtlas

@testset "parallel-gzip output (via AtlasIO)" begin

    readmaps(p) = (a = openAtlas(smartOpen(p, "r")); ms = Map[];
                   while !eof(a); push!(ms, nextMap(a)); end; close(a); ms)
    asvec(x) = x isa AbstractVector ? Float64.(x) : [Float64(x)]
    # a gzip member starts with magic 1f 8b; our writer emits >=2 (header + body)
    countMembers(path) = (b = read(path); count(i -> b[i] == 0x1f && b[i+1] == 0x8b, 1:(length(b)-1)))

    # --- relabelAtlas: .gz output == plain output on a small-map atlas ------------
    @testset "relabelAtlas: .gz output == plain output" begin
        demo = joinpath(@__DIR__, "..", "examples", "demo_grid_4x4.jsonl.gz")
        dir = mktempdir()
        A2gz = joinpath(dir, "rel.jsonl.gz")
        A2plain = joinpath(dir, "rel.jsonl")
        relabelAtlas(demo, A2gz)
        relabelAtlas(demo, A2plain)

        @test success(`gzip -t $A2gz`)
        @test countMembers(A2gz) >= 2          # header member + anchor/body members

        gz, pl = readmaps(A2gz), readmaps(A2plain)
        @test length(gz) == length(pl) >= 4
        for (mg, mp) in zip(gz, pl)
            @test mg.name == mp.name
            @test mg.districting == mp.districting   # identical relabeling
        end
    end

end
