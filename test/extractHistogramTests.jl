# Tests for the `atlas extract-map-data-histogram` subcommand: the CSV + JSON
# rendering helpers and an end-to-end run checked against the atlas's own map data
# (and, for --add, against `extract-map-data`'s own oracle-checked output).

using Test
using JSON3
using AtlasIO
using AtlasUtilities: run_extract_map_data_histogram, mapDataHistograms,
                      writeHistogramCSV, writeHistogramJSON, run_extract
using StreamHistogram: StreamHist, add!, finalize!, nobs, datarange, mean

readtext(p) = (io = smartOpen(p, "r"); s = read(io, String); close(io); s)

"""Split a histogram CSV's text into (header, dataRows)."""
function csvRows(text)
    lines = filter(!isempty, split(text, "\n"))
    return lines[1], lines[2:end]
end

"""Read a histogram JSON's `histograms` dict, keyed by index (as written, string
keys `"1"`, `"2"`, ...)."""
readHistJSON(path) = JSON3.read(readtext(path))["histograms"]

@testset "extract-map-data-histogram" begin

    @testset "helpers: writeHistogramCSV/JSON round-trip a synthetic StreamHist" begin
        mkHist() = StreamHist(; binRange = (0.0, 10.0), binNum = 5)

        @testset "scalar field (bare StreamHist)" begin
            oh = mkHist()
            add!(oh, [1.0, 2.0, 3.0, 9.0])
            finalize!(oh)

            dir = mktempdir()
            csvPath = joinpath(dir, "f-histogram.csv")
            jsonPath = joinpath(dir, "f-histogram.json")
            writeHistogramCSV(csvPath, oh)
            writeHistogramJSON(jsonPath, oh)

            header, rows = csvRows(readtext(csvPath))
            @test header == "index,edge_lo,edge_hi,exact_count"
            @test length(rows) == 5                             # 5 bins
            @test all(startswith(r, "1,") for r in rows)

            hs = readHistJSON(jsonPath)
            @test Set(keys(hs)) == Set([Symbol("1")])
            h1 = hs[Symbol("1")]
            @test h1["nobs"] == 4
            @test h1["exact_min"] == 1.0
            @test h1["exact_max"] == 9.0
            @test length(h1["edges"]) == 6                       # 5 bins -> 6 edges
            @test length(h1["ash_count"]) == 5
        end

        @testset "vector field (Vector{StreamHist})" begin
            oh1, oh2 = mkHist(), mkHist()
            add!(oh1, [1.0, 2.0]); add!(oh2, [7.0, 8.0, 9.0])
            finalize!(oh1); finalize!(oh2)

            dir = mktempdir()
            csvPath = joinpath(dir, "f-histogram.csv")
            jsonPath = joinpath(dir, "f-histogram.json")
            writeHistogramCSV(csvPath, [oh1, oh2])
            writeHistogramJSON(jsonPath, [oh1, oh2])

            _, rows = csvRows(readtext(csvPath))
            @test length(rows) == 2 * 5                          # 5 bins per index
            @test count(r -> startswith(r, "1,"), rows) == 5
            @test count(r -> startswith(r, "2,"), rows) == 5

            hs = readHistJSON(jsonPath)
            @test Set(keys(hs)) == Set([Symbol("1"), Symbol("2")])
            @test hs[Symbol("1")]["nobs"] == 2
            @test hs[Symbol("2")]["nobs"] == 3
        end

        @testset "--integer omits ash_count and relerr_moments" begin
            oh = StreamHist(; integer = true, binRange = (0.0, 10.0))
            add!(oh, [1.0, 2.0, 3.0])
            finalize!(oh)

            dir = mktempdir()
            jsonPath = joinpath(dir, "f-histogram.json")
            writeHistogramJSON(jsonPath, oh)

            h1 = readHistJSON(jsonPath)[Symbol("1")]
            @test h1["integer"] == true
            @test h1["relerr_moments"] === nothing
            @test h1["ash_count"] === nothing
        end
    end

    # End-to-end: run the CLI driver on the real CT slice and check the histogram's
    # summary stats against values computed directly from the atlas's own map data.
    @testset "oracle: histogram stats match map data (scalar field)" begin
        src = joinpath(@__DIR__, "..", "examples", "cycleWalk_ct_slice.jsonl.gz")
        field = "get_log_spanning_forests"   # scalar per map

        dir = mktempdir()
        atlaspath = joinpath(dir, "run.jsonl.gz")
        cp(src, atlaspath)

        a = openAtlas(smartOpen(atlaspath, "r"))
        maps = Map[]; while !eof(a); push!(maps, nextMap(a)); end; close(a)
        @test length(maps) >= 40
        vals = Float64[m.data[field] for m in maps]

        run_extract_map_data_histogram(atlaspath; quiet = true)
        outdir = joinpath(dir, "run")
        csvPath = joinpath(outdir, field * "-histogram.csv.gz")
        jsonPath = joinpath(outdir, field * "-histogram.json.gz")
        @test isfile(csvPath)
        @test isfile(jsonPath)
        h1 = readHistJSON(jsonPath)[Symbol("1")]

        @test h1["nobs"] == length(vals)
        @test h1["exact_min"] == minimum(vals)
        @test h1["exact_max"] == maximum(vals)
        @test isapprox(h1["mean"], sum(vals) / length(vals); rtol = 1e-9)

        # Default skip: re-running writes nothing (files already exist).
        before = mtime(csvPath)
        run_extract_map_data_histogram(atlaspath; quiet = true)
        @test mtime(csvPath) == before
    end

    # A vector field's per-index histograms: with sortVals (default) index j holds
    # the j-th order statistic of each map's (sorted) vector; with sortVals=false
    # index j holds the raw j-th entry.
    @testset "oracle: vector field sortVals vs raw ordering" begin
        src = joinpath(@__DIR__, "..", "examples", "cycleWalk_ct_slice.jsonl.gz")
        field = "get_isoperimetric_scores"

        a = openAtlas(smartOpen(src, "r"))
        maps = Map[]; while !eof(a); push!(maps, nextMap(a)); end; close(a)
        w = length(maps[1].data[field])

        hsorted, _ = mapDataHistograms(src; sortVals = true, quiet = true)
        hraw, _ = mapDataHistograms(src; sortVals = false, quiet = true)

        for j in 1:w
            sortedVals = [sort(Float64.(m.data[field]))[j] for m in maps]
            rawVals = [Float64.(m.data[field])[j] for m in maps]

            @test nobs(hsorted[field][j]) == length(sortedVals)
            @test datarange(hsorted[field][j]) == (minimum(sortedVals), maximum(sortedVals))

            @test nobs(hraw[field][j]) == length(rawVals)
            @test datarange(hraw[field][j]) == (minimum(rawVals), maximum(rawVals))
        end

        # Sorting makes the per-index ranges nondecreasing across the vector's width.
        mins = [datarange(hsorted[field][j])[1] for j in 1:w]
        @test issorted(mins)
    end

    # Every point fed to a StreamHist lands in exactly one of: a traditional-
    # histogram bin, underflow, or overflow -- never dropped, never double
    # counted. Check this directly against the written CSV (exact_count) and JSON
    # (underflow/overflow/nobs) for every field (scalar and vector) of a real run.
    @testset "bin-sum-consistency: sum(exact_count) + underflow + overflow == nobs" begin
        src = joinpath(@__DIR__, "..", "examples", "cycleWalk_ct_slice.jsonl.gz")
        dir = mktempdir()
        atlaspath = joinpath(dir, "run.jsonl.gz"); cp(src, atlaspath)
        run_extract_map_data_histogram(atlaspath; quiet = true)
        outdir = joinpath(dir, "run")

        for field in ["get_log_spanning_forests", "get_log_spanning_trees",
                      "get_isoperimetric_scores"]
            _, rows = csvRows(readtext(joinpath(outdir, field * "-histogram.csv.gz")))
            hs = readHistJSON(joinpath(outdir, field * "-histogram.json.gz"))
            for (idxKey, h) in hs
                idx = string(idxKey)
                binSum = sum(parse(Int, split(r, ",")[4])
                              for r in rows if split(r, ",")[1] == idx)
                @test binSum + h["underflow"] + h["overflow"] == h["nobs"]
            end
        end
    end

    # `integer=:auto` only resolves via `add!`'s learn-completion path once
    # `learnLength` points arrive; a real atlas run is typically far short of the
    # default 10_000, so this exercises `finalize!`'s early-buffer-flush path
    # resolving the decision instead.
    @testset "integer=:auto resolves per-histogram from a short run" begin
        src = joinpath(@__DIR__, "..", "examples", "cycleWalk_ct_slice.jsonl.gz")

        h, _ = mapDataHistograms(src; integer = :auto, quiet = true)
        @test h["get_log_spanning_forests"].integer == false   # log-valued, resolved non-integer

        dir = mktempdir()
        atlaspath = joinpath(dir, "run.jsonl.gz"); cp(src, atlaspath)
        run_extract_map_data_histogram(atlaspath; integer = :auto, quiet = true)
        h1 = readHistJSON(joinpath(dir, "run", "get_log_spanning_forests-histogram.json.gz"))[Symbol("1")]
        @test h1["relerr_moments"] !== nothing   # resolved to non-integer, ASH available
    end

    @testset "--burn-in skips the first n maps" begin
        src = joinpath(@__DIR__, "..", "examples", "cycleWalk_ct_slice.jsonl.gz")
        field = "get_log_spanning_forests"

        a = openAtlas(smartOpen(src, "r"))
        total = 0; while !eof(a); nextMap(a); total += 1; end; close(a)

        h0, n0 = mapDataHistograms(src; quiet = true)
        h2, n2 = mapDataHistograms(src; burn_in = 2, quiet = true)
        @test nobs(h0[field]) == total
        @test nobs(h2[field]) == total - 2
        @test n0 == total
        @test n2 == total - 2

        @test_throws ErrorException mapDataHistograms(src; burn_in = total + 1, quiet = true)
    end

    @testset "--max-maps stops early (composes with --burn-in) and tags output -partial" begin
        src = joinpath(@__DIR__, "..", "examples", "cycleWalk_ct_slice.jsonl.gz")
        field = "get_log_spanning_forests"

        h, n = mapDataHistograms(src; burn_in = 2, max_maps = 5, quiet = true)
        @test nobs(h[field]) == 5
        @test n == 5
        @test_throws ErrorException mapDataHistograms(src; max_maps = -1, quiet = true)

        dir = mktempdir()
        atlaspath = joinpath(dir, "run.jsonl.gz"); cp(src, atlaspath)
        run_extract_map_data_histogram(atlaspath; burn_in = 2, max_maps = 5, quiet = true)
        outdir = joinpath(dir, "run")

        partialCsv = joinpath(outdir, field * "-histogram-partial.csv.gz")
        partialJson = joinpath(outdir, field * "-histogram-partial.json.gz")
        @test isfile(partialCsv)
        @test isfile(partialJson)
        @test !isfile(joinpath(outdir, field * "-histogram.csv.gz"))  # no unsuffixed file written
        @test !isfile(joinpath(outdir, field * "-histogram.json.gz"))
        h1 = readHistJSON(partialJson)[Symbol("1")]
        @test h1["nobs"] == 5

        about = read(joinpath(outdir, "about.md"), String)
        @test occursin("--burn-in 2", about)
        @test occursin("--max-maps 5", about)
        @test occursin("Partial extraction", about)
    end

    @testset "cores=1 (serial) matches multithreaded, up to machine precision" begin
        src = joinpath(@__DIR__, "..", "examples", "cycleWalk_ct_slice.jsonl.gz")
        field = "get_log_spanning_forests"

        hser, _ = mapDataHistograms(src; cores = 1, quiet = true)
        hpar, _ = mapDataHistograms(src; cores = Threads.nthreads(), quiet = true)

        @test nobs(hser[field]) == nobs(hpar[field])
        @test datarange(hser[field]) == datarange(hpar[field])             # min/max: order-independent
        @test isapprox(mean(hser[field]), mean(hpar[field]); rtol = 1e-9)  # sum: order-dependent to float precision
    end

    # --add recomputes a field; cross-check against extract-map-data's own
    # oracle-checked CSV output rather than duplicating CycleWalk's math here.
    @testset "--add cross-checked against extract-map-data" begin
        graph = joinpath(@__DIR__, "..", "Data", "CT_pct20.json")
        src = joinpath(@__DIR__, "..", "examples", "cycleWalk_ct_slice.jsonl.gz")
        field = "get_isoperimetric_scores"
        addOpts = (add = "get_isoperimetric_scores", graph = graph, pop_col = "POP20",
                   node_col = "NAME", area_col = "area", border_col = "border_length",
                   edge_perimeter_col = "length", force = true, quiet = true)

        dirCsv = mktempdir(); atlasCsv = joinpath(dirCsv, "run.jsonl.gz"); cp(src, atlasCsv)
        run_extract(atlasCsv; addOpts...)
        rowsCsv = filter(!isempty, split(readtext(joinpath(dirCsv, "run", field * ".csv.gz")), "\n"))
        w = length(split(rowsCsv[1], ",")) - 1
        colvals(j) = [parse(Float64, split(r, ",")[1 + j]) for r in rowsCsv[2:end]]

        dirHist = mktempdir(); atlasHist = joinpath(dirHist, "run.jsonl.gz"); cp(src, atlasHist)
        run_extract_map_data_histogram(atlasHist; sortVals = false, addOpts...)
        hs = readHistJSON(joinpath(dirHist, "run", field * "-histogram.json.gz"))

        for j in 1:w
            h = hs[Symbol(string(j))]
            csvVals = colvals(j)
            @test h["nobs"] == length(csvVals)
            @test isapprox(h["exact_min"], minimum(csvVals); rtol = 1e-6)
            @test isapprox(h["exact_max"], maximum(csvVals); rtol = 1e-6)
        end
    end

    @testset "--no-compression writes plain .csv/.json" begin
        src = joinpath(@__DIR__, "..", "examples", "cycleWalk_ct_metadata.jsonl.gz")
        dir = mktempdir()
        atlaspath = joinpath(dir, "meta.jsonl.gz"); cp(src, atlaspath)
        run_extract_map_data_histogram(atlaspath; compress = false, quiet = true)
        files = readdir(joinpath(dir, "meta"))
        @test "about.md" in files
        @test !isempty(filter(f -> endswith(f, "-histogram.csv"), files))
        @test !isempty(filter(f -> endswith(f, "-histogram.json"), files))
        @test all(f -> endswith(f, "-histogram.csv") || endswith(f, "-histogram.json") ||
                       f == "about.md", files)
    end

    @testset "about.md content" begin
        src = joinpath(@__DIR__, "..", "examples", "cycleWalk_ct_metadata.jsonl.gz")
        dir = mktempdir()
        atlaspath = joinpath(dir, "meta.jsonl.gz"); cp(src, atlaspath)
        run_extract_map_data_histogram(atlaspath; quiet = true)

        about = joinpath(dir, "meta", "about.md")
        @test isfile(about)
        txt = read(about, String)
        @test occursin("meta.jsonl.gz", txt)
        @test occursin("Source atlas:", txt)
        @test occursin("Atlas Header", txt)
        @test occursin("Map Data Fields", txt)
    end

end
