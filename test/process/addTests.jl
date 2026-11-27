# Tests for writer evaluation (the CycleWalk extension): function
# resolution, graph-spec resolution (TOML + flag overrides), the header
# provenance stamp, and an end-to-end oracle test that recomputes a real
# CycleWalk atlas's map data and checks it reproduces CycleWalk's own values.

using Test
using AtlasIO
import JSON
using CycleWalk: get_log_spanning_trees, get_isoperimetric_scores
import CycleWalk
using AtlasUtilities: addMapData, loadGraph, listWriterDetails
# The writer internals live in the CycleWalk extension, loaded by `import CycleWalk` above.
const CWExt = Base.get_extension(AtlasUtilities, :AtlasUtilitiesCycleWalkExt)
using .CWExt: resolveFunctions, resolveGraphSpec, writeHeaderWithProvenance, GraphSpec, buildGraph,
              evalWriters, evalWritersTreeless, evalWritersLCP, allTreeless, hasFastMethod, voteColumns,
              cycleWalkWriterNames, PARTISAN_WRITERS, smokeTestPartition, writerWorks

# capture_stdout is defined in infoTests.jl, included before this file (see runtests.jl).

# resolveGraphSpec's keywords are all optional.
rgs(; kw...) = resolveGraphSpec("test"; kw...)

