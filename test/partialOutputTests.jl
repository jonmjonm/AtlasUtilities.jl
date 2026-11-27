# A run that fails partway leaves no partial output under the real name (src/output.jl): an atlas, CSV or
# histogram file is written under a temporary name and moved into place only when complete.

using Test
using AtlasIO
using AtlasUtilities: relabelAtlas, extractMapData, mapDataHistograms, extractAssignments, writeHistograms,
                      tempPath, incompletePath, writeReplacing

const PO_CT = joinpath(@__DIR__, "..", "examples", "cycleWalk_ct_slice.jsonl.gz")

"The CT slice as plain lines, with the line of map `k` cut short to `keep` characters (so it does not parse)."
function damagedCT(dir; k = 20, keep = 100)
    io = smartOpen(PO_CT, "r")
    lines = readlines(io)
    close(io)
    first = findfirst(l -> startswith(l, "{\"name\""), lines)
    lines[first + k - 1] = lines[first + k - 1][1:keep]
    path = joinpath(dir, "cut.jsonl")
    write(path, join(lines, "\n") * "\n")
    return path
end

"The error `f()` raises (`nothing` if none)."
errorOf(f) = try f(); nothing catch e; e end

"The maps of the atlas at `path`."
mapsIn(path) = collect(eachMap(path; ntasks = 1))

"Files in `dir` (recursively) whose name says they are temporary."
tmpFiles(dir) = [f for (_, _, fs) in walkdir(dir) for f in fs if occursin(".tmp", f)]

