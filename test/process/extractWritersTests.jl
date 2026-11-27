# `extractMapData` and `mapDataHistograms` with `writers` (the CycleWalk extension). The reading helpers
# (`readtext`, `rowsof`, `readHistJSON`, `histogramFiles`) come from the library tests.

using Test
using AtlasIO
using AtlasUtilities: extractMapData, WriterSet

@testset "extract with writers" begin

    @testset "writers recompute a field to the stored values" begin
        graph = joinpath(@__DIR__, "..", "..", "Data", "CT_pct20.json")
        src = joinpath(@__DIR__, "..", "..", "examples", "cycleWalk_ct_slice.jsonl.gz")
        a = openAtlas(smartOpen(src, "r"))
        maps = Map[]; while !eof(a); push!(maps, nextMap(a)); end; close(a)
        asvec(x) = x isa AbstractVector ? Float64.(x) : [Float64(x)]

        # --add recomputes a field; its extracted values must match the stored ones.
        dir2 = mktempdir()
        atlas2 = joinpath(dir2, "run.jsonl.gz"); cp(src, atlas2)
        ws = WriterSet(["get_isoperimetric_scores"]; graph = graph, pop_col = "POP20", node_col = "NAME",
                       area_col = "area", border_col = "border_length", edge_perimeter_col = "length")
        r = extractMapData(atlas2; writers = ws, force = true)
        @test r.outdir == joinpath(dir2, "run") && r.nmaps == length(maps) && isempty(r.skipped)
        @test first(r.written) == joinpath(dir2, "run", "about.md")
        @test joinpath(dir2, "run", "get_isoperimetric_scores.csv.gz") in r.written
        rows = rowsof(readtext(joinpath(dir2, "run", "get_isoperimetric_scores.csv.gz")))
        maxrel = 0.0
        for (i, m) in enumerate(maps)
            got = parse.(Float64, split(rows[i + 1], ",")[2:end-1])
            for (x, y) in zip(got, asvec(m.data["get_isoperimetric_scores"]))
                maxrel = max(maxrel, abs(x - y) / max(abs(y), 1e-12))
            end
        end
        @test maxrel < 1e-6
    end

    # --add a partisan writer with --vote-cols: the CSV is named for the expanded
    # field and its rows are the per-district vote shares.
    @testset "--add partisan margins with vote-cols" begin
        graph = joinpath(@__DIR__, "..", "..", "Data", "CT_pct20.json")
        src = joinpath(@__DIR__, "..", "..", "examples", "cycleWalk_ct_slice.jsonl.gz")
        v1, v2 = "G20PREDEM", "G20PREREP"
        field = "get_partisan_margins_$(v1)_$(v2)"

        dir = mktempdir()
        atlaspath = joinpath(dir, "run.jsonl.gz"); cp(src, atlaspath)
        ws = WriterSet(["get_partisan_margins"]; graph = graph, pop_col = "POP20", node_col = "NAME",
                       vote_cols = [(v1, v2)])
        extractMapData(atlaspath; writers = ws, force = true)

        csv = joinpath(dir, "run", field * ".csv.gz")
        @test isfile(csv)
        rows = rowsof(readtext(csv))

        a = openAtlas(smartOpen(atlaspath, "r"))
        d = Int(a.atlasParam["districts"])
        nmaps = length(rows) - 1
        @test nmaps >= 40
        @test rows[1] == "name," * join(["$(field)_$i" for i in 1:d], ",") * ",map_weight"   # per-district header
        for r in rows[2:end]
            cells = parse.(Float64, split(r, ",")[2:end-1])
            @test length(cells) == d
            @test all(0 .<= cells .<= 100)                                    # vote shares
        end
        close(a)
    end

    # --add recomputes a field; cross-check against extract-map-data's own
    # oracle-checked CSV output rather than duplicating CycleWalk's math here.
    @testset "--add cross-checked against extract-map-data" begin
        graph = joinpath(@__DIR__, "..", "..", "Data", "CT_pct20.json")
        src = joinpath(@__DIR__, "..", "..", "examples", "cycleWalk_ct_slice.jsonl.gz")
        field = "get_isoperimetric_scores"
        ws = WriterSet(["get_isoperimetric_scores"]; graph = graph, pop_col = "POP20",
                       node_col = "NAME", area_col = "area", border_col = "border_length",
                       edge_perimeter_col = "length")
        addOpts = (writers = ws, force = true)

        dirCsv = mktempdir(); atlasCsv = joinpath(dirCsv, "run.jsonl.gz"); cp(src, atlasCsv)
        extractMapData(atlasCsv; addOpts...)
        rowsCsv = filter(!isempty, split(readtext(joinpath(dirCsv, "run", field * ".csv.gz")), "\n"))
        w = length(split(rowsCsv[1], ",")) - 2          # minus the name and map_weight columns
        colvals(j) = [parse(Float64, split(r, ",")[1 + j]) for r in rowsCsv[2:end]]

        dirHist = mktempdir(); atlasHist = joinpath(dirHist, "run.jsonl.gz"); cp(src, atlasHist)
        histogramFiles(atlasHist; sort_values = false, addOpts...)
        hs = readHistJSON(joinpath(dirHist, "run", field * "-histogram.json.gz"))

        for j in 1:w
            h = hs[string(j)]
            csvVals = colvals(j)
            @test h["nobs"] == length(csvVals)
            @test isapprox(h["exact_min"], minimum(csvVals); rtol = 1e-6)
            @test isapprox(h["exact_max"], maximum(csvVals); rtol = 1e-6)
        end
    end

end
