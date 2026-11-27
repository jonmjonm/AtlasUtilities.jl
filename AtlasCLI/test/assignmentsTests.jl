# `mapatlas extract-assignments`.

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

@testset "mapatlas extract-assignments" begin

    # A multiscale atlas: X split in m2 only, Y split in m1 only, Z never split.
    multiscale = [
        Districting(("X",) => 1, ("Y", "1") => 1, ("Y", "2") => 2, ("Z",) => 2),
        Districting(("X", "1") => 2, ("X", "2") => 1, ("Y",) => 2, ("Z",) => 1),
    ]
    levelsParams = Dict{String,Any}("districts" => 2, "levels in graph" => ["county", "prec"])
    graphJSON = """{"nodes":[""" * join(("{\"id\":$(i-1),\"county\":\"$c\",\"prec\":\"$p\"}"
        for (i, (c, p)) in enumerate([("X","1"), ("X","2"), ("Y","1"), ("Y","2"), ("Z","1"), ("Z","2")])), ",") *
        """],"adjacency":[[],[],[],[],[],[]]}"""

    @testset "mapatlas extract-assignments: skips existing output unless --force" begin
        dir = mktempdir()
        path = joinpath(dir, "a.jsonl")
        writeAssignmentsAtlas(path, [Districting(("a",) => 1, ("b",) => 2)])
        outpath = joinpath(dir, "a-assignments.csv")

        cli_extract_assignments(path; compress = false, quiet = true)
        mtime1 = mtime(outpath)

        out = capture_stdout() do
            cli_extract_assignments(path; compress = false, quiet = true)
        end
        @test occursin("already exists", out)
        @test mtime(outpath) == mtime1     # untouched

        cli_extract_assignments(path; compress = false, force = true, quiet = true)
        @test isfile(outpath)              # --force rewrites it
    end

    @testset "mapatlas extract-assignments: multiscale, no graph: the finest regions seen in the atlas" begin
        dir = mktempdir()
        path = joinpath(dir, "ms.jsonl")
        writeAssignmentsAtlas(path, multiscale; params = levelsParams)
        logs, out = Test.collect_test_logs() do
            capture_stdout() do
                cli_extract_assignments(path; compress = false)
            end
        end
        @test occursin("multiscale", out) && occursin("finest regions seen in the atlas", out)
        @test !any(l -> l.level >= Base.CoreLogging.Error, logs)    # the restart on a node-set change is silent
        # X:1 X:2 Y:1 Y:2 are finest; Z is never split, so it stays one column
        @test readlines_(joinpath(dir, "ms-assignments.csv")) ==
              ["name,X:1,X:2,Y:1,Y:2,Z", "m1,1,1,1,2,2", "m2,2,1,2,2,1"]
    end

    @testset "mapatlas extract-assignments: no maps prints a message, writes nothing" begin
        dir = mktempdir()
        path = joinpath(dir, "a.jsonl")
        writeAssignmentsAtlas(path, Districting[])

        out = capture_stdout() do
            cli_extract_assignments(path; compress = false, quiet = true)
        end
        @test occursin("no maps", out)
        @test isempty(filter(f -> occursin("assignments", f), readdir(dir)))
    end

end
