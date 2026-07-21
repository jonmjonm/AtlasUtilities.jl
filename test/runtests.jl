using Test
using AtlasIO
using AtlasUtilities
using AtlasUtilities: reOrder, relabelMap, run_reorder, loadHierarchy, loadPopulation, expandLabels, BATCH,
                       hammingDistance, confusionMatrix

# Fixed node-key set shared by all test maps.
const NODES = [("a",), ("b",), ("c",), ("dd",)]

"""Build a Map from a vector of district labels in NODES order."""
mkmap(name, labels; w = 1, data = Dict{String,Any}()) =
    Map(name, Districting(NODES[i] => labels[i] for i in eachindex(NODES)), w, data)

"""Labels of a map read back in NODES order."""
labelsof(m) = [m.districting[n] for n in NODES]

"""The partition (set of district node-sets) induced by a label vector over NODES."""
partition(labels) = Set(Set(i for i in eachindex(labels) if labels[i] == d)
                        for d in unique(labels))

@testset "reorder" begin

    @testset "reOrder: identical maps give identity permutation" begin
        m = mkmap("m", [1, 1, 2, 2])
        @test reOrder(m, m, 2) == [1, 2]
    end

    @testset "reOrder: detects and undoes a label swap" begin
        ref = mkmap("ref", [1, 1, 2, 2])
        cur = mkmap("cur", [2, 2, 1, 1])      # same partition, labels swapped
        σ = reOrder(ref, cur, 2)
        @test σ == [2, 1]
        @test labelsof(relabelMap(cur, σ)) == labelsof(ref)   # exact realignment, distance 0
    end

    @testset "reOrder: finds an optimal (min-Hamming) alignment" begin
        # ref: {a,b,c}=1, {dd}=2 ;  cur: {a,b}=2, {c,dd}=1
        ref = mkmap("ref", [1, 1, 1, 2])
        cur = mkmap("cur", [2, 2, 1, 1])
        σ = reOrder(ref, cur, 2)
        # Best match: cur-label-2 -> 1 (overlap {a,b}=2), cur-label-1 -> 2 (overlap {dd}=1).
        @test σ == [2, 1]
    end

    @testset "reOrder: population weighting can flip the optimal alignment" begin
        # ref: {a,b,c}=1, {dd}=2 ;  cur: {a,b}=2, {c,dd}=1
        # Unweighted: cur-label-2 -> 1 (overlap {a,b}=2 nodes) wins over cur-label-1 -> 1 (overlap {c}=1 node).
        # Weight "dd" heavily so the {c,dd} overlap with ref-label-1 (via "c") is no longer decisive;
        # instead weight "c" heavily so cur-label-1 (covering {c,dd}) becomes the better match for ref-label-1.
        ref = mkmap("ref", [1, 1, 1, 2])
        cur = mkmap("cur", [2, 2, 1, 1])
        pop = Dict(("a",) => 1, ("b",) => 1, ("c",) => 100, ("dd",) => 1)
        σ_unweighted = reOrder(ref, cur, 2)
        σ_weighted = reOrder(ref, cur, 2; pop)
        @test σ_unweighted == [2, 1]   # baseline from the test above
        @test σ_weighted == [1, 2]     # heavy "c" pulls cur-label-1 to ref-label-1
    end

    @testset "hammingDistance: matches brute-force symmetric-difference sum" begin
        bruteForce(refLabels, curLabels) = sum(
            length(symdiff(Set(i for i in eachindex(refLabels) if refLabels[i] == ℓ),
                            Set(i for i in eachindex(curLabels) if curLabels[i] == ℓ)))
            for ℓ in 1:2
        )
        ref = mkmap("ref", [1, 1, 1, 2])
        cur = mkmap("cur", [2, 2, 1, 1])
        @test hammingDistance(ref, cur, 2) == bruteForce([1, 1, 1, 2], [2, 2, 1, 1])
        @test hammingDistance(ref, ref, 2) == 0                    # identical maps: zero distance
    end

    @testset "hammingDistance: population weighting scales mismatches by population" begin
        ref = mkmap("ref", [1, 1, 1, 2])
        cur = mkmap("cur", [2, 2, 1, 1])
        # symdiff at label 1: {a,b,c} Δ {c,dd} = {a,b,dd}; at label 2: {dd} Δ {a,b} = {a,b,dd}. Total 6.
        @test hammingDistance(ref, cur, 2) == 6
        # Weight "a" heavily: it now dominates both symmetric differences.
        pop = Dict(("a",) => 10, ("b",) => 1, ("c",) => 1, ("dd",) => 1)
        @test hammingDistance(ref, cur, 2; pop) == 24
    end

    @testset "confusionMatrix: shared between reOrder and hammingDistance" begin
        ref = mkmap("ref", [1, 1, 1, 2])
        cur = mkmap("cur", [2, 2, 1, 1])
        O = confusionMatrix(ref, cur, 2)
        @test AtlasUtilities.permutationFromConfusion(O, 2) == reOrder(ref, cur, 2)
        @test AtlasUtilities.hammingDistanceFromConfusion(O) == hammingDistance(ref, cur, 2)
    end

    @testset "reOrder: errors clearly on mismatched node sets (multiscale)" begin
        ref = mkmap("ref", [1, 1, 2, 2])
        # cur expressed over a different node set (missing "dd", extra "e")
        cur = Map("cur", Districting(("a",) => 1, ("b",) => 2, ("c",) => 2, ("e",) => 1),
                  1, Dict{String,Any}())
        @test_throws ErrorException reOrder(ref, cur, 2)
    end

    @testset "relabel preserves name/weight/data and permutes labels" begin
        cur = mkmap("foo", [1, 2, 2, 1]; w = 7, data = Dict{String,Any}("x" => 3))
        r = relabelMap(cur, [2, 1])
        @test r.name == "foo"
        @test r.weight == 7
        @test r.data == Dict{String,Any}("x" => 3)
        @test labelsof(r) == [2, 1, 1, 2]
    end

    @testset "relabel never changes the induced partition" begin
        cur = mkmap("p", [1, 2, 2, 1])
        r = relabelMap(cur, reOrder(mkmap("ref", [1, 1, 2, 2]), cur, 2))
        @test partition(labelsof(r)) == partition(labelsof(cur))
    end

    # --- helpers for end-to-end tests ---
    function buildatlas(path, srclabels)
        io = smartOpen(path, "w")
        newAtlas(io, AtlasHeader("t", Dict{String,Any}, Dict{String,Any}),
                 Dict{String,Any}("districts" => 2))
        for (k, l) in enumerate(srclabels)
            addMap(io, mkmap("m$k", l))
        end
        close(io)
    end

    function readatlas(path)
        io = smartOpen(path, "r")
        atlas = openAtlas(io)
        out = Map[]
        while !eof(atlas)
            push!(out, nextMap(atlas))
        end
        close(atlas)
        return out
    end

    @testset "end-to-end: default (chained) mode" begin
        dir = mktempdir()
        Atlas1, Atlas2 = joinpath(dir, "Atlas1.jsonl"), joinpath(dir, "Atlas2.jsonl")
        src = [[1, 1, 2, 2], [2, 2, 1, 1], [1, 2, 2, 1]]
        buildatlas(Atlas1, src)

        run_reorder(Atlas1, Atlas2; quiet = true, cores = 1)
        out = readatlas(Atlas2)

        @test length(out) == 3
        @test [m.name for m in out] == ["m1", "m2", "m3"]
        @test labelsof(out[1]) == [1, 1, 2, 2]                 # anchor verbatim
        @test labelsof(out[2]) == [1, 1, 2, 2]                 # m2 swap undone -> equals m1
        for k in 1:3                                            # relabeling preserves partitions
            @test partition(labelsof(out[k])) == partition(src[k])
        end
    end

    @testset "end-to-end: --firstMap mode" begin
        dir = mktempdir()
        Atlas1, Atlas2 = joinpath(dir, "Atlas1.jsonl"), joinpath(dir, "Atlas2.jsonl")
        src = [[1, 1, 2, 2], [2, 2, 1, 1], [1, 2, 2, 1]]
        buildatlas(Atlas1, src)

        run_reorder(Atlas1, Atlas2; firstMap = true, quiet = true, cores = 1)
        out = readatlas(Atlas2)

        @test length(out) == 3
        @test labelsof(out[1]) == [1, 1, 2, 2]                 # anchor verbatim
        for k in 1:3
            @test partition(labelsof(out[k])) == partition(src[k])
        end
    end

    @testset "multiscale: dual-graph hierarchy resolves varying node sets" begin
        dir = mktempdir()
        gpath = joinpath(dir, "graph.json")
        write(gpath, """{"directed":false,"multigraph":false,"graph":[],"nodes":[
            {"id":0,"county":"X","prec":"1"},
            {"id":1,"county":"X","prec":"2"},
            {"id":2,"county":"Y","prec":"1"},
            {"id":3,"county":"Y","prec":"2"}]}""")

        # Maps at MIXED resolutions: m1 coarse (county-level), m2/m3 fine.
        src = [Districting(("X",) => 1, ("Y",) => 2),                              # coarse
               Districting(("X","1")=>2, ("X","2")=>2, ("Y","1")=>1, ("Y","2")=>1), # same partition, swapped
               Districting(("X","1")=>1, ("X","2")=>2, ("Y","1")=>2, ("Y","2")=>1)] # different partition

        Atlas1, Atlas2 = joinpath(dir, "Atlas1.jsonl"), joinpath(dir, "Atlas2.jsonl")
        io = smartOpen(Atlas1, "w")
        newAtlas(io, AtlasHeader("ms", Dict{String,Any}, Dict{String,Any}),
                 Dict{String,Any}("districts" => 2, "levels in graph" => ["county", "prec"]))
        for (k, dist) in enumerate(src)
            addMap(io, Map("m$k", dist, 1, Dict{String,Any}()))
        end
        close(io)

        run_reorder(Atlas1, Atlas2, gpath; quiet = true, cores = 1)
        out = readatlas(Atlas2)
        h = loadHierarchy(gpath, ["county", "prec"])

        @test length(out) == 3
        @test out[1].districting == src[1]                                  # anchor verbatim (still coarse)
        @test expandLabels(h, out[2].districting) == expandLabels(h, src[1]) # swap undone at finest level
        for k in 1:3                                                         # pure relabeling of each source
            @test partition(expandLabels(h, out[k].districting)) == partition(expandLabels(h, src[k]))
        end
    end

    @testset "multiscale: population weighting resolves to finest units" begin
        dir = mktempdir()
        gpath = joinpath(dir, "graph.json")
        write(gpath, """{"directed":false,"multigraph":false,"graph":[],"nodes":[
            {"id":0,"county":"X","prec":"1","pop2020cen":1},
            {"id":1,"county":"X","prec":"2","pop2020cen":1},
            {"id":2,"county":"Y","prec":"1","pop2020cen":100},
            {"id":3,"county":"Y","prec":"2","pop2020cen":1}]}""")
        levels = ["county", "prec"]

        pop = loadPopulation(gpath, levels, "pop2020cen")
        @test pop[("X","1")] == 1 && pop[("Y","1")] == 100

        h = loadHierarchy(gpath, levels)
        # Mirrors the fixed-node-set weighting test above ("Y","1") plays the role of "c",
        # but here cur represents the whole Y county as one coarse node.
        ref = Districting(("X","1")=>1, ("X","2")=>1, ("Y","1")=>1, ("Y","2")=>2)
        cur = Districting(("X","1")=>2, ("X","2")=>2, ("Y",)=>1)
        refMap, curMap = Map("ref", ref, 1, Dict{String,Any}()), Map("cur", cur, 1, Dict{String,Any}())

        @test reOrder(refMap, curMap, 2, h) == [2, 1]            # unweighted baseline
        @test reOrder(refMap, curMap, 2, h; pop) == [1, 2]       # heavy ("Y","1") flips the match
    end

    @testset "progress bar path (no --quiet) runs and is correct" begin
        dir = mktempdir()
        Atlas1, Atlas2 = joinpath(dir, "Atlas1.jsonl"), joinpath(dir, "Atlas2.jsonl")
        buildatlas(Atlas1, [[1, 1, 2, 2], [2, 2, 1, 1], [1, 2, 2, 1]])
        run_reorder(Atlas1, Atlas2; cores = 1)       # progress enabled; must not error
        out = readatlas(Atlas2)
        @test length(out) == 3
        @test labelsof(out[2]) == [1, 1, 2, 2]
    end

    @testset "threaded batches: parallel output matches serial, order preserved" begin
        dir = mktempdir()
        Atlas1 = joinpath(dir, "Atlas1.jsonl")
        # Span several batches so the pipeline's batching/carry-over is exercised.
        nmaps = 2 * BATCH + 37
        src = [rand(1:2, 4) for _ in 1:nmaps]
        for v in src                          # ensure both districts are non-empty
            v[1] = 1; v[2] = 2
        end
        io = smartOpen(Atlas1, "w")
        newAtlas(io, AtlasHeader("t", Dict{String,Any}, Dict{String,Any}),
                 Dict{String,Any}("districts" => 2))
        for (k, v) in enumerate(src)
            addMap(io, mkmap("m$k", v))
        end
        close(io)

        # Compare an explicitly serial run against one using this process's full
        # thread count. Run the suite with `julia -t N` to exercise true parallelism.
        ser = joinpath(dir, "serial.jsonl"); par = joinpath(dir, "par.jsonl")
        run_reorder(Atlas1, ser; quiet = true, cores = 1)
        run_reorder(Atlas1, par; quiet = true, cores = Threads.nthreads())

        os, op = readatlas(ser), readatlas(par)
        @test length(os) == nmaps && length(op) == nmaps
        @test [m.name for m in op] == ["m$k" for k in 1:nmaps]            # order preserved
        @test all(k -> os[k].districting == op[k].districting, 1:nmaps)  # identical to serial
    end

end

include(joinpath(@__DIR__, "infoTests.jl"))
include(joinpath(@__DIR__, "nodesTests.jl"))
include(joinpath(@__DIR__, "assignmentsTests.jl"))
include(joinpath(@__DIR__, "addTests.jl"))
include(joinpath(@__DIR__, "extractTests.jl"))
include(joinpath(@__DIR__, "parallelTests.jl"))
include(joinpath(@__DIR__, "pargzipTests.jl"))
