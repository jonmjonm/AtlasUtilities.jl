# Integration tests for AtlasUtilities' use of AtlasIO's parallel byte-targeted gzip
# atlas output. The invariant: a `.gz` result from `run_add`/`run_relabel` is a valid
# multi-member gzip that the system `gunzip` accepts and that AtlasIO reads back with
# the same maps as an uncompressed (`.jsonl`) run. (The low-level writer -- AtlasOutput,
# writeGzipMembers!, groupByBytes -- is unit-tested in AtlasIO itself.)

using Test
using AtlasIO
using AtlasUtilities: run_add, run_relabel

@testset "parallel-gzip output (via AtlasIO)" begin

    readmaps(p) = (a = openAtlas(smartOpen(p, "r")); ms = Map[];
                   while !eof(a); push!(ms, nextMap(a)); end; close(a); ms)
    asvec(x) = x isa AbstractVector ? Float64.(x) : [Float64(x)]
    # a gzip member starts with magic 1f 8b; our writer emits >=2 (header + body)
    countMembers(path) = (b = read(path); count(i -> b[i] == 0x1f && b[i+1] == 0x8b, 1:(length(b)-1)))

    # --- run_add: .gz output == plain output -------------------------------------
    graph = joinpath(@__DIR__, "..", "Data", "CT_pct20.json")
    oracle = joinpath(@__DIR__, "..", "examples", "cycleWalk_ct_slice.jsonl.gz")
    addkw = (graph = graph, pop_col = "POP20", node_col = "NAME", area_col = "area",
             border_col = "border_length", edge_perimeter_col = "length",
             node_data = "COUNTY,NAME,POP20,area,border_length",
             overwrite = true, quiet = true)

    @testset "run_add: .gz output == plain output" begin
        dir = mktempdir()
        A2gz = joinpath(dir, "out.jsonl.gz")
        A2plain = joinpath(dir, "out.jsonl")
        run_add("get_log_spanning_trees", oracle, A2gz; addkw...)
        run_add("get_log_spanning_trees", oracle, A2plain; addkw...)

        @test success(`gzip -t $A2gz`)        # system gunzip accepts it
        @test countMembers(A2gz) >= 2         # multi-member (header + body)

        gz, pl = readmaps(A2gz), readmaps(A2plain)
        @test length(gz) == length(pl) >= 40
        for (mg, mp) in zip(gz, pl)
            @test mg.name == mp.name
            @test asvec(mg.data["get_log_spanning_trees"]) == asvec(mp.data["get_log_spanning_trees"])
        end
    end

    # --- run_relabel: .gz output == plain output on a small-map atlas ------------
    @testset "run_relabel: .gz output == plain output" begin
        demo = joinpath(@__DIR__, "..", "examples", "demo_grid_4x4.jsonl.gz")
        dir = mktempdir()
        A2gz = joinpath(dir, "rel.jsonl.gz")
        A2plain = joinpath(dir, "rel.jsonl")
        run_relabel(demo, A2gz; quiet = true)
        run_relabel(demo, A2plain; quiet = true)

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
