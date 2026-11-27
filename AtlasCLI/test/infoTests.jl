# `mapatlas info` and `mapatlas list-map-data`.
using AtlasUtilities: extractScripts, atlasHeaderInfo

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

@testset "mapatlas info, list-map-data" begin

    @testset "mapatlas info: prints header + params, omits script, keys sorted" begin
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
            cli_info(path)
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

    @testset "mapatlas info extract_script: writes script to script_name file" begin
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
                cli_info(path; extract_script = true)
            end
        end

        scriptOut = joinpath(dir, "extracted.jl")
        @test isfile(scriptOut)
        @test read(scriptOut, String) == body
        @test occursin("Wrote script entry to: extracted.jl", out)
    end

    @testset "mapatlas info extract_script: never writes outside the current directory" begin
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
                cli_info(path; extract_script = true)
            end
        end

        @test read(original, String) == "[plans]\nnum_dists = 9   # the live config\n"
        @test !isfile(joinpath(elsewhereDir, "run.jl"))
        @test read(joinpath(dir, "param.toml"), String) == "[plans]\nnum_dists = 3\n"
        @test read(joinpath(dir, "run.jl"), String) == "println(1)\n"
    end

    @testset "mapatlas info extract_script: existing file kept unless force" begin
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
                    cli_info(path; extract_script = true)
                end
            end
        end
        @test read(joinpath(dir, "run.jl"), String) == "# mine, not the atlas's\n"
        @test occursin("already exists", out)
        @test occursin("already exists", err)

        cd(dir) do
            capture_stdout() do
                cli_info(path; extract_script = true, force = true)
            end
        end
        @test read(joinpath(dir, "run.jl"), String) == "println(1)\n"
    end

    @testset "mapatlas info: omits the bulky script_includes, extracts each include" begin
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
                cli_info(path)
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
                cli_info(path; extract_script = true)
            end
        end
        @test read(joinpath(dir, "helpers.jl"), String) == incBody
        # "../src/deeper.jl" lands in the current directory, under its basename.
        @test read(joinpath(dir, "deeper.jl"), String) == "# a deeper include\n"
        @test occursin("script_includes[helpers.jl]", out2)
    end

    @testset "mapatlas info: no script_includes entry is not mentioned" begin
        dir = mktempdir()
        path = joinpath(dir, "a.jsonl")
        writeAtlas(path, Dict{String,Any}("districts" => 2))

        out = capture_stdout() do
            cli_info(path)
        end
        @test !occursin("script includes", out)
        @test !occursin("script_includes", out)
    end

    @testset "mapatlas info extract_script: no script entry warns, writes nothing" begin
        dir = mktempdir()
        path = joinpath(dir, "a.jsonl")
        writeAtlas(path, Dict{String,Any}("districts" => 2))

        local out
        err = capture_stderr() do
            out = capture_stdout() do
                cli_info(path; extract_script = true)
            end
        end

        @test occursin("no \"script\" entry", err)      # warning on stderr
        @test occursin("no \"script\" entry", out)      # and also on stdout
        @test isempty(readdir(dir)) == false            # only the atlas file exists
        @test !any(f -> endswith(f, ".jl"), readdir(dir))
    end

    @testset "mapatlas info: lists first map's data field names" begin
        dir = mktempdir()
        path = joinpath(dir, "a.jsonl")
        writeAtlas(path, Dict{String,Any}("districts" => 5);
                  mapData = Dict{String,Any}("log_spanning_trees" => 1.2, "alpha" => 3))

        out = capture_stdout() do
            cli_info(path)
        end

        @test occursin("Map Data Fields", out)
        @test occursin("log_spanning_trees", out)
        # Field names are listed, sorted.
        @test findfirst("alpha", out).start < findfirst("log_spanning_trees", out).start
    end

    @testset "mapatlas info: notes embedded run script and/or toml config, extracts both" begin
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
            cli_info(path)
        end
        @test occursin("run script", out)
        @test occursin("toml config", out)
        @test !occursin(scriptBody, out)
        @test !occursin(configBody, out)
        @test !isfile(scriptOut)   # info alone does not extract
        @test !isfile(configOut)

        out2 = cd(dir) do
            capture_stdout() do
                cli_info(path; extract_script = true)
            end
        end
        @test isfile(scriptOut)
        @test read(scriptOut, String) == scriptBody
        @test isfile(configOut)
        @test read(configOut, String) == configBody
        @test occursin("Wrote script entry to: extracted.jl", out2)
        @test occursin("Wrote toml_config entry to: extracted.toml", out2)

        # The library: what was written and skipped, silently, into any directory.
        other = mktempdir()
        r = @test_nowarn extractScripts(path, other)
        @test r.written == [joinpath(other, "extracted.jl"), joinpath(other, "extracted.toml")]
        @test isempty(r.skipped)
        @test r.entries == ["script" => joinpath(other, "extracted.jl"), "toml_config" => joinpath(other, "extracted.toml")]
        @test isempty(capture_stdout(() -> extractScripts(path, other)))
        r2 = extractScripts(path, other)
        @test isempty(r2.written) && r2.skipped == r.written            # kept, without force
        @test extractScripts(path, other; force = true).written == r.written
        @test atlasHeaderInfo(path) == out                               # the text `mapatlas info` prints
    end

    @testset "mapatlas info: no toml config entry does not mention or extract one" begin
        dir = mktempdir()
        path = joinpath(dir, "a.jsonl")
        writeAtlas(path, Dict{String,Any}("districts" => 2))

        out = capture_stdout() do
            cli_info(path; extract_script = true)
        end
        @test !occursin("toml config", out)
        @test !occursin("toml_config", out)
        @test !any(f -> endswith(f, ".toml"), readdir(dir))
    end

    @testset "mapatlas info: no maps prints (none) for Map Data Fields" begin
        dir = mktempdir()
        path = joinpath(dir, "a.jsonl")
        writeEmptyAtlas(path, Dict{String,Any}("districts" => 1))

        out = capture_stdout() do
            cli_info(path)
        end

        @test occursin("Map Data Fields", out)
        @test occursin("(none)", out)
    end

    @testset "mapatlas list-map-data: prints sorted field names, one per line" begin
        dir = mktempdir()
        path = joinpath(dir, "a.jsonl")
        writeAtlas(path, Dict{String,Any}();
                  mapData = Dict{String,Any}("log_spanning_trees" => 1.0, "alpha" => 2))

        out = capture_stdout() do
            cli_list_map_data(path)
        end
        lines = filter(!isempty, split(out, '\n'))

        @test lines == ["alpha", "log_spanning_trees"]
    end

    @testset "mapatlas list-map-data: no maps prints a message, no field lines" begin
        dir = mktempdir()
        path = joinpath(dir, "a.jsonl")
        writeEmptyAtlas(path, Dict{String,Any}())

        out = capture_stdout() do
            cli_list_map_data(path)
        end

        @test occursin("no maps", out)
    end

    @testset "mapatlas info: gzip-compressed atlas reads fine" begin
        dir = mktempdir()
        path = joinpath(dir, "a.jsonl.gz")
        writeAtlas(path, Dict{String,Any}("districts" => 4, "state" => "CT"))

        out = capture_stdout() do
            cli_info(path)
        end
        @test occursin("state", out)
        @test occursin("\"CT\"", out)
    end

end