@testset "no partial output on failure" begin

    @testset "tempPath keeps the extensions" begin
        @test tempPath("a/out.jsonl.gz") == "a/out.tmp.jsonl.gz"
        @test tempPath("out.csv.bz2") == "out.tmp.csv.bz2"
        @test tempPath("out.csv") == "out.tmp.csv"
        @test tempPath("out.gz") == "out.tmp.gz"
        @test tempPath("d.v2/out") == "d.v2/out.tmp"
    end

    @testset "incompletePath" begin
        @test incompletePath("a/out.jsonl.gz") == "a/out.incomplete.jsonl.gz"
        @test incompletePath("f-partial.csv") == "f-partial.incomplete.csv"
    end

    @testset "writeReplacing: moved into place on success, removed on error" begin
        dir = mktempdir()
        p = joinpath(dir, "x.txt")
        write(p, "old")
        @test writeReplacing(tmp -> (write(tmp, "new"); 7), p) == 7
        @test read(p, String) == "new" && isempty(tmpFiles(dir))
        @test_throws ErrorException writeReplacing(tmp -> (write(tmp, "half"); error("boom")), p)
        @test read(p, String) == "new" && isempty(tmpFiles(dir))      # untouched
    end

    @testset "relabelAtlas: a bad map leaves dst as it was" begin
        dir = mktempdir()
        cut = damagedCT(dir)
        dst = joinpath(dir, "out.jsonl.gz")
        @test_throws AtlasFormatError relabelAtlas(cut, dst; cores = 1)
        @test !isfile(dst) && isempty(tmpFiles(dir))
        write(dst, "earlier output")
        @test_throws AtlasFormatError relabelAtlas(cut, dst; cores = 1)
        @test read(dst, String) == "earlier output"
    end

    @testset "relabelAtlas: dst may be src" begin
        dir = mktempdir()
        a, b = joinpath(dir, "a.jsonl.gz"), joinpath(dir, "b.jsonl.gz")
        cp(PO_CT, a)
        n = relabelAtlas(a, b)
        @test relabelAtlas(a, a) == n
        read_(p) = (io = smartOpen(p, "r"); s = read(io, String); close(io); s)
        @test read_(a) == read_(b) && isempty(tmpFiles(dir))
    end

    @testset "extractMapData: a bad map leaves no CSV, so a rerun is not fooled" begin
        dir = mktempdir()
        cut = damagedCT(dir)
        out = joinpath(dir, "cut")
        @test_throws AtlasFormatError extractMapData(cut, out; cores = 1)
        @test isempty(filter(f -> endswith(f, ".csv.gz"), readdir(out))) && isempty(tmpFiles(dir))
        # the same atlas, intact: everything is written (nothing is skipped as already there)
        good = joinpath(dir, "good.jsonl.gz")
        cp(PO_CT, good)
        r = extractMapData(good, out)
        @test isempty(r.skipped) && r.nmaps == 41 && all(isfile, r.written)
    end

    @testset "a damaged map: the error says which file, line and map" begin
        dir = mktempdir()
        cut = damagedCT(dir)                  # map 20, on line 23 (after the 3 header lines)
        at = "$cut, line 23 (map 20): not a valid Atlas map line"
        runs = [cores -> relabelAtlas(cut, joinpath(dir, "r.jsonl"); cores),
                cores -> extractMapData(cut, joinpath(dir, "x"); cores),
                cores -> mapDataHistograms(cut; cores),
                cores -> mapDataHistograms(cut; cores, burn_in = 5),       # map 20 is still map 20
                cores -> extractAssignments(cut; cores)]
        for run in runs, cores in (1, 4)
            e = errorOf(() -> run(cores))
            @test e isa AtlasFormatError && startswith(e.msg, at)
        end
        first = damagedCT(mktempdir(); k = 1)                   # the first map, read on its own
        @test startswith(errorOf(() -> relabelAtlas(first, first * ".out")).msg, "$first, line 4 (map 1): ")
        @test startswith(errorOf(() -> extractMapData(first)).msg, "$first, line 4 (map 1): ")
    end

    @testset "keep_partial: what a failed run wrote is kept, under an .incomplete name" begin
        dir = mktempdir()
        cut = damagedCT(dir)
        dst = joinpath(dir, "out.jsonl.gz")
        kept = joinpath(dir, "out.incomplete.jsonl.gz")
        @test_logs (:warn, Regex("kept .*" * basename(kept))) match_mode = :any begin
            @test_throws AtlasFormatError relabelAtlas(cut, dst; keep_partial = true, cores = 1)
        end
        @test !isfile(dst) && length(mapsIn(kept)) == 19               # the maps before the damaged one
        for cores in (1, 4)                                             # with several threads too
            relabelAtlas(PO_CT, joinpath(dir, "full.jsonl.gz"); cores)
            @test_logs (:warn, r"kept") match_mode = :any begin
                @test_throws AtlasFormatError relabelAtlas(cut, dst; keep_partial = true, cores)
            end
            @test [m.districting for m in mapsIn(kept)] ==
                  [m.districting for m in mapsIn(joinpath(dir, "full.jsonl.gz"))[1:19]]   # relabeled as in full
        end
        @test isempty(tmpFiles(dir))

        out = joinpath(dir, "x")
        @test_logs (:warn, r"kept") match_mode = :any begin
            @test_throws AtlasFormatError extractMapData(cut, out; keep_partial = true, cores = 1)
        end
        csvs = sort(readdir(out))
        @test "get_log_spanning_trees.incomplete.csv.gz" in csvs && !("get_log_spanning_trees.csv.gz" in csvs)
        io = smartOpen(joinpath(out, "get_log_spanning_trees.incomplete.csv.gz"), "r")
        @test length(readlines(io)) == 1 + 19                         # the header and the maps before
        close(io)

        @test_logs (:warn, r"kept") match_mode = :any begin
            @test_throws AtlasFormatError extractAssignments(cut; keep_partial = true, cores = 1)
        end
        @test isfile(joinpath(dir, "cut-assignments.incomplete.csv.gz"))
        @test !isfile(joinpath(dir, "cut-assignments.csv.gz")) && isempty(tmpFiles(dir))
    end

    @testset "an input named like the output's temporary or kept file is refused, not overwritten" begin
        dir = mktempdir()
        src = joinpath(dir, "run.tmp.jsonl.gz")                 # tempPath("run.jsonl.gz")
        cp(PO_CT, src)
        before = read(src)
        e = errorOf(() -> relabelAtlas(src, joinpath(dir, "run.jsonl.gz")))
        @test e isa ErrorException && startswith(e.msg, "relabelAtlas: the input $src is named like the temporary")
        @test read(src) == before && !isfile(joinpath(dir, "run.jsonl.gz"))
        kept = joinpath(dir, "out.incomplete.jsonl.gz")         # incompletePath("out.jsonl.gz")
        cp(PO_CT, kept)
        e = errorOf(() -> relabelAtlas(kept, joinpath(dir, "out.jsonl.gz"); keep_partial = true))
        @test e isa ErrorException && occursin("kept incomplete output", e.msg) && read(kept) == before
        @test relabelAtlas(kept, joinpath(dir, "out.jsonl.gz")) == 41    # without keep_partial it cannot clash
    end

    @testset "an atlas with a bad header: an error, and no temporary file left" begin
        dir = mktempdir()
        bad = joinpath(dir, "bad.jsonl")
        write(bad, "not an atlas\n")
        @test_throws AtlasFormatError relabelAtlas(bad, joinpath(dir, "o.jsonl.gz"))
        @test isempty(tmpFiles(dir)) && !isfile(joinpath(dir, "o.jsonl.gz"))
    end

    @testset "writeHistograms: a field's CSV and JSON are written together or not at all" begin
        dir = mktempdir()
        hists, _ = mapDataHistograms(PO_CT)
        field = "get_log_spanning_trees"
        # The JSON cannot be written (a directory is in the way of its temporary file): no CSV either.
        mkpath(tempPath(joinpath(dir, field * "-histogram.json.gz")))
        @test_throws Exception writeHistograms(dir, hists)
        @test !isfile(joinpath(dir, field * "-histogram.csv.gz"))
        @test !isfile(joinpath(dir, field * "-histogram.csv.gz") |> tempPath)
        rm(tempPath(joinpath(dir, field * "-histogram.json.gz")); force = true, recursive = true)
        r = writeHistograms(dir, hists)            # a rerun writes the pair; it skips only the complete pairs
        csv, json = joinpath(dir, field * "-histogram.csv.gz"), joinpath(dir, field * "-histogram.json.gz")
        @test csv in r.written && json in r.written && isfile(csv) && isfile(json)
        pairOf(p) = replace(p, r"\.csv\.gz$" => ".json.gz", r"\.json\.gz$" => ".csv.gz")
        @test all(p -> isfile(pairOf(p)), r.skipped)
    end

    @testset "mapDataHistograms: a bad map is an error (and the atlas is closed)" begin
        dir = mktempdir()
        @test_throws AtlasFormatError mapDataHistograms(damagedCT(dir); cores = 1)
        rm(dir; recursive = true)        # nothing still holds the file open (it would fail on Windows)
        @test !isdir(dir)
    end
end
