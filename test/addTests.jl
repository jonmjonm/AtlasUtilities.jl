# Tests for the `atlas add` subcommand's graph-free logic: function-name parsing,
# function resolution, graph-spec resolution (TOML + flag overrides), and the
# header provenance stamp. The full reconstruction path (which needs a real dual
# graph and the CycleWalk partition stack) is exercised separately.

using Test
using AtlasIO
using CycleWalk: get_log_spanning_trees, get_isoperimetric_scores
using AtlasUtilities: parseFunctionNames, resolveFunctions, resolveGraphSpec,
                     writeHeaderWithProvenance, GraphSpec

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

end
