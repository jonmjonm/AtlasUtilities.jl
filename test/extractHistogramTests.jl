# Tests for the `atlas extract-map-data-histogram` subcommand: the CSV rendering
# helpers and an end-to-end run checked against the atlas's own map data (and,
# for --add, against `extract-map-data`'s own oracle-checked output).

using Test
using AtlasIO
using AtlasUtilities: run_extract_map_data_histogram, mapDataHistograms,
                      writeHistogramCSV, histSummaryHeader, run_extract
using StreamHistogram: StreamHist, add!, finalize!, nobs, datarange, mean

readtext(p) = (io = smartOpen(p, "r"); s = read(io, String); close(io); s)

"""Split a histogram CSV's text into (summaryRows, binRows), each a header row
followed by its data rows (see `writeHistogramCSV`'s two-block format)."""
function histBlocks(text)
    lines = split(text, "\n")
    blank = findfirst(isempty, lines)
    block1 = lines[1:(blank - 1)]
    block2 = filter(!isempty, lines[(blank + 1):end])
    return block1, block2
end

@testset "extract-map-data-histogram" begin

    @testset "helpers: writeHistogramCSV round-trips a synthetic StreamHist" begin
        mkHist() = StreamHist(; binRange = (0.0, 10.0), binNum = 5)

        @testset "scalar field (bare StreamHist)" begin
            oh = mkHist()
            add!(oh, [1.0, 2.0, 3.0, 9.0])
            finalize!(oh)

            dir = mktempdir()
            path = joinpath(dir, "f-histogram.csv")
            writeHistogramCSV(path, oh)
            block1, block2 = histBlocks(readtext(path))

            @test block1[1] * "\n" == histSummaryHeader(oh.momentPowers)
            @test length(block1) == 2                        # header + one index row
            cells = split(block1[2], ",")
            @test cells[1] == "1"                             # index
            @test parse(Int, cells[2]) == 4                    # nobs
            @test parse(Float64, cells[5]) == 1.0              # exact_min
            @test parse(Float64, cells[6]) == 9.0              # exact_max

            @test block2[1] == "index,edge_lo,edge_hi,exact_count,ash_count"
            @test length(block2) == 1 + 5                      # header + 5 bins
            @test all(startswith(r, "1,") for r in block2[2:end])
        end

        @testset "vector field (Vector{StreamHist})" begin
            oh1, oh2 = mkHist(), mkHist()
            add!(oh1, [1.0, 2.0]); add!(oh2, [7.0, 8.0, 9.0])
            finalize!(oh1); finalize!(oh2)

            dir = mktempdir()
            path = joinpath(dir, "f-histogram.csv")
            writeHistogramCSV(path, [oh1, oh2])
            block1, block2 = histBlocks(readtext(path))

            @test length(block1) == 3                          # header + 2 index rows
            @test split(block1[2], ",")[1] == "1"
            @test split(block1[3], ",")[1] == "2"
            @test parse(Int, split(block1[2], ",")[2]) == 2     # oh1 nobs
            @test parse(Int, split(block1[3], ",")[2]) == 3     # oh2 nobs

            @test length(block2) == 1 + 2 * 5                   # header + 5 bins per index
            @test count(r -> startswith(r, "1,"), block2[2:end]) == 5
            @test count(r -> startswith(r, "2,"), block2[2:end]) == 5
        end

        @testset "--integer omits ash_count and relerr columns" begin
            oh = StreamHist(; integer = true, binRange = (0.0, 10.0))
            add!(oh, [1.0, 2.0, 3.0])
            finalize!(oh)

            dir = mktempdir()
            path = joinpath(dir, "f-histogram.csv")
            writeHistogramCSV(path, oh)
            block1, block2 = histBlocks(readtext(path))

            nPowers = length(oh.momentPowers)
            @test split(block1[2], ",")[(end - nPowers + 1):end] == fill("", nPowers)
            @test all(r -> split(r, ",")[end] == "", block2[2:end])   # ash_count blank
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
        @test isfile(joinpath(outdir, field * "-histogram.csv.gz"))
        block1, _ = histBlocks(readtext(joinpath(outdir, field * "-histogram.csv.gz")))
        cells = split(block1[2], ",")

        @test parse(Int, cells[2]) == length(vals)                        # nobs
        @test parse(Float64, cells[5]) == minimum(vals)                   # exact_min
        @test parse(Float64, cells[6]) == maximum(vals)                   # exact_max
        @test isapprox(parse(Float64, cells[7]), sum(vals) / length(vals); rtol = 1e-9)  # mean

        # Default skip: re-running writes nothing (files already exist).
        before = mtime(joinpath(outdir, field * "-histogram.csv.gz"))
        run_extract_map_data_histogram(atlaspath; quiet = true)
        @test mtime(joinpath(outdir, field * "-histogram.csv.gz")) == before
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

        hsorted = mapDataHistograms(src; sortVals = true, quiet = true)
        hraw = mapDataHistograms(src; sortVals = false, quiet = true)

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
    # counted. Check this directly against the written CSV (both blocks) for
    # every field (scalar and vector) of a real run.
    @testset "bin-sum-consistency: sum(exact_count) + underflow + overflow == nobs" begin
        src = joinpath(@__DIR__, "..", "examples", "cycleWalk_ct_slice.jsonl.gz")
        dir = mktempdir()
        atlaspath = joinpath(dir, "run.jsonl.gz"); cp(src, atlaspath)
        run_extract_map_data_histogram(atlaspath; quiet = true)
        outdir = joinpath(dir, "run")

        for field in ["get_log_spanning_forests", "get_log_spanning_trees",
                      "get_isoperimetric_scores"]
            block1, block2 = histBlocks(readtext(joinpath(outdir, field * "-histogram.csv.gz")))
            for row in block1[2:end]                       # one row per index
                cells = split(row, ",")
                idx, nobsRow, underflow, overflow =
                    parse.(Int, cells[1:4])
                binSum = sum(parse(Int, split(r, ",")[4])
                              for r in block2[2:end] if parse(Int, split(r, ",")[1]) == idx)
                @test binSum + underflow + overflow == nobsRow
            end
        end
    end

    # `integer=:auto` only resolves via `add!`'s learn-completion path once
    # `learnLength` points arrive; a real atlas run is typically far short of the
    # default 10_000, so this exercises `finalize!`'s early-buffer-flush path
    # resolving the decision instead.
    @testset "integer=:auto resolves per-histogram from a short run" begin
        src = joinpath(@__DIR__, "..", "examples", "cycleWalk_ct_slice.jsonl.gz")

        h = mapDataHistograms(src; integer = :auto, quiet = true)
        @test h["get_log_spanning_forests"].integer == false   # log-valued, resolved non-integer

        dir = mktempdir()
        atlaspath = joinpath(dir, "run.jsonl.gz"); cp(src, atlaspath)
        run_extract_map_data_histogram(atlaspath; integer = :auto, quiet = true)
        block1, _ = histBlocks(readtext(joinpath(dir, "run", "get_log_spanning_forests-histogram.csv.gz")))
        cells = split(block1[2], ",")
        @test cells[end] != ""   # relerr column populated -> resolved to non-integer, ASH available
    end

    @testset "--burn-in skips the first n maps" begin
        src = joinpath(@__DIR__, "..", "examples", "cycleWalk_ct_slice.jsonl.gz")
        field = "get_log_spanning_forests"

        a = openAtlas(smartOpen(src, "r"))
        total = 0; while !eof(a); nextMap(a); total += 1; end; close(a)

        h0 = mapDataHistograms(src; quiet = true)
        h2 = mapDataHistograms(src; burn_in = 2, quiet = true)
        @test nobs(h0[field]) == total
        @test nobs(h2[field]) == total - 2

        @test_throws ErrorException mapDataHistograms(src; burn_in = total + 1, quiet = true)
    end

