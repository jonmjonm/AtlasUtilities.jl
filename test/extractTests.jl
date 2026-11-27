# Tests for the `atlas extract-map-data` subcommand: the CSV/value helpers and an
# end-to-end extraction checked against the atlas's own map data.

using Test
using AtlasIO
using AtlasUtilities: extractMapData, stripAtlasExt, flattenVal, headerRow, valueRow

readtext(p) = (io = smartOpen(p, "r"); s = read(io, String); close(io); s)
rowsof(s) = filter(!isempty, split(s, "\n"))

@testset "extract-map-data" begin

    @testset "helpers" begin
        @test stripAtlasExt("a/b/foo.jsonl.gz") == "a/b/foo"
        @test stripAtlasExt("foo.jsonl.bz2") == "foo"
        @test stripAtlasExt("foo.jsonl") == "foo"
        @test stripAtlasExt("foo.csv") == "foo"          # falls back to splitext

        @test flattenVal(3.0) == [3.0]                   # scalar -> one cell
        @test flattenVal([1, 2, 3]) == [1, 2, 3]         # vector -> spread

        @test headerRow("f", 1) == "name,f,map_weight\n"
        @test headerRow("f", 3) == "name,f_1,f_2,f_3,map_weight\n"

        @test valueRow("m", 900.5, 1, 1) == "m,900.5,1\n"
        @test valueRow("m", [1.0, 2.0], 2, 0.25) == "m,1.0,2.0,0.25\n"
        @test valueRow("m", nothing, 2, 3) == "m,,,3\n"       # missing -> empty cells, weight still written
        @test valueRow("a,b", 1, 1, 1) == "\"a,b\",1,1\n"     # name with comma is quoted
    end

    # End-to-end: extract the real CT slice's map data and check each CSV against
    # the atlas's own stored values.
    @testset "oracle: extracted CSV matches map data" begin
        graph = joinpath(@__DIR__, "..", "Data", "CT_pct20.json")
        src = joinpath(@__DIR__, "..", "examples", "cycleWalk_ct_slice.jsonl.gz")
        fields = ["get_log_spanning_trees", "get_log_spanning_forests",
                  "get_isoperimetric_scores"]

        dir = mktempdir()
        atlaspath = joinpath(dir, "run.jsonl.gz")
        cp(src, atlaspath)

        extractMapData(atlaspath)
        outdir = joinpath(dir, "run")

        # Read the atlas maps for comparison.
        a = openAtlas(smartOpen(atlaspath, "r"))
        maps = Map[]; while !eof(a); push!(maps, nextMap(a)); end; close(a)
        @test length(maps) >= 40

        asvec(x) = x isa AbstractVector ? Float64.(x) : [Float64(x)]
        for f in fields
            @test isfile(joinpath(outdir, f * ".csv.gz"))
            rows = rowsof(readtext(joinpath(outdir, f * ".csv.gz")))
            @test length(rows) == length(maps) + 1       # header + one row per map
            width = length(asvec(maps[1].data[f]))
            @test rows[1] == (width == 1 ? "name,$f" :
                              "name," * join(["$(f)_$i" for i in 1:width], ",")) * ",map_weight"
            for (i, m) in enumerate(maps)
                cells = split(rows[i + 1], ",")
                @test cells[1] == m.name
                @test parse.(Float64, cells[2:end-1]) == asvec(m.data[f])
                @test parse(Float64, cells[end]) == m.weight
            end
        end

        # Default skip: re-running writes nothing (files already exist).
        before = mtime(joinpath(outdir, "get_log_spanning_forests.csv.gz"))
        r = extractMapData(atlaspath)
        @test mtime(joinpath(outdir, "get_log_spanning_forests.csv.gz")) == before
        @test r.written == [joinpath(outdir, "about.md")] && joinpath(outdir, "get_log_spanning_forests.csv.gz") in r.skipped
    end

    @testset "--max-maps stops early and tags output -partial" begin
        src = joinpath(@__DIR__, "..", "examples", "cycleWalk_ct_slice.jsonl.gz")
        field = "get_log_spanning_forests"
        dir = mktempdir()
        atlaspath = joinpath(dir, "run.jsonl.gz"); cp(src, atlaspath)
        extractMapData(atlaspath; max_maps = 5)
        outdir = joinpath(dir, "run")

        partialCsv = joinpath(outdir, field * "-partial.csv.gz")
        @test isfile(partialCsv)
        @test !isfile(joinpath(outdir, field * ".csv.gz"))     # no unsuffixed file written
        rows = rowsof(readtext(partialCsv))
        @test length(rows) == 5 + 1                            # header + 5 maps

        about = read(joinpath(outdir, "about.md"), String)
        @test occursin("--max-maps 5", about)
        @test occursin("Partial extraction", about)

        # A full run afterward doesn't collide with (or get shadowed by) the
        # partial run's files, since they're named differently.
        extractMapData(atlaspath; force = true)
        @test isfile(joinpath(outdir, field * ".csv.gz"))
        fullRows = rowsof(readtext(joinpath(outdir, field * ".csv.gz")))
        @test length(fullRows) > length(rows)
    end

    @testset "--max-maps rejects a negative value" begin
        src = joinpath(@__DIR__, "..", "examples", "cycleWalk_ct_slice.jsonl.gz")
        dir = mktempdir()
        atlaspath = joinpath(dir, "run.jsonl.gz"); cp(src, atlaspath)
        @test_throws ErrorException extractMapData(atlaspath; max_maps = -1)
    end

    @testset "--no-compression writes plain .csv" begin
        src = joinpath(@__DIR__, "..", "examples", "cycleWalk_ct_metadata.jsonl.gz")
        dir = mktempdir()
        atlaspath = joinpath(dir, "meta.jsonl.gz"); cp(src, atlaspath)
        extractMapData(atlaspath; compress = false)
        files = readdir(joinpath(dir, "meta"))
        @test "about.md" in files                        # about.md accompanies the CSVs
        @test !isempty(filter(f -> endswith(f, ".csv"), files))
        @test all(f -> endswith(f, ".csv") || f == "about.md", files)
    end

    # about.md carries the atlas info (minus the embedded script) plus provenance.
    @testset "about.md content" begin
        # This fixture embeds its generating script in the header.
        src = joinpath(@__DIR__, "..", "examples", "cycleWalk_ct_metadata.jsonl.gz")
        dir = mktempdir()
        atlaspath = joinpath(dir, "meta.jsonl.gz"); cp(src, atlaspath)
        extractMapData(atlaspath)

        about = joinpath(dir, "meta", "about.md")
        @test isfile(about)
        txt = read(about, String)

        # source atlas name + extraction date + the atlas info blocks
        @test occursin("meta.jsonl.gz", txt)             # source atlas name
        @test occursin("Source atlas:", txt)
        @test occursin("Extraction date:", txt)
        @test occursin("Atlas Header", txt)
        @test occursin("Atlas Parameters", txt)
        @test occursin("districts", txt)                 # a real header param
        @test occursin("Map Data Fields", txt)
        @test occursin("get_log_spanning_trees", txt)    # first map's field names

        # the embedded script source is NOT leaked (only its script_name may appear)
        a = openAtlas(smartOpen(atlaspath, "r"))
        script = get(a.atlasParam, "script", nothing)
        close(a)
        @test script !== nothing                         # fixture really has a script
        token = String(script)[1:min(60, length(String(script)))]
        @test !occursin(token, txt)                      # script body absent from about.md
    end

end
