# Tests for the `atlas add` subcommand: function-name parsing, function
# resolution, graph-spec resolution (TOML + flag overrides), the header
# provenance stamp, and an end-to-end oracle test that recomputes a real
# CycleWalk atlas's map data and checks it reproduces CycleWalk's own values.

using Test
using AtlasIO
using JSON3
using CycleWalk: get_log_spanning_trees, get_isoperimetric_scores
using AtlasUtilities: parseFunctionNames, resolveFunctions, resolveGraphSpec,
                     writeHeaderWithProvenance, GraphSpec, run_add,
                     parseVotePairs, voteColumns

# resolveGraphSpec takes only keyword arguments; default them all to "".
rgs(; kw...) = resolveGraphSpec(; config = "", graph = "", pop_col = "",
                                node_col = "", area_col = "", border_col = "",
                                edge_perimeter_col = "", node_data = "", kw...)

@testset "add" begin

    @testset "parseFunctionNames" begin
        @test parseFunctionNames("get_log_spanning_trees") == ["get_log_spanning_trees"]
        @test parseFunctionNames("a,b,c") == ["a", "b", "c"]
        @test parseFunctionNames("[a, b]") == ["a", "b"]           # bracketed list
        @test parseFunctionNames("[\"a\", \"b\"]") == ["a", "b"]   # quoted, bracketed
        @test parseFunctionNames("  a , b ,") == ["a", "b"]        # trailing comma / spaces
        @test_throws ErrorException parseFunctionNames("")
        @test_throws ErrorException parseFunctionNames("[]")
    end

    @testset "resolveFunctions" begin
        fns = resolveFunctions(["get_log_spanning_trees", "get_isoperimetric_scores"])
        @test [d for (d, _) in fns] == ["get_log_spanning_trees", "get_isoperimetric_scores"]
        @test fns[1][2] === get_log_spanning_trees
        @test fns[2][2] === get_isoperimetric_scores
        @test_throws ErrorException resolveFunctions(["no_such_function_xyz"])
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
        @test_throws ErrorException rgs(pop_col = "POP20", node_col = "NAME")   # no graph
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
        A1 = joinpath(dir, "A1.jsonl")
        A2 = joinpath(dir, "A2.jsonl")

        io = smartOpen(A1, "w")
        newAtlas(io, AtlasHeader("desc", Dict{String,Any}, Dict{String,Any}),
                 Dict{String,Any}("districts" => 3))
        close(io)

        spec = rgs(graph = "g.json", pop_col = "POP20", node_col = "NAME")
        writeHeaderWithProvenance(A1, A2, ["get_log_spanning_trees"], spec)

        atlas = openAtlas(smartOpen(A2, "r"))
        @test atlas.atlasParam["districts"] == 3        # original params preserved
        prov = atlas.atlasParam["added map data"]
        @test length(prov) == 1
        @test prov[1]["fields"] == ["get_log_spanning_trees"]
        @test prov[1]["graph"] == "g.json"
        @test haskey(prov[1], "date")
        close(atlas)

        # A second pass appends to (does not clobber) the provenance log.
        A3 = joinpath(dir, "A3.jsonl")
        writeHeaderWithProvenance(A2, A3, ["get_isoperimetric_scores"], spec)
        atlas = openAtlas(smartOpen(A3, "r"))
        @test length(atlas.atlasParam["added map data"]) == 2
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
    graph = joinpath(@__DIR__, "..", "Data", "CT_pct20.json")
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
            oracle = joinpath(@__DIR__, "..", "examples", fixture)
            A2 = joinpath(mktempdir(), "ct_recomputed.jsonl.gz")
            run_add(join(fields, ","), oracle, A2;
                    graph = graph, pop_col = "POP20", node_col = "NAME",
                    area_col = "area", border_col = "border_length",
                    edge_perimeter_col = "length",
                    node_data = "COUNTY,NAME,POP20,area,border_length",
                    overwrite = true, quiet = true)

            orig, recomp = readall(oracle), readall(A2)
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

    @testset "parseVotePairs / voteColumns" begin
        @test parseVotePairs("") == Tuple{String,String}[]
        @test parseVotePairs("A,B") == [("A", "B")]
        @test parseVotePairs("A,B;C,D") == [("A", "B"), ("C", "D")]
        @test parseVotePairs(" A , B ; C , D ") == [("A", "B"), ("C", "D")]  # spaces trimmed
        @test parseVotePairs("A,B;") == [("A", "B")]                         # trailing ; ignored
        @test_throws ErrorException parseVotePairs("A")                      # not a pair
        @test_throws ErrorException parseVotePairs("A,B,C")                  # too many cols
        @test voteColumns([("A", "B"), ("C", "A")]) == ["A", "B", "C"]       # distinct, in order
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

        # mixing a partisan and a plain writer
        fm = resolveFunctions(["get_partisan_seats", "get_isoperimetric_scores"], [("D", "R")])
        @test [d for (d, _) in fm] == ["get_partisan_seats_D_R", "get_isoperimetric_scores"]

        # a partisan writer without vote columns is an error
        @test_throws ErrorException resolveFunctions(["get_partisan_margins"])
    end

    # End-to-end: add per-district vote shares and check them against an independent
    # aggregation of the graph's vote columns over each map's own districting.
    @testset "run_add: partisan margins == independent tally" begin
        graphPath = joinpath(@__DIR__, "..", "Data", "CT_pct20.json")
        src = joinpath(@__DIR__, "..", "examples", "cycleWalk_ct_slice.jsonl.gz")
        v1, v2 = "G20PREDEM", "G20PREREP"
        field = "get_partisan_margins_$(v1)_$(v2)"

        A2 = joinpath(mktempdir(), "votes.jsonl.gz")
        run_add("get_partisan_margins", src, A2; graph = graphPath, pop_col = "POP20",
                node_col = "NAME", vote_cols = "$v1,$v2", overwrite = true, quiet = true)

        # graph vote data keyed by NAME
        graph = JSON3.read(read(graphPath, String))
        vote = Dict(string(n["NAME"]) => (Float64(n[Symbol(v1)]), Float64(n[Symbol(v2)]))
                    for n in graph.nodes)

        a = openAtlas(smartOpen(A2, "r"))
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
