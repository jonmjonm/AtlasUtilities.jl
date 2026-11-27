# The zsh completion script Comonicon generates from the help text must parse: an apostrophe in a command's
# docstring (a contraction, a possessive) opens a quote there and breaks it ("parse error near ...").
import Comonicon

@testset "zsh completion script parses" begin
    zsh = Sys.which("zsh")
    if zsh === nothing
        @info "no zsh on this machine; skipping the completion check"
    else
        options = Comonicon.Configs.read_options(AtlasCLI)
        script = Comonicon.Builder.completion_script(AtlasCLI, options, "zsh")
        path = joinpath(mktempdir(), "_mapatlas")
        write(path, replace(script, r"\e\[[0-9;]*m" => ""))      # as deps/build.jl does
        @test success(`$zsh -n $path`)
    end
end
