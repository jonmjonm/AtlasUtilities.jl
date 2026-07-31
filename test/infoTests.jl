# Tests for the `atlas info` subcommand (src/info.jl).

using Test
using AtlasIO
using AtlasUtilities: formatValue, printBlock, run_info, run_list_map_data,
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

    @testset "run_info: prints header + params, omits script, keys sorted" begin
        dir = mktempdir()
        path = joinpath(dir, "a.jsonl")
        writeAtlas(path, Dict{String,Any}(
            "districts"   => 5,
            "energies"    => Any["iso", "sf"],
            "zeta"        => 1,
            "alpha"       => 2,
            "script_name" => "run.jl",
            "script"      => "print(\"hello\")\n",
        ))

        out = capture_stdout() do
            run_info(path)
        end

        @test occursin("Atlas Header", out)
        @test occursin("Atlas Parameters", out)
        @test occursin("districts", out)
        @test occursin("energies", out)
        @test occursin("[\"iso\", \"sf\"]", out)        # scalar array formatting
        @test occursin("script_name", out)              # script_name IS shown
        @test !occursin("hello", out)                   # script BODY is never printed
        @test !occursin("\nscript ", out) && !occursin("  script ", out)  # no "script" key row
        # Params are alphabetized: alpha before zeta.
        @test findfirst("alpha", out).start < findfirst("zeta", out).start
    end

    @testset "run_info extract_script: writes script to script_name file" begin
        dir = mktempdir()
        path = joinpath(dir, "a.jsonl")
        body = "# extracted script\nprintln(42)\n"
        writeAtlas(path, Dict{String,Any}(
            "districts"   => 3,
            "script_name" => "extracted.jl",
            "script"      => body,
        ))

        out = cd(dir) do
            capture_stdout() do
                run_info(path; extract_script = true)
            end
        end

        scriptOut = joinpath(dir, "extracted.jl")
        @test isfile(scriptOut)
        @test read(scriptOut, String) == body
        @test occursin("Wrote script entry to: extracted.jl", out)
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

    @testset "run_info extract_script: never writes outside the current directory" begin
        # CycleWalk records the TOML config under the path the run was invoked with,
        # which is often the live config file itself; extraction must not write there.
        dir = mktempdir()
        elsewhereDir = mktempdir()
        path = joinpath(dir, "a.jsonl")
        original = joinpath(elsewhereDir, "param.toml")
        write(original, "[plans]\nnum_dists = 9   # the live config\n")

        writeAtlas(path, Dict{String,Any}(
            "districts"        => 3,
            "script_name"      => joinpath(elsewhereDir, "run.jl"),
            "script"           => "println(1)\n",
            "toml_config_file" => original,
            "toml_config"      => "[plans]\nnum_dists = 3\n",
        ))

        cd(dir) do
            capture_stdout() do
                run_info(path; extract_script = true)
            end
        end

        @test read(original, String) == "[plans]\nnum_dists = 9   # the live config\n"
        @test !isfile(joinpath(elsewhereDir, "run.jl"))
        @test read(joinpath(dir, "param.toml"), String) == "[plans]\nnum_dists = 3\n"
        @test read(joinpath(dir, "run.jl"), String) == "println(1)\n"
    end

    @testset "run_info extract_script: existing file kept unless force" begin
        dir = mktempdir()
        path = joinpath(dir, "a.jsonl")
        writeAtlas(path, Dict{String,Any}(
            "districts"   => 3,
            "script_name" => "run.jl",
            "script"      => "println(1)\n",
        ))
        write(joinpath(dir, "run.jl"), "# mine, not the atlas's\n")

        local out
        err = cd(dir) do
            capture_stderr() do
                out = capture_stdout() do
                    run_info(path; extract_script = true)
                end
            end
        end
        @test read(joinpath(dir, "run.jl"), String) == "# mine, not the atlas's\n"
        @test occursin("already exists", out)
        @test occursin("already exists", err)

        cd(dir) do
            capture_stdout() do
                run_info(path; extract_script = true, force = true)
            end
        end
        @test read(joinpath(dir, "run.jl"), String) == "println(1)\n"
    end

    @testset "run_info: omits the bulky script_includes, extracts each include" begin
        # CycleWalk >= 0.2.2 embeds the source of every file the run script includes;
        # printing them would bury the header under tens of kilobytes of Julia.
        dir = mktempdir()
        path = joinpath(dir, "a.jsonl")
        incBody = "# an included file\nconst SECRET_MARKER = 1\n"
        writeAtlas(path, Dict{String,Any}(
            "districts"       => 3,
            "script_name"     => "run.jl",
            "script"          => "include(\"helpers.jl\")\n",
            "script_includes" => Dict{String,Any}(
                "helpers.jl"           => incBody,
                "../src/deeper.jl"     => "# a deeper include\n",
            ),
            "script_includes_skipped" => Any["huge.jl"],   # short list: still printed
        ))

        out = cd(dir) do
            capture_stdout() do
                run_info(path)
            end
        end
        @test occursin("script includes", out)            # presence noted
        @test occursin("2 file(s) embedded", out)
        @test !occursin("SECRET_MARKER", out)             # bodies never printed
        @test !occursin("a deeper include", out)
        @test occursin("script_includes_skipped", out)    # its short companions stay
        @test occursin("huge.jl", out)
        @test !isfile(joinpath(dir, "helpers.jl"))        # info alone does not extract

        out2 = cd(dir) do
            capture_stdout() do
                run_info(path; extract_script = true)
            end
        end
        @test read(joinpath(dir, "helpers.jl"), String) == incBody
        # "../src/deeper.jl" lands in the current directory, under its basename.
        @test read(joinpath(dir, "deeper.jl"), String) == "# a deeper include\n"
        @test occursin("script_includes[helpers.jl]", out2)
    end

    @testset "run_info: no script_includes entry is not mentioned" begin
        dir = mktempdir()
        path = joinpath(dir, "a.jsonl")
        writeAtlas(path, Dict{String,Any}("districts" => 2))

        out = capture_stdout() do
            run_info(path)
        end
        @test !occursin("script includes", out)
        @test !occursin("script_includes", out)
    end

    @testset "run_info extract_script: no script entry warns, writes nothing" begin
        dir = mktempdir()
        path = joinpath(dir, "a.jsonl")
        writeAtlas(path, Dict{String,Any}("districts" => 2))

        local out
        err = capture_stderr() do
            out = capture_stdout() do
                run_info(path; extract_script = true)
            end
        end

        @test occursin("no \"script\" entry", err)      # warning on stderr
        @test occursin("no \"script\" entry", out)      # and also on stdout
        @test isempty(readdir(dir)) == false            # only the atlas file exists
        @test !any(f -> endswith(f, ".jl"), readdir(dir))
    end

    @testset "run_info: lists first map's data field names" begin
        dir = mktempdir()
        path = joinpath(dir, "a.jsonl")
        writeAtlas(path, Dict{String,Any}("districts" => 5);
                  mapData = Dict{String,Any}("log_spanning_trees" => 1.2, "alpha" => 3))

        out = capture_stdout() do
            run_info(path)
        end

        @test occursin("Map Data Fields", out)
        @test occursin("log_spanning_trees", out)
        # Field names are listed, sorted.
        @test findfirst("alpha", out).start < findfirst("log_spanning_trees", out).start
    end

    @testset "run_info: notes embedded run script and/or toml config, extracts both" begin
        dir = mktempdir()
        path = joinpath(dir, "a.jsonl")
        scriptOut = joinpath(dir, "extracted.jl")
        configOut = joinpath(dir, "extracted.toml")
        scriptBody = "println(1)\n"
        configBody = "[plans]\nnum_dists = 3\n"
        writeAtlas(path, Dict{String,Any}(
            "districts"         => 3,
            "script_name"       => "extracted.jl",
            "script"            => scriptBody,
            "toml_config_file"  => "extracted.toml",
            "toml_config"       => configBody,
        ))

        out = capture_stdout() do
            run_info(path)
        end
        @test occursin("run script", out)
        @test occursin("toml config", out)
        @test !occursin(scriptBody, out)
        @test !occursin(configBody, out)
        @test !isfile(scriptOut)   # info alone does not extract
        @test !isfile(configOut)

        out2 = cd(dir) do
            capture_stdout() do
                run_info(path; extract_script = true)
            end
        end
        @test isfile(scriptOut)
        @test read(scriptOut, String) == scriptBody
        @test isfile(configOut)
        @test read(configOut, String) == configBody
        @test occursin("Wrote script entry to: extracted.jl", out2)
        @test occursin("Wrote toml_config entry to: extracted.toml", out2)
    end

    @testset "run_info: no toml config entry does not mention or extract one" begin
        dir = mktempdir()
        path = joinpath(dir, "a.jsonl")
        writeAtlas(path, Dict{String,Any}("districts" => 2))

        out = capture_stdout() do
            run_info(path; extract_script = true)
        end
        @test !occursin("toml config", out)
        @test !occursin("toml_config", out)
        @test !any(f -> endswith(f, ".toml"), readdir(dir))
    end

    @testset "run_info: no maps prints (none) for Map Data Fields" begin
        dir = mktempdir()
        path = joinpath(dir, "a.jsonl")
        writeEmptyAtlas(path, Dict{String,Any}("districts" => 1))

        out = capture_stdout() do
            run_info(path)
        end

        @test occursin("Map Data Fields", out)
        @test occursin("(none)", out)
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

    @testset "run_list_map_data: prints sorted field names, one per line" begin
        dir = mktempdir()
        path = joinpath(dir, "a.jsonl")
        writeAtlas(path, Dict{String,Any}();
                  mapData = Dict{String,Any}("log_spanning_trees" => 1.0, "alpha" => 2))

        out = capture_stdout() do
            run_list_map_data(path)
        end
        lines = filter(!isempty, split(out, '\n'))

        @test lines == ["alpha", "log_spanning_trees"]
    end

    @testset "run_list_map_data: no maps prints a message, no field lines" begin
        dir = mktempdir()
        path = joinpath(dir, "a.jsonl")
        writeEmptyAtlas(path, Dict{String,Any}())

        out = capture_stdout() do
            run_list_map_data(path)
        end

        @test occursin("no maps", out)
    end

    @testset "run_info: gzip-compressed atlas reads fine" begin
        dir = mktempdir()
        path = joinpath(dir, "a.jsonl.gz")
        writeAtlas(path, Dict{String,Any}("districts" => 4, "state" => "CT"))

        out = capture_stdout() do
            run_info(path)
        end
        @test occursin("state", out)
        @test occursin("\"CT\"", out)
    end

end
