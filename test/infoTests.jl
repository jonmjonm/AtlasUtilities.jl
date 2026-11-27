# Tests for reading an atlas header (src/info.jl).

using Test
using AtlasIO
using AtlasUtilities: formatValue, printBlock, extractScripts, atlasHeaderInfo, listMapData,
                      firstMapFieldNames, atlasInfo, extractName

"""Run `f()` capturing everything it writes to stdout, returned as a String."""
function capture_stdout(f)
    mktemp() do path, io
        redirect_stdout(f, io)
        flush(io)
        return read(path, String)
    end
end

"""Run `f()` capturing everything it writes to stderr, returned as a String."""
function capture_stderr(f)
    mktemp() do path, io
        redirect_stderr(f, io)
        flush(io)
        return read(path, String)
    end
end

"""Write a minimal atlas at `path` whose header (line 3) is `atlasParam`; the one
trivial map's data is `mapData` (empty by default)."""
function writeAtlas(path, atlasParam; mapData = Dict{String,Any}())
    io = smartOpen(path, "w")
    newAtlas(io, AtlasHeader("desc", "2026-01-02T03:04:05", Dict{String,Any}, Dict{String,Any}),
             atlasParam)
    # One trivial map so the file is a well-formed atlas.
    addMap(io, Map("m1", Districting(("a",) => 1, ("b",) => 2), 1, mapData))
    close(io)
end

"""Write a minimal atlas at `path` with no maps at all (header only)."""
function writeEmptyAtlas(path, atlasParam)
    io = smartOpen(path, "w")
    newAtlas(io, AtlasHeader("desc", "2026-01-02T03:04:05", Dict{String,Any}, Dict{String,Any}),
             atlasParam)
    close(io)
end

