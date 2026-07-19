# Tests for the `atlas extract-assignments` subcommand (src/assignments.jl).

using Test
using AtlasIO
using AtlasUtilities: run_extract_assignments

"""Write an atlas at `path` with one map per entry of `districtings`
(named m1, m2, ...)."""
function writeAssignmentsAtlas(path, districtings)
    io = smartOpen(path, "w")
    newAtlas(io, AtlasHeader("desc", "2026-01-02T03:04:05", Dict{String,Any}, Dict{String,Any}),
             Dict{String,Any}("districts" => 2))
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

        @test_throws Exception run_extract_assignments(path; compress = false, quiet = true)
        @test !isfile(joinpath(dir, "a-assignments.csv"))
        @test !isfile(joinpath(dir, "a-assignments.tmp.csv"))
        @test isempty(filter(f -> occursin("assignments", f), readdir(dir)))
    end

    @testset "run_extract_assignments: errors on multiscale node ids (first map already multi-component)" begin
        dir = mktempdir()
        path = joinpath(dir, "a.jsonl")
        writeAssignmentsAtlas(path, [Districting(("county", "tract") => 1)])

        @test_throws ErrorException run_extract_assignments(path; compress = false, quiet = true)
        @test isempty(filter(f -> occursin("assignments", f), readdir(dir)))
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
