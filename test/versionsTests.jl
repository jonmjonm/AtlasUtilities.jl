# Every subcommand gives the same results on a format v1 atlas and on its v2 conversion, and atlases with Float64
# weights keep them. Runs the subcommands through `command_main`, like test/cliTests.jl.
import JSON
using AtlasUtilities: command_main, stripAtlasExt, run_convert, atlasInfo

const VEX = joinpath(@__DIR__, "..", "examples")
const VDATA = joinpath(@__DIR__, "..", "Data")

"Run `atlas args...`; return what it printed (it must succeed)."
function vcli(args...)
    path, io = mktemp()
    code = redirect_stdout(io) do
        command_main(collect(String, args))
    end
    close(io)
    code == 0 || error("atlas $(join(args, ' ')) returned $code")
    return read(path, String)
end

vmaps(path) = (io = smartOpen(path, "r"); a = openAtlas(io); ms = Map[]; while !eof(a) push!(ms, nextMap(a)) end;
               close(io); (a, ms))
sameMaps(x, y) = length(x) == length(y) &&
    all(a.name == b.name && a.districting == b.districting && a.weight == b.weight && a.data == b.data
        for (a, b) in zip(x, y))

"The lines of `text` without the ones that legitimately differ between the two runs."
dropVarying(text) = filter(l -> !occursin(r"format version|Extraction date|Source atlas", l), split(text, '\n'))

"Every file under `dir`, relative path => contents."
function dirContents(dir)
    out = Dict{String,String}()
    for (root, _, files) in walkdir(dir), f in files
        out[relpath(joinpath(root, f), dir)] = read(joinpath(root, f), String)
    end
    return out
end

@testset "format v1 and v2 atlases give the same results" begin
    d1, d2 = mktempdir(), mktempdir()
    ct1, ct2 = joinpath(d1, "ct.jsonl.gz"), joinpath(d2, "ct.jsonl.gz")
    ms1, ms2 = joinpath(d1, "ms.jsonl.gz"), joinpath(d2, "ms.jsonl.gz")
    cp(joinpath(VEX, "cycleWalk_ct_slice.jsonl.gz"), ct1)
    cp(joinpath(VEX, "demo_multiscale.jsonl.gz"), ms1)
    run_convert(ct1, ct2; to = 2, quiet = true)
    run_convert(ms1, ms2; to = 2, quiet = true)
    @test vmaps(ct1)[1].formatVersion == "1" && vmaps(ct2)[1].formatVersion == "2"

    @testset "info shows the format version" begin
        @test occursin(r"format version\s*:\s*\"1\"", vcli("info", ct1))
        @test occursin(r"format version\s*:\s*\"2\"", vcli("info", ct2))
        @test atlasInfo(ct1)["header"]["format version"] == "1"
        @test atlasInfo(ct2)["header"]["format version"] == "2"
    end

    @testset "printing subcommands: same output" begin
        @test dropVarying(vcli("info", ct1)) == dropVarying(vcli("info", ct2))
        for args in (("list-map-data",), ("list-nodes", "--map", "3"), ("summarize-map-data", "--quiet"))
            @test vcli(args[1], ct1, args[2:end]...) == vcli(args[1], ct2, args[2:end]...)
        end
        @test vcli("list-nodes", ms1, "--map", "2") == vcli("list-nodes", ms2, "--map", "2")
    end

    @testset "extracting subcommands: same files" begin
        for (a, b) in ((ct1, ct2),)
            vcli("extract-map-data", a, "--no-compression", "--quiet")
            vcli("extract-map-data", b, "--no-compression", "--quiet")
            vcli("extract-map-data-histogram", a, "--no-compression", "--quiet")
            vcli("extract-map-data-histogram", b, "--no-compression", "--quiet")
            vcli("extract-assignments", a, "--no-compression", "--quiet")
            vcli("extract-assignments", b, "--no-compression", "--quiet")
        end
        f1, f2 = dirContents(stripAtlasExt(ct1)), dirContents(stripAtlasExt(ct2))
        @test sort(collect(keys(f1))) == sort(collect(keys(f2)))
        @test length(f1) == 1 + 3 + 3 * 2       # about.md, 3 field CSVs, 3 x (histogram CSV + JSON)
        for k in keys(f1)
            if k == "about.md"                  # differs only in the format version and the extraction date
                @test dropVarying(f1[k]) == dropVarying(f2[k])
            else
                @test f1[k] == f2[k]
            end
        end
        @test read(stripAtlasExt(ct1) * "-assignments.csv", String) ==
              read(stripAtlasExt(ct2) * "-assignments.csv", String)
    end

    @testset "writing subcommands keep the input's version and give the same maps" begin
        g = joinpath(VDATA, "CT_pct20.json")
        addFlags = ["--graph", g, "--pop-col", "POP20", "--node-col", "NAME", "--vote-cols", "G20PREDEM,G20PREREP",
                    "--quiet"]
        runs = [
            (ct1, ct2, "ct_rel.jsonl.gz", ["relabel"], ["--quiet"]),
            (ms1, ms2, "ms_rel.jsonl.gz", ["relabel"], [joinpath(VEX, "demo_multiscale_graph.json"), "--quiet"]),
            (ct1, ct2, "ct_add.jsonl.gz", ["add", "get_partisan_margins"], addFlags),
        ]
        for (a, b, outName, cmd, flags) in runs
            o1, o2 = joinpath(d1, outName), joinpath(d2, outName)
            vcli(cmd..., a, o1, flags...)
            vcli(cmd..., b, o2, flags...)
            (h1, m1), (h2, m2) = vmaps(o1), vmaps(o2)
            @test h1.formatVersion == "1" && h2.formatVersion == "2"
            @test sameMaps(m1, m2)
        end
    end

    @testset "render: same image" begin
        p1, p2 = joinpath(d1, "ct.png"), joinpath(d2, "ct.png")
        for (a, p) in ((ct1, p1), (ct2, p2))
            vcli("render", a, joinpath(VDATA, "shapefile_CT.zip"), "--key", "NAME", "--map", "2", "--out", p,
                 "--quiet")
        end
        @test read(p1) == read(p2)
    end

    @testset "extract-assignments on a multiscale atlas: a plain error, not a task failure" begin
        for m in (ms1, ms2)
            err = try
                vcli("extract-assignments", m, "--quiet")
                nothing
            catch e
                e
            end
            @test err isa ErrorException
            @test occursin("multiscale", err.msg)
        end
    end