@testset "add" begin

    @testset "resolveFunctions" begin
        fns = resolveFunctions(["get_log_spanning_trees", "get_isoperimetric_scores"])
        @test [d for (d, _) in fns] == ["get_log_spanning_trees", "get_isoperimetric_scores"]
        @test fns[1][2] === get_log_spanning_trees
        @test fns[2][2] === get_isoperimetric_scores
        @test_throws ErrorException resolveFunctions(["no_such_function_xyz"])
    end

    @testset "cycleWalkWriterNames: sorted, resolvable, excludes partisan writers" begin
        writerNames = cycleWalkWriterNames()
        @test !isempty(writerNames)
        @test issorted(writerNames)
        @test "get_log_spanning_trees" in writerNames        # a known plain writer
        @test isempty(intersect(writerNames, PARTISAN_WRITERS))

        # Every listed name must actually resolve via resolveFunctions (the same
        # path `atlas add <name> ...` takes).
        for n in writerNames
            fns = resolveFunctions([n])
            @test fns[1][1] == n
        end
    end

    @testset "cycleWalkWriterNames: every listed writer actually runs end-to-end" begin
        # Codifies the audit that motivated writerWorks: cycleWalkWriterNames should
        # list only writers usable in practice, not just ones with a matching method
        # signature (e.g. CycleWalk 0.2.1's get_degree_distributions / get_average_degrees
        # / get_center_moments / get_center_leaves_moments all HAVE a `f(::LinkCutPartition)`
        # method but unconditionally throw `UndefVarError: LiftedTreeWalk not defined`
        # when called -- an upstream CycleWalk bug, not reachable via hasmethod).
        writerNames = cycleWalkWriterNames()

        graph = joinpath(@__DIR__, "..", "..", "Data", "CT_pct20.json")
        oracle = joinpath(@__DIR__, "..", "..", "examples", "cycleWalk_ct_slice.jsonl.gz")
        Atlas2 = joinpath(mktempdir(), "listed_writers_smoke.jsonl.gz")
        addMapData(oracle, Atlas2, writerNames;
                   graph = graph, pop_col = "POP20", node_col = "NAME",
                   area_col = "area", border_col = "border_length",
                   edge_perimeter_col = "length",
                   node_data = ["COUNTY", "NAME", "POP20", "area", "border_length"],
                   overwrite = true)   # must not throw

        a = openAtlas(smartOpen(Atlas2, "r"))
        m = nextMap(a)
        close(a)
        for n in writerNames
            @test haskey(m.data, n)
        end
    end

    @testset "writerWorks: catches a writer that throws" begin
        p = smokeTestPartition()
        @test writerWorks(get_log_spanning_trees, p)
        @test !writerWorks((_p) -> error("boom"), p)
    end

    @testset "listWriterDetails: plain + partisan writers" begin
        d = listWriterDetails()
        @test first.(d.plain) == cycleWalkWriterNames()
        @test all(fast == hasFastMethod(getfield(CycleWalk, Symbol(n))) for (n, fast) in d.plain)
        @test d.partisan == ["get_partisan_margins", "get_partisan_seats"]
    end

    @testset "resolveGraphSpec: flags only" begin
        s = rgs(graph = "g.json", pop_col = "POP20", node_col = "NAME",
                area_col = "area", border_col = "border_length",
                edge_perimeter_col = "length")
        @test s isa GraphSpec
        @test s.path == "g.json"
        @test s.pop_col == "POP20"
        @test s.levels == ["NAME"]
        @test s.area_col == "area"
        @test s.node_border_col == "border_length"
        @test s.edge_perimeter_col == "length"
        # node_data must include the level, pop, area and border columns.
        @test issubset(Set(["NAME", "POP20", "area", "border_length"]), s.node_data)
    end

    @testset "resolveGraphSpec: missing required pieces error" begin
        err = try rgs(pop_col = "POP20", node_col = "NAME"); nothing catch e; e end     # no graph
        @test err isa ErrorException && startswith(err.msg, "test: no graph given") && occursin("graph =", err.msg)
        @test_throws ErrorException rgs(graph = "", pop_col = "POP20", node_col = "NAME")   # "" is not given
        @test_throws ErrorException rgs(graph = "g.json", node_col = "NAME")    # no pop col
        @test_throws ErrorException rgs(graph = "g.json", pop_col = "POP20")    # no node col
    end

    @testset "resolveGraphSpec: TOML + flag override" begin
        dir = mktempdir()
        toml = joinpath(dir, "param.toml")
        open(toml, "w") do io
            println(io, "[plans]")
            println(io, "pop_col = \"POP20\"")
            println(io, "geo_units = [\"NAME\"]")
            println(io, "area_col = \"area\"")
            println(io, "node_border_col = \"border_length\"")
            println(io, "edge_perimeter_col = \"length\"")
            println(io, "node_data = [\"COUNTY\", \"NAME\"]")
            println(io, "map_directory = [\"maps\", \"nc\"]")
            println(io, "map_file = \"g.json\"")
        end

        s = rgs(config = toml)
        @test s.path == joinpath("maps", "nc", "g.json")
        @test s.pop_col == "POP20"
        @test s.levels == ["NAME"]
        @test s.edge_perimeter_col == "length"
        @test "COUNTY" in s.node_data

        # A flag overrides the corresponding TOML value.
        s2 = rgs(config = toml, graph = "other.json", pop_col = "TOTPOP")
        @test s2.path == "other.json"
        @test s2.pop_col == "TOTPOP"
        @test s2.levels == ["NAME"]              # untouched TOML value kept
    end

    @testset "writeHeaderWithProvenance" begin
        dir = mktempdir()
        Atlas1 = joinpath(dir, "Atlas1.jsonl")
        Atlas2 = joinpath(dir, "Atlas2.jsonl")

        io = smartOpen(Atlas1, "w")
        newAtlas(io, AtlasHeader("desc", Dict{String,Any}, Dict{String,Any}),
                 Dict{String,Any}("districts" => 3))
        close(io)

        spec = rgs(graph = "g.json", pop_col = "POP20", node_col = "NAME").path
        writeHeaderWithProvenance(Atlas1, Atlas2, ["get_log_spanning_trees"], spec)

        atlas = openAtlas(smartOpen(Atlas2, "r"))
        @test atlas.atlasParam["districts"] == 3        # original params preserved
        prov = atlas.atlasParam["added map data"]
        @test length(prov) == 1
        @test prov[1]["fields"] == ["get_log_spanning_trees"]
        @test prov[1]["graph"] == "g.json"
        @test haskey(prov[1], "date")
        close(atlas)

        # A second pass appends to (does not clobber) the provenance log.
        A3 = joinpath(dir, "A3.jsonl")
        writeHeaderWithProvenance(Atlas2, A3, ["get_isoperimetric_scores"], spec)
        atlas = openAtlas(smartOpen(A3, "r"))
        @test length(atlas.atlasParam["added map data"]) == 2
        close(atlas)

        # The existing params are written back byte for byte: same key order, exact numbers.
        # (Before 0.2.0, the JSON3 round trip turned 0.0 into 0, -0.0 into 0, corrupted
        # integers beyond 2^53, and scrambled the key order.)
        params = "{\"zeta\":1,\"gamma\":0.0,\"seed\":-7375463094308724563,\"negzero\":-0.0," *
                 "\"nested\":{\"b\":1,\"a\":[1.0,2.5]},\"alpha\":\"x\"}"
        A4 = joinpath(dir, "A4.jsonl")
        write(A4, "\"banner\"\n" *
                  "{\"description\":\"d\",\"date\":\"t\",\"atlasParamType\":\"Dict{String, Any}\"," *
                  "\"mapParamType\":\"Dict{String, Any}\"}\n" * params * "\n")
        A5 = joinpath(dir, "A5.jsonl")
        writeHeaderWithProvenance(A4, A5, ["get_log_spanning_trees"], spec)
        line3 = readlines(A5)[3]
        @test startswith(line3, params[1:end-1] * ",\"added map data\":[{\"by\":\"atlas add\",")
        atlas = openAtlas(smartOpen(A5, "r"))
        @test atlas.atlasParam["gamma"] === 0.0
        @test atlas.atlasParam["seed"] === -7375463094308724563
        @test atlas.atlasParam["negzero"] === -0.0
        close(atlas)
    end

    # Oracle tests: these fixtures are real CycleWalk output whose maps already
    # carry get_log_spanning_trees / get_log_spanning_forests /
    # get_isoperimetric_scores. Recompute them from each districting on the same
    # CT dual graph and confirm we reproduce CycleWalk's own values. This exercises
    # the full reconstruction path -- MultiLevelPartition(graph, districting) ->
    # LinkCutPartition -> f(partition), including the district-label re-alignment
    # (LinkCutPartition renumbers districts, so per-district vectors must be mapped
    # back onto the districting's labels) -- against ground truth. The multi-map
    # slice is what makes the re-alignment observable: several of its maps
    # reconstruct with a non-identity district permutation.
    graph = joinpath(@__DIR__, "..", "..", "Data", "CT_pct20.json")
    fields = ["get_log_spanning_trees", "get_log_spanning_forests",
              "get_isoperimetric_scores"]
    readall(p) = (a = openAtlas(smartOpen(p, "r")); ms = Map[];
                  while !eof(a); push!(ms, nextMap(a)); end; close(a); ms)
    asvec(x) = x isa AbstractVector ? Float64.(x) : [Float64(x)]

    # (fixture, expected minimum map count)
    fixtures = [("cycleWalk_ct_metadata.jsonl.gz", 1),
                ("cycleWalk_ct_slice.jsonl.gz", 40)]

    for (fixture, minmaps) in fixtures
        @testset "oracle: $fixture" begin
            oracle = joinpath(@__DIR__, "..", "..", "examples", fixture)
            Atlas2 = joinpath(mktempdir(), "ct_recomputed.jsonl.gz")
            n = addMapData(oracle, Atlas2, fields;
                           graph = graph, pop_col = "POP20", node_col = "NAME",
                           area_col = "area", border_col = "border_length",
                           edge_perimeter_col = "length",
                           node_data = ["COUNTY", "NAME", "POP20", "area", "border_length"],
                           overwrite = true)
            @test n == length(readall(oracle))

            orig, recomp = readall(oracle), readall(Atlas2)
            @test length(orig) == length(recomp)
            @test length(orig) >= minmaps

            maxrel = 0.0
            for (mo, mr) in zip(orig, recomp), f in fields
                o, r = asvec(mo.data[f]), asvec(mr.data[f])
                @test length(o) == length(r)
                for (a, b) in zip(o, r)
                    maxrel = max(maxrel, abs(a - b) / max(abs(a), 1e-12))
                end
            end
            # CycleWalk's stored values are reproduced to (essentially) machine
            # precision; 1e-6 leaves headroom for BLAS/platform variation.
            @test maxrel < 1e-6
        end
    end

    # The treeless fast path (builds no partition object -- resolves node_to_dist
    # straight from the districting via coverLabel) must reproduce the general
    # LinkCutPartition path (to machine precision) for the writers it covers. This
    # pins the fast == slow invariant directly, independent of the oracle fixtures'
    # stored values.
    #
    # Dispatch is by method existence (hasFastMethod), so these assertions are robust
    # to the CycleWalk version: against a CycleWalk that provides the partition-free
    # writer methods the fast path is exercised in full; against one that does not,
    # everything correctly routes to the LinkCutPartition path (validated by the
    # oracle test above) and the fast==slow value checks are skipped.
    @testset "treeless fast path == LinkCutPartition path" begin
        treelessNames = ["get_log_spanning_trees", "get_log_spanning_forests",
                         "get_isoperimetric_scores"]

        # allTreeless follows hasFastMethod for every candidate, whichever way it goes.
        for f in treelessNames
            fn = resolveFunctions([f])[1][2]
            @test allTreeless(resolveFunctions([f])) == hasFastMethod(fn)
        end
        # A writer with ONLY the LinkCutPartition method (get_isoperimetric_score,
        # singular -- the summed scalar) is never fast and taints a mixed request, so
        # it always routes to the LCP fallback.
        @test !hasFastMethod(resolveFunctions(["get_isoperimetric_score"])[1][2])
        @test !allTreeless(resolveFunctions(["get_isoperimetric_score"]))
        @test !allTreeless(resolveFunctions(["get_log_spanning_trees",
                                             "get_isoperimetric_score"]))

        treelessFns = resolveFunctions(treelessNames)
        if !allTreeless(treelessFns)
            @info "CycleWalk lacks the partition-free writer methods; skipping " *
                  "fast==LCP value checks (all writers route to the LinkCutPartition path)."
        else
            g = loadGraph(graph = graph, pop_col = "POP20", node_col = "NAME",
                          area_col = "area", border_col = "border_length",
                          edge_perimeter_col = "length",
                          node_data = ["COUNTY", "NAME", "POP20", "area", "border_length"])
            maps = readall(joinpath(@__DIR__, "..", "..", "examples", "cycleWalk_ct_slice.jsonl.gz"))
            @test length(maps) >= 40
            for m in maps
                fast = evalWritersTreeless(g, m, treelessFns)
                slow = evalWritersLCP(g, m, treelessFns)
                # Per-district tree counts are the same induced-subgraph logdets in
                # both paths, so they agree bit-for-bit.
                @test asvec(fast["get_log_spanning_trees"]) == asvec(slow["get_log_spanning_trees"])
                # The forest count is their SUM; the two paths sum in different
                # district orders, so it agrees only to machine precision.
                @test fast["get_log_spanning_forests"] ≈ slow["get_log_spanning_forests"]
                # Isoperimetric scores match to machine precision: both accumulate the
                # same node areas/border lengths and cross-edge perimeters, but the
                # fast path walks the graph's edges while the LCP path walks the
                # partition's cross_district_edges dict, so the perimeter sums land in
                # a different order (~1e-14 -- the same summation-order noise).
                @test asvec(fast["get_isoperimetric_scores"]) ≈ asvec(slow["get_isoperimetric_scores"])
                # evalWriters dispatches to the fast path and matches it exactly.
                @test evalWriters(g, m, treelessFns)["get_log_spanning_trees"] ==
                      fast["get_log_spanning_trees"]
            end
        end
    end

    @testset "voteColumns: distinct, in order" begin
        @test voteColumns([("A", "B"), ("C", "A")]) == ["A", "B", "C"]
    end

    @testset "resolveFunctions: partisan writers expand per vote pair" begin
        # nullary writers unaffected by vote pairs
        f1 = resolveFunctions(["get_log_spanning_trees"])
        @test [d for (d, _) in f1] == ["get_log_spanning_trees"]

        # partisan name expands to one field per vote pair
        fp = resolveFunctions(["get_partisan_margins"], [("G20_D", "G20_R"), ("G16_D", "G16_R")])
        @test [d for (d, _) in fp] ==
              ["get_partisan_margins_G20_D_G20_R", "get_partisan_margins_G16_D_G16_R"]
        @test all(f isa Function for (_, f) in fp)
        # partisan writers take the treeless fast path iff CycleWalk provides the
        # partition-free method on the built functor (dispatch follows hasFastMethod).
        @test allTreeless(fp) == all(hasFastMethod(f) for (_, f) in fp)

        # mixing a partisan and a plain writer
        fm = resolveFunctions(["get_partisan_seats", "get_isoperimetric_scores"], [("D", "R")])
        @test [d for (d, _) in fm] == ["get_partisan_seats_D_R", "get_isoperimetric_scores"]

        # a partisan writer without vote columns is an error
        @test_throws ErrorException resolveFunctions(["get_partisan_margins"])
    end

    # End-to-end: add per-district vote shares and check them against an independent
    # aggregation of the graph's vote columns over each map's own districting.
    @testset "addMapData: partisan margins == independent tally" begin
        graphPath = joinpath(@__DIR__, "..", "..", "Data", "CT_pct20.json")
        src = joinpath(@__DIR__, "..", "..", "examples", "cycleWalk_ct_slice.jsonl.gz")
        v1, v2 = "G20PREDEM", "G20PREREP"
        field = "get_partisan_margins_$(v1)_$(v2)"

        Atlas2 = joinpath(mktempdir(), "votes.jsonl.gz")
        addMapData(src, Atlas2, ["get_partisan_margins"]; graph = graphPath, pop_col = "POP20",
                   node_col = "NAME", vote_cols = [(v1, v2)], overwrite = true)

        # graph vote data keyed by NAME
        graph = JSON.parse(read(graphPath, String))
        vote = Dict(string(n["NAME"]) => (Float64(n[v1]), Float64(n[v2])) for n in graph["nodes"])

        a = openAtlas(smartOpen(Atlas2, "r"))
        nmaps = 0
        maxerr = 0.0
        while !eof(a)
            m = nextMap(a); nmaps += 1
            got = Float64.(m.data[field])
            d = Int(a.atlasParam["districts"])
            dv = zeros(d); rv = zeros(d)
            for (key, lab) in m.districting                 # key is a 1-tuple of NAME
                dd, rr = vote[string(key[1])]
                dv[lab] += dd; rv[lab] += rr
            end
            want = [100.0 * dv[i] / (dv[i] + rv[i]) for i in 1:d]
            @test length(got) == d
            maxerr = max(maxerr, maximum(abs.(got .- want)))
        end
        close(a)
        @test nmaps >= 40
        @test maxerr < 1e-9        # exact per-district vote-share aggregation
    end

end