@testset "info" begin

    @testset "formatValue: scalars render via repr" begin
        @test formatValue(5) == "5"
        @test formatValue(0.3) == "0.3"
        @test formatValue("hi") == "\"hi\""
    end

    @testset "formatValue: scalar array on one line, no Any[] prefix" begin
        @test formatValue([1, 2, 3]) == "[1, 2, 3]"
        @test formatValue(Any["x", "y"]) == "[\"x\", \"y\"]"
        @test formatValue(Any[]) == "[]"
    end

    @testset "formatValue: empty dict is inline {}" begin
        @test formatValue(Dict{String,Any}()) == "{}"
    end

    @testset "formatValue: nested dict expands, sorted, indented" begin
        s = formatValue(Dict{String,Any}("b" => 2, "a" => 1))
        # Keys appear alphabetically: "a" before "b".
        @test occursin("a: 1", s)
        @test occursin("b: 2", s)
        @test findfirst("a: 1", s).start < findfirst("b: 2", s).start
        @test startswith(s, "\n")            # nested block starts on its own line
    end

    @testset "formatValue: array of dicts uses [i] markers" begin
        s = formatValue(Any[Dict{String,Any}("w" => 1), Dict{String,Any}("w" => 2)])
        @test occursin("[1]", s)
        @test occursin("[2]", s)
    end

    @testset "printBlock: sorts keys, aligns, underlines title" begin
        out = capture_stdout() do
            printBlock("Title", Pair["bbb" => 1, "a" => 2])
        end
        lines = split(out, '\n')
        @test lines[1] == "Title"
        @test lines[2] == "====="                       # underline matches title length
        @test occursin("a", lines[3]) && occursin("2", lines[3])   # sorted: "a" first
        @test occursin("bbb", lines[4])
        # Short key "a" is right-padded to the width of "bbb" before " : ".
        @test occursin("a   : 2", lines[3])
    end

    @testset "printBlock: empty prints (none)" begin
        out = capture_stdout() do
            printBlock("Empty", Pair[])
        end
        @test occursin("(none)", out)
    end

    @testset "extractName: keeps extraction inside the current directory" begin
        # A recorded path -- absolute, or climbing out with ".." -- is reduced to its
        # basename, so extraction can never write back over the original file.
        @test extractName("/abs/where/param.toml", "fallback.toml") == "param.toml"
        @test extractName("../src/parameterUtils.jl", "fallback.jl") ==
              "parameterUtils.jl"
        @test extractName("toml/param_ct.toml", "fallback.toml") == "param_ct.toml"
        @test extractName("run.jl", "fallback.jl") == "run.jl"
        # No usable basename falls back.
        @test extractName("", "fallback.jl") == "fallback.jl"
        @test extractName("/", "fallback.jl") == "fallback.jl"
        @test extractName("..", "fallback.jl") == "fallback.jl"
    end

    @testset "firstMapFieldNames: sorted names, nothing when no maps" begin
        dir = mktempdir()

        path = joinpath(dir, "a.jsonl")
        writeAtlas(path, Dict{String,Any}();
                  mapData = Dict{String,Any}("zeta" => 1, "alpha" => 2))
        io = smartOpen(path, "r"); atlas = openAtlas(io)
        @test firstMapFieldNames(atlas) == ["alpha", "zeta"]
        close(atlas)

        emptyPath = joinpath(dir, "empty.jsonl")
        writeEmptyAtlas(emptyPath, Dict{String,Any}())
        io2 = smartOpen(emptyPath, "r"); atlas2 = openAtlas(io2)
        @test firstMapFieldNames(atlas2) === nothing
        close(atlas2)
    end

    @testset "atlasInfo: header, parameters (incl. script), and map_data" begin
        dir = mktempdir()
        path = joinpath(dir, "a.jsonl")
        writeAtlas(path, Dict{String,Any}(
            "districts"   => 5,
            "script_name" => "run.jl",
            "script"      => "print(\"hello\")\n",
        ); mapData = Dict{String,Any}("log_spanning_trees" => 1.2, "alpha" => 3))

        info = atlasInfo(path)

        @test info["header"]["description"] == "desc"
        @test info["header"]["date"] == "2026-01-02T03:04:05"
        @test haskey(info["header"], "map param type")
        @test haskey(info["header"], "weight type")

        @test info["parameters"]["districts"] == 5
        @test info["parameters"]["script"] == "print(\"hello\")\n"  # script IS included

        @test info["map_data"] == ["alpha", "log_spanning_trees"]  # sorted
    end

    @testset "atlasInfo: no maps yields empty map_data" begin
        dir = mktempdir()
        path = joinpath(dir, "empty.jsonl")
        writeEmptyAtlas(path, Dict{String,Any}("districts" => 1))

        info = atlasInfo(path)

        @test info["map_data"] == String[]
    end

    @testset "atlasInfo: accepts an already-open atlas, same result as by path" begin
        dir = mktempdir()
        path = joinpath(dir, "a.jsonl")
        writeAtlas(path, Dict{String,Any}("districts" => 7);
                  mapData = Dict{String,Any}("zeta" => 1))

        io = smartOpen(path, "r")
        atlas = openAtlas(io)
        info = atlasInfo(atlas)
        close(atlas)

        @test info["header"]["description"] == "desc"
        @test info["parameters"]["districts"] == 7
        @test info["map_data"] == ["zeta"]
    end

    @testset "extractScripts: writes script, config and includes into dir, never to their recorded paths" begin
        dir, out, elsewhere = mktempdir(), mktempdir(), mktempdir()
        path = joinpath(dir, "a.jsonl")
        original = joinpath(elsewhere, "param.toml")
        write(original, "live")
        writeAtlas(path, Dict{String,Any}(
            "districts" => 3, "script_name" => joinpath(elsewhere, "run.jl"), "script" => "println(1)\n",
            "toml_config_file" => original, "toml_config" => "[plans]\n",
            "script_includes" => Dict{String,Any}("a/util.jl" => "# a\n", "b/util.jl" => "# b\n")))
        r = extractScripts(path, out)
        @test read(original, String) == "live" && !isfile(joinpath(elsewhere, "run.jl"))
        @test isempty(r.skipped) && length(r.written) == 4 == length(unique(r.written))
        @test all(p -> dirname(p) == out, r.written)       # two includes named util.jl get distinct files
        @test sort(read.(filter(p -> occursin("util", p), r.written), String)) == ["# a\n", "# b\n"]
        write(joinpath(out, "run.jl"), "# mine\n")
        r2 = extractScripts(path, out)
        @test isempty(r2.written) && joinpath(out, "run.jl") in r2.skipped
        @test read(joinpath(out, "run.jl"), String) == "# mine\n"
        @test extractScripts(path, out; force = true).written == r.written
        @test read(joinpath(out, "run.jl"), String) == "println(1)\n"
    end

    @testset "extractScripts: an include named like the script gets a file of its own" begin
        dir, out = mktempdir(), mktempdir()
        path = joinpath(dir, "a.jsonl")
        writeAtlas(path, Dict{String,Any}(
            "districts" => 3, "script_name" => "run.jl", "script" => "# script\n",
            "toml_config_file" => "run.jl", "toml_config" => "[plans]\n",          # also named like the script
            "script_includes" => Dict{String,Any}("lib/run.jl" => "# lib\n", "run.jl" => "# top\n")))
        r = extractScripts(path, out)
        @test isempty(r.skipped) && length(r.written) == 4 == length(unique(r.written))
        @test length(unique(last.(r.entries))) == 4                               # one path per entry
        byEntry = Dict(r.entries)
        @test read(byEntry["script"], String) == "# script\n"                     # never overwritten
        @test read(byEntry["toml_config"], String) == "[plans]\n"
        @test basename(byEntry["toml_config"]) == "run_2.jl"
        @test read(byEntry["script_includes[lib/run.jl]"], String) == "# lib\n"
        @test basename(byEntry["script_includes[lib/run.jl]"]) == "lib_run.jl"
        @test read(byEntry["script_includes[run.jl]"], String) == "# top\n"
        # The names depend on the header only: a rerun skips the very same files.
        r2 = extractScripts(path, out)
        @test isempty(r2.written) && sort(r2.skipped) == sort(r.written) && r2.entries == r.entries
    end

end
