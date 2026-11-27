# Tests for district assignments (src/assignments.jl).

using Test
using AtlasIO
using AtlasUtilities: extractAssignments, assignmentMatrix, loadHierarchy, expandLabels, nodeIdString

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

    @testset "extractAssignments: writes wide CSV, columns sorted, one row per map" begin
        dir = mktempdir()
        path = joinpath(dir, "a.jsonl")
        writeAssignmentsAtlas(path, [
            Districting(("c",) => 1, ("a",) => 2, ("b",) => 1),
            Districting(("c",) => 2, ("a",) => 1, ("b",) => 2),
        ])

        local r
        out = capture_stdout() do
            r = extractAssignments(path; compress = false)
        end
        @test isempty(out)                                          # the library prints nothing

        outpath = joinpath(dir, "a-assignments.csv")
        @test r.path == outpath && r.nmaps == 2 && r.units == [("a",), ("b",), ("c",)] && r.scale === nothing
        @test isfile(outpath)
        lines = readlines_(outpath)
        @test lines[1] == "name,a,b,c"
        @test lines[2] == "m1,2,1,1"
        @test lines[3] == "m2,1,2,2"
    end

    @testset "extractAssignments: gzip by default, plain with --no-compression" begin
        dir = mktempdir()
        path = joinpath(dir, "a.jsonl")
        writeAssignmentsAtlas(path, [Districting(("a",) => 1, ("b",) => 2)])

        extractAssignments(path)
        @test isfile(joinpath(dir, "a-assignments.csv.gz"))
        @test !isfile(joinpath(dir, "a-assignments.csv"))
    end

    @testset "extractAssignments: skips existing output unless force" begin
        dir = mktempdir()
        path = joinpath(dir, "a.jsonl")
        writeAssignmentsAtlas(path, [Districting(("a",) => 1, ("b",) => 2)])
        outpath = joinpath(dir, "a-assignments.csv")

        extractAssignments(path; compress = false)
        mtime1 = mtime(outpath)
        @test extractAssignments(path; compress = false) === nothing       # skipped, nothing returned
        @test mtime(outpath) == mtime1     # untouched
        @test extractAssignments(path; compress = false, force = true) !== nothing
        @test isfile(outpath)              # force rewrites it
    end

    @testset "extractAssignments: errors (no partial file) when a map's node set differs" begin
        dir = mktempdir()
        path = joinpath(dir, "a.jsonl")
        writeAssignmentsAtlas(path, [
            Districting(("a",) => 1, ("b",) => 2),
            Districting(("a",) => 1, ("c",) => 2),   # different node set: "c" instead of "b"
        ])

        # The node sets differ, so the finest regions seen (a, b, c) become the columns; m1 covers no "c".
        logs, err = Test.collect_test_logs() do
            try extractAssignments(path; compress = false); nothing catch e; e end
        end
        @test err isa ErrorException && occursin("map \"m1\" assigns no district to \"c\"", err.msg)
        @test !any(l -> l.level >= Base.CoreLogging.Error, logs)    # an error for the user: no AtlasIO log
        @test !isfile(joinpath(dir, "a-assignments.csv"))
        @test !isfile(joinpath(dir, "a-assignments.tmp.csv"))
        @test isempty(filter(f -> occursin("assignments", f), readdir(dir)))
    end

    @testset "extractAssignments: multi-component node ids, same in every map: joined with ':'" begin
        dir = mktempdir()
        path = joinpath(dir, "a.jsonl")
        writeAssignmentsAtlas(path, [Districting(("county", "tract") => 1, ("county", "t2") => 2),
                                     Districting(("county", "tract") => 2, ("county", "t2") => 1)])
        extractAssignments(path; compress = false)
        @test readlines_(joinpath(dir, "a-assignments.csv")) == ["name,county:t2,county:tract", "m1,2,1", "m2,1,2"]
    end

    @testset "extractAssignments: a given outpath is compressed by its own extension" begin
        dir = mktempdir()
        path = joinpath(dir, "a.jsonl")
        writeAssignmentsAtlas(path, [Districting(("a",) => 1, ("b",) => 2), Districting(("a",) => 2, ("b",) => 1)])
        expected = ["name,a,b", "m1,1,2", "m2,2,1"]
        magic(p) = read(p, 3)
        for (name, head) in [("out.csv.bz2", b"BZh"), ("out.tsv.gz", UInt8[0x1f, 0x8b]), ("out.gz", UInt8[0x1f, 0x8b]),
                             ("out.csv", b"nam"), ("out.txt", b"nam")]
            outpath = joinpath(dir, name)
            r = extractAssignments(path, outpath)
            @test r.path == outpath && isfile(outpath)
            @test magic(outpath)[1:length(head)] == head                 # compressed (or not) as its name says
            io = smartOpen(outpath, "r")
            @test filter(!isempty, split(read(io, String), '\n')) == expected
            close(io)
        end
        @test isempty(filter(f -> occursin("tmp", f), readdir(dir)))        # no temporary file left
    end

    @testset "assignments: a graph without \"levels in graph\" names the function" begin
        dir = mktempdir()
        path = joinpath(dir, "a.jsonl")
        writeAssignmentsAtlas(path, [Districting(("a",) => 1, ("b",) => 2)])
        g = joinpath(dir, "g.json")
        write(g, """{"nodes":[{"id":0,"prec":"a"},{"id":1,"prec":"b"}],"adjacency":[[],[]]}""")
        e1 = try extractAssignments(path; graph = g, compress = false); nothing catch e; e end
        @test e1 isa ErrorException && startswith(e1.msg, "extractAssignments: a graph was given")
        e2 = try assignmentMatrix(path; graph = g); nothing catch e; e end
        @test e2 isa ErrorException && startswith(e2.msg, "assignmentMatrix: a graph was given")
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
        local r
        logs, out = Test.collect_test_logs() do
            capture_stdout() do
                r = extractAssignments(path; compress = false)
            end
        end
        @test isempty(out) && occursin("finest regions seen in the atlas", r.scale)
        @test occursin("pass graph = <graph.json>", r.scale) && !occursin("--graph", r.scale)   # library terms
        @test !any(l -> l.level >= Base.CoreLogging.Error, logs)    # the restart on a node-set change is silent
        # X:1 X:2 Y:1 Y:2 are finest; Z is never split, so it stays one column
        @test readlines_(joinpath(dir, "ms-assignments.csv")) ==
              ["name,X:1,X:2,Y:1,Y:2,Z", "m1,1,1,1,2,2", "m2,2,1,2,2,1"]
    end

    @testset "multiscale, --graph: the graph's finest units, also in a county never split" begin
        dir = mktempdir()
        path, g = joinpath(dir, "ms.jsonl.gz"), joinpath(dir, "g.json")
        writeAssignmentsAtlas(path, multiscale; params = levelsParams)
        write(g, graphJSON)
        extractAssignments(path; graph = g, compress = false)
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
        err = try extractAssignments(p1; graph = g, compress = false); nothing catch e; e end
        @test err isa ErrorException && occursin("levels in graph", err.msg)
        # a map uses a county the graph does not have
        p2 = joinpath(dir, "unknown.jsonl")
        writeAssignmentsAtlas(p2, [multiscale[1], Districting(("X",) => 1, ("Y",) => 2, ("W",) => 1)];
                              params = levelsParams)
        err = try extractAssignments(p2; graph = g, compress = false); nothing catch e; e end
        @test err isa ErrorException && occursin("map \"m2\" has node \"W\"", err.msg)
        @test isempty(filter(f -> occursin("assignments", f), readdir(dir)))
    end

    @testset "multiscale demo + its graph: agrees with relabel's expansion to finest units" begin
        ex = joinpath(@__DIR__, "..", "examples")
        dir = mktempdir()
        path = joinpath(dir, "demo_multiscale.jsonl.gz")
        cp(joinpath(ex, "demo_multiscale.jsonl.gz"), path)
        g = joinpath(ex, "demo_multiscale_graph.json")
        extractAssignments(path; graph = g, compress = false)
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

    # assignmentMatrix is the CSV as data: the same names, columns and districts, plus the weights.
    "The cells of a CSV line, unquoting `\"...\"` cells (CT's unit names hold commas)."
    function csvsplit(line)
        cells, buf, quoted, i = String[], IOBuffer(), false, firstindex(line)
        while i <= lastindex(line)
            c = line[i]
            if quoted && c == '"' && i < lastindex(line) && line[nextind(line, i)] == '"'
                print(buf, '"'); i = nextind(line, i)
            elseif c == '"'
                quoted = !quoted
            elseif c == ',' && !quoted
                push!(cells, String(take!(buf)))
            else
                print(buf, c)
            end
            i = nextind(line, i)
        end
        push!(cells, String(take!(buf)))
        return cells
    end
    "`assignmentMatrix(path; kw...)` and the CSV `extract-assignments` writes with the same options agree."
    function sameAsCSV(path; kw...)
        A = assignmentMatrix(path; kw...)
        extractAssignments(path; compress = false, force = true, kw...)
        lines = readlines_(replace(path, r"\.jsonl(\.gz)?$" => "-assignments.csv"))
        rows = csvsplit.(lines[2:end])
        return csvsplit(lines[1])[2:end] == A.unitNames && A.unitNames == nodeIdString.(A.units) &&
               first.(rows) == A.names &&
               size(A.districts) == (length(rows), length(A.units)) &&
               all(parse.(Int, rows[i][2:end]) == A.districts[i, :] for i in eachindex(rows))
    end

    @testset "assignmentMatrix: the CSV's table, as data" begin
        dir = mktempdir()
        single = joinpath(dir, "single.jsonl")
        writeAssignmentsAtlas(single, [Districting(("c",) => 1, ("a",) => 2, ("b",) => 1),
                                       Districting(("c",) => 2, ("a",) => 1, ("b",) => 2)])
        A = assignmentMatrix(single)
        @test A.names == ["m1", "m2"] && A.weights == [1.0, 1.0]
        @test A.units == [("a",), ("b",), ("c",)] && A.unitNames == ["a", "b", "c"]
        @test A.districts == [2 1 1; 1 2 2]
        @test sameAsCSV(single)

        ms = joinpath(dir, "ms.jsonl")
        writeAssignmentsAtlas(ms, multiscale; params = levelsParams)
        @test sameAsCSV(ms)                                          # the finest regions seen in the atlas
        @test assignmentMatrix(ms).unitNames == ["X:1", "X:2", "Y:1", "Y:2", "Z"]
        g = joinpath(dir, "g.json")
        write(g, graphJSON)
        @test sameAsCSV(ms; graph = g)                               # the graph's finest units
        @test assignmentMatrix(ms; graph = g).districts == [1 1 1 2 2 2; 2 1 2 2 1 1]
        @test isempty(capture_stdout(() -> assignmentMatrix(ms)))       # the library prints nothing

        ex = joinpath(@__DIR__, "..", "examples")
        demo = joinpath(dir, "demo_multiscale.jsonl.gz")
        cp(joinpath(ex, "demo_multiscale.jsonl.gz"), demo)
        @test sameAsCSV(demo; graph = joinpath(ex, "demo_multiscale_graph.json"))
        ct = joinpath(dir, "ct.jsonl.gz")
        cp(joinpath(ex, "cycleWalk_ct_slice.jsonl.gz"), ct)
        @test sameAsCSV(ct)
        @test any(occursin(',', u) for u in assignmentMatrix(ct).unitNames)   # quoted in the CSV
    end

    @testset "assignmentMatrix: weights, errors, no maps" begin
        dir = mktempdir()
        path = joinpath(dir, "w.jsonl")
        io = smartOpen(path, "w")
        newAtlas(io, AtlasHeader("desc", Dict{String,Any}, Dict{String,Any}; weightType = Float64),
                 Dict{String,Any}("districts" => 2))
        for (k, w) in enumerate([0.5, 2.25])
            addMap(io, Map("m$k", Districting(("a",) => k, ("b",) => 3 - k), w, Dict{String,Any}()))
        end
        close(io)
        A = assignmentMatrix(path)
        @test A.weights == [0.5, 2.25] && A.districts == [1 2; 2 1]

        bad = joinpath(dir, "bad.jsonl")
        writeAssignmentsAtlas(bad, [Districting(("a",) => 1, ("b",) => 2), Districting(("a",) => 1)];
                              params = levelsParams)
        err = try assignmentMatrix(bad); nothing catch e; e end
        @test err isa ErrorException && occursin("map \"m2\" assigns no district to \"b\"", err.msg)

        none = joinpath(dir, "none.jsonl")
        writeAssignmentsAtlas(none, Districting[])
        E = assignmentMatrix(none)
        @test isempty(E.names) && isempty(E.units) && size(E.districts) == (0, 0)
    end

    @testset "extractAssignments: no maps writes nothing" begin
        dir = mktempdir()
        path = joinpath(dir, "a.jsonl")
        writeAssignmentsAtlas(path, Districting[])
        @test extractAssignments(path; compress = false).nmaps == 0
        @test isempty(filter(f -> occursin("assignments", f), readdir(dir)))
    end

end