<<<<<<< HEAD
=======
    @testset "--max-maps stops early (composes with --burn-in) and tags output -partial" begin
        src = joinpath(@__DIR__, "..", "examples", "cycleWalk_ct_slice.jsonl.gz")
        field = "get_log_spanning_forests"

        h = mapDataHistograms(src; burn_in = 2, max_maps = 5, quiet = true)
        @test nobs(h[field]) == 5
        @test_throws ErrorException mapDataHistograms(src; max_maps = -1, quiet = true)

        dir = mktempdir()
        atlaspath = joinpath(dir, "run.jsonl.gz"); cp(src, atlaspath)
        run_extract_map_data_histogram(atlaspath; burn_in = 2, max_maps = 5, quiet = true)
        outdir = joinpath(dir, "run")

        partialCsv = joinpath(outdir, field * "-histogram-partial.csv.gz")
        @test isfile(partialCsv)
        @test !isfile(joinpath(outdir, field * "-histogram.csv.gz"))  # no unsuffixed file written
        block1, _ = histBlocks(readtext(partialCsv))
        @test parse(Int, split(block1[2], ",")[2]) == 5               # nobs

        about = read(joinpath(outdir, "about.md"), String)
        @test occursin("--burn-in 2", about)
        @test occursin("--max-maps 5", about)
        @test occursin("Partial extraction", about)
    end

>>>>>>> e34b6c4a06a8daff341a75d53858faa4b49d1283
    @testset "cores=1 (serial) matches multithreaded, up to machine precision" begin
        src = joinpath(@__DIR__, "..", "examples", "cycleWalk_ct_slice.jsonl.gz")
        field = "get_log_spanning_forests"

        hser = mapDataHistograms(src; cores = 1, quiet = true)
        hpar = mapDataHistograms(src; cores = Threads.nthreads(), quiet = true)

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
        block1, _ = histBlocks(readtext(joinpath(dirHist, "run", field * "-histogram.csv.gz")))

        for j in 1:w
            cells = split(block1[1 + j], ",")
            csvVals = colvals(j)
            @test parse(Int, cells[2]) == length(csvVals)
            @test isapprox(parse(Float64, cells[5]), minimum(csvVals); rtol = 1e-6)
            @test isapprox(parse(Float64, cells[6]), maximum(csvVals); rtol = 1e-6)
        end
    end

    @testset "--no-compression writes plain .csv" begin
        src = joinpath(@__DIR__, "..", "examples", "cycleWalk_ct_metadata.jsonl.gz")
        dir = mktempdir()
        atlaspath = joinpath(dir, "meta.jsonl.gz"); cp(src, atlaspath)
        run_extract_map_data_histogram(atlaspath; compress = false, quiet = true)
        files = readdir(joinpath(dir, "meta"))
        @test "about.md" in files
        @test !isempty(filter(f -> endswith(f, "-histogram.csv"), files))
        @test all(f -> endswith(f, "-histogram.csv") || f == "about.md", files)
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
