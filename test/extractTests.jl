# Tests for the `atlas extract-map-data` subcommand: the CSV/value helpers and an
# end-to-end extraction (including --add) checked against the atlas's own map data.

using Test
using AtlasIO
using AtlasUtilities: run_extract, stripAtlasExt, flattenVal, headerRow, valueRow

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

        @test headerRow("f", 1) == "name,f\n"
        @test headerRow("f", 3) == "name,f_1,f_2,f_3\n"

        @test valueRow("m", 900.5, 1) == "m,900.5\n"
        @test valueRow("m", [1.0, 2.0], 2) == "m,1.0,2.0\n"
        @test valueRow("m", nothing, 2) == "m,,\n"       # missing -> empty cells
        @test valueRow("a,b", 1, 1) == "\"a,b\",1\n"     # name with comma is quoted
    end

    # End-to-end: extract the real CT slice's map data and check each CSV against
    # the atlas's own stored values, then check --add recomputes to ground truth.
    @testset "oracle: extracted CSV matches map data" begin
        graph = joinpath(@__DIR__, "..", "Data", "CT_pct20.json")
        src = joinpath(@__DIR__, "..", "examples", "cycleWalk_ct_slice.jsonl.gz")
        fields = ["get_log_spanning_trees", "get_log_spanning_forests",
                  "get_isoperimetric_scores"]

        dir = mktempdir()
        atlaspath = joinpath(dir, "run.jsonl.gz")
        cp(src, atlaspath)

        run_extract(atlaspath; quiet = true)
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
                              "name," * join(["$(f)_$i" for i in 1:width], ","))
            for (i, m) in enumerate(maps)
                cells = split(rows[i + 1], ",")
                @test cells[1] == m.name
                @test parse.(Float64, cells[2:end]) == asvec(m.data[f])
            end
        end

        # Default skip: re-running writes nothing (files already exist).
        before = mtime(joinpath(outdir, "get_log_spanning_forests.csv.gz"))
        run_extract(atlaspath; quiet = true)
        @test mtime(joinpath(outdir, "get_log_spanning_forests.csv.gz")) == before

        # --add recomputes a field; its extracted values must match the stored ones.
        dir2 = mktempdir()
        atlas2 = joinpath(dir2, "run.jsonl.gz"); cp(src, atlas2)
        run_extract(atlas2; add = "get_isoperimetric_scores", graph = graph,
                    pop_col = "POP20", node_col = "NAME", area_col = "area",
                    border_col = "border_length", edge_perimeter_col = "length",
                    force = true, quiet = true)
        rows = rowsof(readtext(joinpath(dir2, "run", "get_isoperimetric_scores.csv.gz")))
        maxrel = 0.0
        for (i, m) in enumerate(maps)
            got = parse.(Float64, split(rows[i + 1], ",")[2:end])
            for (x, y) in zip(got, asvec(m.data["get_isoperimetric_scores"]))
                maxrel = max(maxrel, abs(x - y) / max(abs(y), 1e-12))
            end
        end
        @test maxrel < 1e-6
    end

    # --add a partisan writer with --vote-cols: the CSV is named for the expanded
    # field and its rows are the per-district vote shares.
    @testset "--add partisan margins with vote-cols" begin
        graph = joinpath(@__DIR__, "..", "Data", "CT_pct20.json")
        src = joinpath(@__DIR__, "..", "examples", "cycleWalk_ct_slice.jsonl.gz")
        v1, v2 = "G20PREDEM", "G20PREREP"
        field = "get_partisan_margins_$(v1)_$(v2)"

        dir = mktempdir()
        atlaspath = joinpath(dir, "run.jsonl.gz"); cp(src, atlaspath)
        run_extract(atlaspath; add = "get_partisan_margins", graph = graph,
                    pop_col = "POP20", node_col = "NAME", vote_cols = "$v1,$v2",
                    force = true, quiet = true)

        csv = joinpath(dir, "run", field * ".csv.gz")
        @test isfile(csv)
        rows = rowsof(readtext(csv))

        a = openAtlas(smartOpen(atlaspath, "r"))
        d = Int(a.atlasParam["districts"])
        nmaps = length(rows) - 1
        @test nmaps >= 40
        @test rows[1] == "name," * join(["$(field)_$i" for i in 1:d], ",")   # per-district header
        for r in rows[2:end]
            cells = parse.(Float64, split(r, ",")[2:end])
            @test length(cells) == d
            @test all(0 .<= cells .<= 100)                                    # vote shares
        end
        close(a)
    end

    @testset "--max-maps stops early and tags output -partial" begin
        src = joinpath(@__DIR__, "..", "examples", "cycleWalk_ct_slice.jsonl.gz")
        field = "get_log_spanning_forests"
        dir = mktempdir()
        atlaspath = joinpath(dir, "run.jsonl.gz"); cp(src, atlaspath)
        run_extract(atlaspath; max_maps = 5, quiet = true)
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
        run_extract(atlaspath; force = true, quiet = true)
        @test isfile(joinpath(outdir, field * ".csv.gz"))
        fullRows = rowsof(readtext(joinpath(outdir, field * ".csv.gz")))
        @test length(fullRows) > length(rows)
    end

    @testset "--max-maps rejects a negative value" begin
        src = joinpath(@__DIR__, "..", "examples", "cycleWalk_ct_slice.jsonl.gz")
        dir = mktempdir()
        atlaspath = joinpath(dir, "run.jsonl.gz"); cp(src, atlaspath)
        @test_throws ErrorException run_extract(atlaspath; max_maps = -1, quiet = true)
    end

    @testset "--no-compression writes plain .csv" begin
        src = joinpath(@__DIR__, "..", "examples", "cycleWalk_ct_metadata.jsonl.gz")
        dir = mktempdir()
        atlaspath = joinpath(dir, "meta.jsonl.gz"); cp(src, atlaspath)
        run_extract(atlaspath; compress = false, quiet = true)
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
        run_extract(atlaspath; quiet = true)

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
