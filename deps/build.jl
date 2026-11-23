# Installs the `atlas` command: run `julia --project deps/build.jl` from a clone (or `Pkg.build("AtlasUtilities")`).
#
#   1. The command's own environment, ~/.julia/scratchspaces/<AtlasUtilities uuid>/env, with this checkout of
#      AtlasUtilities developed into it and everything precompiled. `atlas install-render` later adds the plotting
#      packages to this environment, never to the checkout's Project.toml.
#   2. The launcher ~/.julia/bin/atlas, which runs Julia in that environment (and only it, plus the standard
#      library). It prefers the Julia that ran this build, and falls back to `julia` on the PATH if that one has been
#      removed (e.g. by juliaup), so a Julia update does not break the command.
#   3. Shell completions in ~/.julia/completions (Comonicon).
#
# No system image is built: precompiled package images make startup fast enough, install takes minutes less, and a
# plain environment is what lets `atlas install-render` add packages.
using AtlasUtilities
using Pkg
using Comonicon: Comonicon

const UUID_DIR = joinpath(first(DEPOT_PATH), "scratchspaces", "020ba7bf-05d8-4817-8da0-aeeb372d76a1")
const ENV_DIR = joinpath(UUID_DIR, "env")
const PKG_DIR = pkgdir(AtlasUtilities)
const BIN = joinpath(first(DEPOT_PATH), "bin", "atlas")

# 1. The environment, built in a separate Julia process so it never touches the project running this script.
# Plotting packages a previous `atlas install-render` added are kept.
render = String[]
if isfile(joinpath(ENV_DIR, "Project.toml"))
    deps = get(Pkg.TOML.parsefile(joinpath(ENV_DIR, "Project.toml")), "deps", Dict())
    render = [p.name for p in AtlasUtilities.RENDER_PACKAGES if haskey(deps, p.name)]
end
rm(ENV_DIR; force = true, recursive = true)
mkpath(ENV_DIR)
setup = """
    import Pkg
    Pkg.develop(path = $(repr(PKG_DIR)))
    isempty($(repr(render))) || Pkg.add($(repr(render)))
    Pkg.precompile()
    """
run(`$(Base.julia_cmd()) --startup-file=no --project=$ENV_DIR -e $setup`)

# The system image older versions built (about 1.2 GB) is no longer used.
rm(joinpath(UUID_DIR, "sysimg"); force = true, recursive = true)

# 2. The launcher.
julia = joinpath(Sys.BINDIR, Base.julia_exename())
mkpath(dirname(BIN))
write(BIN, """
    #!/usr/bin/env bash
    #=
    # The `atlas` command (AtlasUtilities), written by $(joinpath(PKG_DIR, "deps", "build.jl")).
    JULIA=$(repr(julia))
    [ -x "\$JULIA" ] || JULIA=\$(command -v julia) || { echo "atlas: cannot find julia" >&2; exit 127; }
    JULIA_PROJECT=$(repr(ENV_DIR)) JULIA_LOAD_PATH="@:@stdlib" \\
    exec "\$JULIA" --startup-file=no --color=yes -- "\${BASH_SOURCE[0]}" "\$@"
    =#
    using AtlasUtilities
    exit(AtlasUtilities.command_main())
    """)
chmod(BIN, 0o755)
println("Installed $BIN (environment $ENV_DIR)")

# 3. Shell completions.
shell = basename(get(ENV, "SHELL", ""))
if shell in ("zsh", "bash")
    options = Comonicon.Configs.read_options(AtlasUtilities)
    Comonicon.Builder.install_completion(AtlasUtilities, options, shell)
end

# Comonicon's docstring-to-completion-text conversion hardcodes `color = true`
# (see Comonicon.jl `md_to_string`), so the generated zsh completion script embeds
# raw ANSI escape codes in its description strings. zsh's `_arguments` chokes on
# the literal escape bytes ("invalid argument" at runtime), so strip them here.
let path = joinpath(first(DEPOT_PATH), "completions", "_atlas")
    if isfile(path)
        text = read(path, String)
        stripped = replace(text, r"\e\[[0-9;]*m" => "")
        stripped == text || write(path, stripped)
    end
end
