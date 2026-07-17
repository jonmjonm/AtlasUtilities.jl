# Tests for the `atlas info` subcommand (src/info.jl).

using Test
using AtlasIO
using AtlasUtilities: formatValue, printBlock, run_info

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

"""Write a minimal atlas at `path` whose header (line 3) is `atlasParam`."""
function writeAtlas(path, atlasParam)
    io = smartOpen(path, "w")
    newAtlas(io, AtlasHeader("desc", "2026-01-02T03:04:05", Dict{String,Any}, Dict{String,Any}),
             atlasParam)
    # One trivial map so the file is a well-formed atlas.
    addMap(io, Map("m1", Districting(("a",) => 1, ("b",) => 2), 1, Dict{String,Any}()))
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
        scriptOut = joinpath(dir, "extracted.jl")
        body = "# extracted script\nprintln(42)\n"
        writeAtlas(path, Dict{String,Any}(
            "districts"   => 3,
            "script_name" => scriptOut,     # absolute path so it lands in the tempdir
            "script"      => body,
        ))

        out = capture_stdout() do
            run_info(path; extract_script = true)
        end

        @test isfile(scriptOut)
        @test read(scriptOut, String) == body
        @test occursin("Wrote script entry to: $scriptOut", out)
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

        @test occursin("no \"script\" entry", err)
        @test isempty(readdir(dir)) == false            # only the atlas file exists
        @test !any(f -> endswith(f, ".jl"), readdir(dir))
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