end

@testset "Float64 weights survive relabel, add and convert" begin
    dir = mktempdir()
    src = joinpath(dir, "fw.jsonl.gz")
    let io = smartOpen(joinpath(VEX, "cycleWalk_ct_slice.jsonl.gz"), "r"), a = openAtlas(io)
        out = smartOpen(src, "w")
        newAtlas(out, AtlasHeader("float weights", Dict{String,Any}, Dict{String,Any}; weightType = Float64),
                 a.atlasParam)
        k = 0
        while !eof(a)
            m = nextMap(a)
            k += 1
            addMap(out, Map(m.name, m.districting, 0.25 * k, m.data))
        end
        close(out); close(io)
    end
    h0, m0 = vmaps(src)
    @test h0.weightType == Float64 && m0[3].weight === 0.75

    outs = Dict(
        "relabel" => (joinpath(dir, "rel.jsonl.gz"), ["relabel", src, joinpath(dir, "rel.jsonl.gz"), "--quiet"]),
        "add" => (joinpath(dir, "add.jsonl.gz"),
                  ["add", "get_partisan_margins", src, joinpath(dir, "add.jsonl.gz"), "--graph",
                   joinpath(VDATA, "CT_pct20.json"), "--pop-col", "POP20", "--node-col", "NAME",
                   "--vote-cols", "G20PREDEM,G20PREREP", "--quiet"]),
        "convert" => (joinpath(dir, "v2.jsonl.gz"), ["convert", src, joinpath(dir, "v2.jsonl.gz"), "--to", "2",
                                                     "--quiet"]),
    )
    for (name, (out, args)) in outs
        vcli(args...)
        h, ms = vmaps(out)
        @test h.weightType == Float64
        @test [m.weight for m in ms] == [m.weight for m in m0]
    end
    # The read-only subcommands run on it too (they do not use the weights yet).
    @test occursin(r"weight type\s*:\s*\"Float64\"", vcli("info", src))
    @test !isempty(vcli("summarize-map-data", src, "--quiet"))
    vcli("extract-map-data", src, "--no-compression", "--quiet")
    @test length(filter(endswith(".csv"), readdir(stripAtlasExt(src)))) == 3
end
