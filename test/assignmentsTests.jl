# Tests for the `atlas extract-assignments` subcommand (src/assignments.jl).

using Test
using AtlasIO
using AtlasUtilities: run_extract_assignments, loadHierarchy, expandLabels, nodeIdString

"""Write an atlas at `path` with one map per entry of `districtings`
(named m1, m2, ...)."""
function writeAssignmentsAtlas(path, districtings; params = Dict{String,Any}("districts" => 2))
    io = smartOpen(path, "w")
    newAtlas(io, AtlasHeader("desc", "2026-01-02T03:04:05", Dict{String,Any}, Dict{String,Any}), params)
    for (k, dist) in enumerate(districtings)
        addMap(io, Map("m$k", dist, 1, Dict{String,Any}()))
    end
    close(io)
end

readlines_(path) = filter(!isempty, split(read(path, String), '\n'))

@testset "extract-assignments" begin

    @testset "run_extract_assignments: writes wide CSV, columns sorted, one row per map" begin
        dir = mktempdir()
        path = joinpath(dir, "a.jsonl")
        writeAssignmentsAtlas(path, [
            Districting(("c",) => 1, ("a",) => 2, ("b",) => 1),
            Districting(("c",) => 2, ("a",) => 1, ("b",) => 2),
        ])

        out = capture_stdout() do
            run_extract_assignments(path; compress = false, quiet = true)
        end

        outpath = joinpath(dir, "a-assignments.csv")
        @test isfile(outpath)
        lines = readlines_(outpath)
        @test lines[1] == "name,a,b,c"
        @test lines[2] == "m1,2,1,1"
        @test lines[3] == "m2,1,2,2"
    end

    @testset "run_extract_assignments: gzip by default, plain with --no-compression" begin
        dir = mktempdir()
        path = joinpath(dir, "a.jsonl")
        writeAssignmentsAtlas(path, [Districting(("a",) => 1, ("b",) => 2)])

        run_extract_assignments(path; quiet = true)
        @test isfile(joinpath(dir, "a-assignments.csv.gz"))
        @test !isfile(joinpath(dir, "a-assignments.csv"))
    end

    @testset "run_extract_assignments: skips existing output unless --force" begin
        dir = mktempdir()
        path = joinpath(dir, "a.jsonl")
        writeAssignmentsAtlas(path, [Districting(("a",) => 1, ("b",) => 2)])
        outpath = joinpath(dir, "a-assignments.csv")

        run_extract_assignments(path; compress = false, quiet = true)
        mtime1 = mtime(outpath)

        out = capture_stdout() do
            run_extract_assignments(path; compress = false, quiet = true)
        end
        @test occursin("already exists", out)
        @test mtime(outpath) == mtime1     # untouched

        run_extract_assignments(path; compress = false, force = true, quiet = true)
        @test isfile(outpath)              # --force rewrites it
    end

    @testset "run_extract_assignments: errors (no partial file) when a map's node set differs" begin
        dir = mktempdir()
        path = joinpath(dir, "a.jsonl")
        writeAssignmentsAtlas(path, [
            Districting(("a",) => 1, ("b",) => 2),
            Districting(("a",) => 1, ("c",) => 2),   # different node set: "c" instead of "b"
        ])

        # The node sets differ, so the finest regions seen (a, b, c) become the columns; m1 covers no "c".
        err = try run_extract_assignments(path; compress = false, quiet = true); nothing catch e; e end
        @test err isa ErrorException && occursin("map \"m1\" assigns no district to \"c\"", err.msg)
        @test !isfile(joinpath(dir, "a-assignments.csv"))
        @test !isfile(joinpath(dir, "a-assignments.tmp.csv"))
        @test isempty(filter(f -> occursin("assignments", f), readdir(dir)))
    end

    @testset "run_extract_assignments: multi-component node ids, same in every map: joined with ':'" begin
        dir = mktempdir()
        path = joinpath(dir, "a.jsonl")
        writeAssignmentsAtlas(path, [Districting(("county", "tract") => 1, ("county", "t2") => 2),
                                     Districting(("county", "tract") => 2, ("county", "t2") => 1)])
        run_extract_assignments(path; compress = false, quiet = true)
        @test readlines_(joinpath(dir, "a-assignments.csv")) == ["name,county:t2,county:tract", "m1,2,1", "m2,1,2"]
    end

    # A multiscale atlas: X split in m2 only, Y split in m1 only, Z never split.
    multiscale = [
        Districting(("X",) => 1, ("Y", "1") => 1, ("Y", "2") => 2, ("Z",) => 2),
        Districting(("X", "1") => 2, ("X", "2") => 1, ("Y",) => 2, ("Z",) => 1),
    ]
    levelsParams = Dict{String,Any}("districts" => 2, "levels in graph" => ["county", "prec"])
    graphJSON = """{"nodes":[""" * join(("{\"id\":$(i-1),\"county\":\"$c\",\"prec\":\"$p\"}"
        for (i, (c, p)) in enumerate([("X","1"), ("X","2"), ("Y","1"), ("Y","2"), ("Z","1"), ("Z","2")])), ",") *
        """],"adjacency":[[],[],[],[],[],[]]}"""

    @testset "multiscale, no graph: the finest regions seen in the atlas" begin
        dir = mktempdir()
        path = joinpath(dir, "ms.jsonl")
        writeAssignmentsAtlas(path, multiscale; params = levelsParams)
        out = capture_stdout() do
            run_extract_assignments(path; compress = false)
        end
        @test occursin("multiscale", out) && occursin("finest regions seen in the atlas", out)
        # X:1 X:2 Y:1 Y:2 are finest; Z is never split, so it stays one column
        @test readlines_(joinpath(dir, "ms-assignments.csv")) ==
              ["name,X:1,X:2,Y:1,Y:2,Z", "m1,1,1,1,2,2", "m2,2,1,2,2,1"]
    end

    @testset "multiscale, --graph: the graph's finest units, also in a county never split" begin
        dir = mktempdir()
        path, g = joinpath(dir, "ms.jsonl.gz"), joinpath(dir, "g.json")
        writeAssignmentsAtlas(path, multiscale; params = levelsParams)
        write(g, graphJSON)
        run_extract_assignments(path; graph = g, compress = false, quiet = true)
        @test readlines_(joinpath(dir, "ms-assignments.csv")) ==
              ["name,X:1,X:2,Y:1,Y:2,Z:1,Z:2", "m1,1,1,1,2,2,2", "m2,2,1,2,2,1,1"]
    end

    @testset "multiscale, --graph: errors (no partial file)" begin
        dir = mktempdir()
        g = joinpath(dir, "g.json")
        write(g, graphJSON)
        # the atlas does not say which graph attributes its keys are
        p1 = joinpath(dir, "nolevels.jsonl")
        writeAssignmentsAtlas(p1, multiscale)
        err = try run_extract_assignments(p1; graph = g, compress = false, quiet = true); nothing catch e; e end
        @test err isa ErrorException && occursin("levels in graph", err.msg)
        # a map uses a county the graph does not have
        p2 = joinpath(dir, "unknown.jsonl")
        writeAssignmentsAtlas(p2, [multiscale[1], Districting(("X",) => 1, ("Y",) => 2, ("W",) => 1)];
                              params = levelsParams)
        err = try run_extract_assignments(p2; graph = g, compress = false, quiet = true); nothing catch e; e end
        @test err isa ErrorException && occursin("map \"m2\" has node \"W\"", err.msg)
        @test isempty(filter(f -> occursin("assignments", f), readdir(dir)))
    end

    @testset "multiscale demo + its graph: agrees with relabel's expansion to finest units" begin
        ex = joinpath(@__DIR__, "..", "examples")
        dir = mktempdir()
        path = joinpath(dir, "demo_multiscale.jsonl.gz")
        cp(joinpath(ex, "demo_multiscale.jsonl.gz"), path)
        g = joinpath(ex, "demo_multiscale_graph.json")
        run_extract_assignments(path; graph = g, compress = false, quiet = true)
        lines = readlines_(joinpath(dir, "demo_multiscale-assignments.csv"))
        cols = split(lines[1], ',')[2:end]

        io = smartOpen(path, "r"); a = openAtlas(io)
        h = loadHierarchy(g, a.atlasParam["levels in graph"])
        order = [findfirst(==(c), nodeIdString.(h.finest)) for c in cols]
        k = 1
        while !eof(a)
            m = nextMap(a)
            k += 1
            @test split(lines[k], ',') == vcat(m.name, string.(expandLabels(h, m.districting)[order]))
        end
        close(io)
        @test k == length(lines) && length(cols) == length(h.finest)
    end

    @testset "run_extract_assignments: no maps prints a message, writes nothing" begin
        dir = mktempdir()
        path = joinpath(dir, "a.jsonl")
        writeAssignmentsAtlas(path, Districting[])

        out = capture_stdout() do
            run_extract_assignments(path; compress = false, quiet = true)
        end
        @test occursin("no maps", out)
        @test isempty(filter(f -> occursin("assignments", f), readdir(dir)))
    end

end
