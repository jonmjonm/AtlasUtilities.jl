# Every subcommand run through `command_main`, the entry point the installed `mapatlas` command uses, so the
# command-line layer is tested too: option parsing (e.g. --bins "a,b,c", --integer auto), flags turned into
# settings (--no-compression -> compress = false), and argument order. The other test files call the library
# functions directly; these check that the flags reach them.
using AtlasCLI: command_main
using AtlasUtilities: stripAtlasExt

const EX = joinpath(@__DIR__, "..", "..", "examples")
const DATA = joinpath(@__DIR__, "..", "..", "Data")

"Run `mapatlas args...` and return (exit code, what it printed)."
function atlascli(args...)
    path, io = mktemp()
    code = redirect_stdout(io) do
        command_main(collect(String, args))
    end
    close(io)
    return code, read(path, String)
end

"A copy of example atlas `name` in a fresh directory (the extract commands write next to their input)."
function excopy(name)
    p = joinpath(mktempdir(), name)
    cp(joinpath(EX, name), p)
    return p
end

mapsof(path) = (io = smartOpen(path, "r"); a = openAtlas(io); ms = Map[]; while !eof(a) push!(ms, nextMap(a)) end; close(io); ms)

@testset "command line" begin

    @testset "--help describes the <atlas> argument" begin
        for cmd in ("info", "list-map-data", "list-nodes")
            code, out = atlascli(cmd, "--help")
            @test code == 0 && occursin("path to the atlas file", out)
        end
    end

    @testset "a damaged map: located in the error; --keep-partial keeps what was written" begin
        dir = mktempdir()
        io = smartOpen(joinpath(EX, "cycleWalk_ct_slice.jsonl.gz"), "r")
        lines = readlines(io)
        close(io)
        lines[4 + 19] = lines[4 + 19][1:100]                     # map 20, on line 23
        cut = joinpath(dir, "cut.jsonl")
        write(cut, join(lines, "\n") * "\n")
        err(args...) = try atlascli(args...); nothing catch e; e end
        for cmd in (["relabel", cut, joinpath(dir, "r.jsonl.gz")], ["extract-map-data", cut],
                    ["extract-map-data-histogram", cut], ["summarize-map-data", cut], ["extract-assignments", cut])
            e = err(cmd..., "--quiet")
            @test e isa AtlasFormatError && startswith(e.msg, "$cut, line 23 (map 20): ")
        end
        @test !isfile(joinpath(dir, "r.jsonl.gz")) && !isfile(joinpath(dir, "r.incomplete.jsonl.gz"))
        @test_logs (:warn, r"kept") match_mode = :any begin
            @test err("relabel", cut, joinpath(dir, "r.jsonl.gz"), "--keep-partial", "--quiet") isa AtlasFormatError
        end
        @test !isfile(joinpath(dir, "r.jsonl.gz")) && isfile(joinpath(dir, "r.incomplete.jsonl.gz"))
        @test_logs (:warn, r"kept") match_mode = :any begin
            err("extract-map-data", cut, "--keep-partial", "--quiet")
            err("extract-assignments", cut, "--keep-partial", "--quiet")
        end
        @test isfile(joinpath(dir, "cut", "get_log_spanning_trees.incomplete.csv.gz"))
        @test isfile(joinpath(dir, "cut-assignments.incomplete.csv.gz"))
        @test isempty(filter(f -> occursin(".tmp", f), vcat(readdir(dir), readdir(joinpath(dir, "cut")))))
    end

    @testset "extract-map-data-histogram: an atlas with no maps leaves no directory" begin
        dir = mktempdir()
        empty = joinpath(dir, "empty.jsonl")
        io = smartOpen(empty, "w")
        newAtlas(io, AtlasHeader("desc", "2026-01-02T03:04:05", Dict{String,Any}, Dict{String,Any}),
                 Dict{String,Any}("districts" => 2))
        close(io)
        code, out = atlascli("extract-map-data-histogram", empty, "--quiet")
        @test code == 0 && occursin("has no maps; nothing written", out)
        @test !isdir(joinpath(dir, "empty"))
    end

    @testset "error messages in the terms of the command" begin
        ct = joinpath(EX, "cycleWalk_ct_slice.jsonl.gz")
        err(args...) = try atlascli(args...); nothing catch e; e.msg end
        @test err("summarize-map-data", ct, "--max-maps", "-1") ==
              "mapatlas summarize-map-data: --max-maps must be ≥ 0, got -1."
        @test err("extract-map-data-histogram", excopy("cycleWalk_ct_slice.jsonl.gz"), "--max-maps", "-1") ==
              "mapatlas extract-map-data-histogram: --max-maps must be ≥ 0, got -1."
        @test err("list-nodes", ct, "--map", "0") == "mapatlas list-nodes: --map must be >= 1 (got 0)."
        msg = err("add", "no_such_writer", ct, joinpath(mktempdir(), "o.jsonl"), "--graph",
                  joinpath(DATA, "CT_pct20.json"), "--pop-col", "POP20", "--node-col", "NAME")
        @test occursin("no_such_writer", msg) && occursin("(see `mapatlas add --list-writers`)", msg)
    end
    ct = joinpath(EX, "cycleWalk_ct_slice.jsonl.gz")

    @testset "info, list-map-data, list-nodes, summarize-map-data" begin
        code, out = atlascli("info", ct)
        @test code == 0 && occursin("Atlas Header", out)

        code, out = atlascli("list-map-data", ct)
        @test code == 0
        @test split(strip(out), '\n') == ["get_isoperimetric_scores", "get_log_spanning_forests",
                                          "get_log_spanning_trees"]

        code, out1 = atlascli("list-nodes", joinpath(EX, "demo_grid_4x4.jsonl.gz"))
        code2, out2 = atlascli("list-nodes", joinpath(EX, "demo_grid_4x4.jsonl.gz"), "--map", "2")
        @test code == code2 == 0
        @test JSON.parse(out1) isa Vector && "n0" in JSON.parse(out1)
        @test JSON.parse(out2) == JSON.parse(out1)     # same node set in every map of this demo

        code, out = atlascli("summarize-map-data", ct, "--max-maps", "5", "--quiet")
        @test code == 0 && occursin("get_log_spanning_trees", out)

        @test atlascli("list-nodes", ct, "--no-such-flag")[1] != 0   # an unknown flag is refused
    end

    @testset "info --extract-script writes into the current directory" begin
        meta = joinpath(EX, "cycleWalk_ct_metadata.jsonl.gz")
        dir = mktempdir()
        cd(dir) do
            @test atlascli("info", meta, "--extract-script")[1] == 0
            written = readdir(dir)
            @test !isempty(written)
            @test any(endswith(".jl"), written)
            @test atlascli("info", meta, "--extract-script", "--force")[1] == 0   # overwrite allowed
            @test sort(readdir(dir)) == sort(written)
        end
    end

    @testset "extract-map-data and extract-assignments honour --no-compression and --max-maps" begin
        a = excopy("cycleWalk_ct_slice.jsonl.gz")
        @test atlascli("extract-map-data", a, "--no-compression", "--max-maps", "3", "--quiet")[1] == 0
        outdir = stripAtlasExt(a)
        csvs = filter(endswith(".csv"), readdir(outdir))
        @test length(csvs) == 3 && isfile(joinpath(outdir, "about.md"))
        @test !any(endswith(".gz"), readdir(outdir))                  # --no-compression reached extractMapData
        rows = readlines(joinpath(outdir, csvs[1]))
        @test length(rows) == 1 + 3                                   # header + --max-maps 3 rows

        @test atlascli("extract-assignments", a, "--no-compression", "--quiet")[1] == 0
        @test isfile(stripAtlasExt(a) * "-assignments.csv")
        @test atlascli("extract-assignments", a, "--quiet")[1] == 0   # default: compressed
        @test isfile(stripAtlasExt(a) * "-assignments.csv.gz")
    end

    @testset "extract-map-data-histogram parses --bins, --bin-range, --moment-powers and --integer" begin
        # The ranges apply to every field; 0-1000 covers all three of this atlas's (a field entirely outside
        # the range made the command fail before StreamHistogram's empty-range fix).
        field = "get_log_spanning_trees"
        a = excopy("cycleWalk_ct_slice.jsonl.gz")
        hist(path) = JSON.parse(read(path, String))
        out = joinpath(stripAtlasExt(a), field * "-histogram.json")

        @test atlascli("extract-map-data-histogram", a, "--bins", "0,250,500,1000", "--moment-powers", "1,2",
                       "--no-compression", "--quiet")[1] == 0
        h = hist(out)
        @test h["moment_powers"] == [1, 2]
        # powers up to 2: variance is computed; skewness and excess kurtosis (orders 3, 4) are null, not an error
        @test all(x["variance"] isa Real && x["skewness"] === nothing && x["excess_kurtosis"] === nothing
                  for x in values(h["histograms"]))
        @test all(length(x["edges"]) == 4 for x in values(h["histograms"]))     # 3 bins -> 4 edges
        @test all(x["edges"] == [0, 250, 500, 1000] for x in values(h["histograms"]))

        @test atlascli("extract-map-data-histogram", a, "--bin-range", "0,1000", "--bin-num", "10",
                       "--no-compression", "--force", "--quiet")[1] == 0
        h = hist(out)
        @test h["moment_powers"] == [1, 2, 4, 8]                                # the default
        @test all(x["skewness"] isa Real && x["excess_kurtosis"] isa Real for x in values(h["histograms"]))
        @test !any(haskey(x, "kurtosis") || haskey(x, "weighted_kurtosis") for x in values(h["histograms"]))
        @test all(length(x["edges"]) == 11 && first(x["edges"]) == 0 && last(x["edges"]) == 1000
                  for x in values(h["histograms"]))                             # --bin-num 10

        @test atlascli("extract-map-data-histogram", a, "--integer", "auto", "--no-compression", "--force",
                       "--quiet")[1] == 0
        @test all(x["integer"] == false for x in values(hist(out)["histograms"])) # log values: not integers
        @test_throws ErrorException atlascli("extract-map-data-histogram", a, "--integer", "maybe", "--quiet")
    end

    @testset "extract-map-data-histogram with a --bin-range no value falls in" begin
        # Every value is below the range: the counts go to `underflow`, the density-based entries are null or zero, and
        # the command succeeds (StreamHistogram used to fail on a histogram with nothing in range).
        a = excopy("cycleWalk_ct_slice.jsonl.gz")
        @test atlascli("extract-map-data-histogram", a, "--bin-range", "1e6,2e6", "--no-compression",
                       "--quiet")[1] == 0
        for field in ("get_log_spanning_trees", "get_isoperimetric_scores")
            base = joinpath(stripAtlasExt(a), field * "-histogram")
            for x in values(JSON.parse(read(base * ".json", String))["histograms"])
                @test x["underflow"] == x["nobs"] > 0 && x["overflow"] == 0
                @test x["underflow_weight"] == x["total_weight"]
                @test all(==(0), x["ash_count"]) && all(==(0), x["ash_weight"])
                @test all(isnothing, values(x["relerr_moments"]))
                @test all(isnothing, values(x["weighted_relerr_moments"]))
                @test x["mean"] isa Real && x["weighted_mean"] isa Real      # the moments use every value
            end
            rows = split(strip(read(base * ".csv", String)), '\n')[2:end]
            @test all(r -> endswith(r, ",0,0.0"), rows)                       # no count, no weight in any bin
        end
    end

    @testset "add: --list-writers, and refusing to overwrite a field without --overwrite" begin
        @test atlascli("add", "--list-writers")[1] == 0
        dir = mktempdir()
        a2, a3 = joinpath(dir, "a2.jsonl.gz"), joinpath(dir, "a3.jsonl.gz")
        flags = ["--graph", joinpath(DATA, "CT_pct20.json"), "--pop-col", "POP20", "--node-col", "NAME",
                 "--vote-cols", "G20PREDEM,G20PREREP", "--quiet"]
        field = "get_partisan_margins_G20PREDEM_G20PREREP"
        @test atlascli("add", "get_partisan_margins", ct, a2, flags...)[1] == 0
        @test all(haskey(m.data, field) for m in mapsof(a2))

        # a2 already has the field: without --overwrite, add stops and names the (first) map and the field, with
        # no error log before the message (it is meant for the user, not a writer failure)
        logs, err = Test.collect_test_logs() do
            try
                atlascli("add", "get_partisan_margins", a2, a3, flags...)
                nothing
            catch e
                e
            end
        end
        @test err isa ErrorException
        @test occursin("already has field \"$field\"", err.msg) && occursin("--overwrite", err.msg)
        @test occursin("map \"$(first(mapsof(a2)).name)\"", err.msg)
        @test !any(l -> l.level >= Base.CoreLogging.Error, logs)

        @test atlascli("add", "get_partisan_margins", a2, a3, flags..., "--overwrite")[1] == 0
        @test [m.data[field] for m in mapsof(a3)] == [m.data[field] for m in mapsof(a2)]
    end

    @testset "relabel: --first-map, and --weight-population end to end" begin
        dir = mktempdir()
        out = joinpath(dir, "grid.jsonl.gz")
        src = joinpath(EX, "demo_grid_4x4.jsonl.gz")
        @test atlascli("relabel", src, out, "--first-map", "--quiet")[1] == 0
        ms = mapsof(out)
        @test length(ms) == length(mapsof(src))
        @test all(m.districting == ms[1].districting for m in ms)   # same partition, labels now canonical

        # Multiscale atlas + its dual graph, weighted by a population attribute.
        msrc = joinpath(EX, "demo_multiscale.jsonl.gz")
        graph = joinpath(EX, "demo_multiscale_graph.json")
        popgraph = joinpath(dir, "pop.json")
        g = JSON.parse(read(graph, String))
        for (i, n) in enumerate(g["nodes"])
            n["pop"] = 10 * i
        end
        write(popgraph, JSON.json(g))
        mout = joinpath(dir, "multi.jsonl.gz")
        @test atlascli("relabel", msrc, mout, graph, "--weight-population", popgraph, "--population-attr", "pop",
                       "--quiet")[1] == 0
        @test length(mapsof(mout)) == length(mapsof(msrc))

        # --weight-population needs --population-attr ...
        @test_throws ErrorException atlascli("relabel", msrc, joinpath(dir, "x.jsonl"), graph,
                                             "--weight-population", popgraph, "--quiet")
        # ... and an atlas whose params name its levels
        nolevels = joinpath(dir, "nolevels.jsonl")
        io = smartOpen(nolevels, "w")
        newAtlas(io, AtlasHeader("t", Dict{String,Any}, Dict{String,Any}), Dict{String,Any}("districts" => 2))
        addMap(io, Map("m1", Districting(("X",) => 1, ("Y",) => 2), 1, Dict{String,Any}()))
        close(io)
        err = try
            atlascli("relabel", nolevels, joinpath(dir, "y.jsonl"), "--weight-population", popgraph,
                     "--population-attr", "pop", "--quiet")
            nothing
        catch e
            e
        end
        @test err isa ErrorException && occursin("levels in graph", err.msg)
    end
end
