# Exercised while building the Comonicon system image so the compiled `atlas`
# command has both subcommands' code paths baked in (fast startup). Builds a
# tiny throwaway atlas and runs `info` and `relabel` over it.
using AtlasIO
using AtlasUtilities

mktempdir() do dir
    a1 = joinpath(dir, "a1.jsonl")
    a2 = joinpath(dir, "a2.jsonl")

    io = smartOpen(a1, "w")
    newAtlas(io, AtlasHeader("precompile", Dict{String,Any}, Dict{String,Any}),
             Dict{String,Any}(
                 "districts"   => 2,
                 "energies"    => Any["e1", "e2"],
                 "script_name" => joinpath(dir, "script.jl"),
                 "script"      => "print(1)\n",
             ))
    for k in 1:3
        addMap(io, Map("m$k",
                       Districting(("a",) => 1, ("b",) => 2, ("c",) => 2, ("d",) => 1),
                       1, Dict{String,Any}()))
    end
    close(io)

    # Keep the build log clean; we only care about triggering compilation.
    redirect_stdout(devnull) do
        redirect_stderr(devnull) do
            AtlasUtilities.run_info(a1)
            AtlasUtilities.run_info(a1; extract_script = true)
            AtlasUtilities.run_relabel(a1, a2; quiet = true)
        end
    end
end
