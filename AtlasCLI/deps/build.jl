# Installs the `mapatlas` command: run `julia --project=AtlasCLI AtlasCLI/deps/build.jl` from a clone (or
# `Pkg.build("AtlasCLI")`).
#
#   1. The command's own environment, ~/.julia/scratchspaces/<AtlasCLI uuid>/env, with this checkout of
#      AtlasUtilities and AtlasCLI developed into it (CycleWalk and the rest come as AtlasCLI's dependencies) and
#      everything precompiled. It is rebuilt in a new directory and swapped in only on success, and resolves afresh,
#      ignoring the checkout's own Manifest.toml files.
#   2. The launcher ~/.julia/bin/mapatlas, which runs Julia in that environment (and only it, plus the standard
#      library). It prefers the Julia that ran this build, and falls back to `julia` on the PATH if that one has been
#      removed (e.g. by juliaup), so a Julia update does not break the command.
#   3. Shell completions in ~/.julia/completions (Comonicon).
#
# No system image is built: precompiled package images make startup fast enough, and install takes minutes less.
using AtlasCLI
using AtlasUtilities
using Pkg
using Comonicon: Comonicon

const UUID_DIR = joinpath(first(DEPOT_PATH), "scratchspaces", "633115ed-ca31-433d-9d30-b211c9b74b65")
const ENV_DIR = joinpath(UUID_DIR, "env")
const LIB_DIR = pkgdir(AtlasUtilities)
const CLI_DIR = pkgdir(AtlasCLI)
const BIN = joinpath(first(DEPOT_PATH), "bin", "mapatlas")

# 1. The environment, built in a separate Julia process so it never touches the project running this script.
# A checkout's own manifest (its development environment; not in git) is read when the checkout is developed
# into another environment, so it would pin the packages it gets by URL from [sources] (StreamHistogram) to the
# commit it last resolved, however old: a stale one makes the build fail, or install an old version. Set it aside
# while the environment resolves, so those are fetched afresh, and put it back afterwards.
const ASIDE = ".aside-during-mapatlas-build"
aside(path) = path * ASIDE
# A build killed while they were set aside (a second Ctrl-C, kill -9, out of memory, a CI timeout: the `finally`
# below never ran) leaves them under that name, where nothing would look for them again. Put such a leftover back
# first; if a manifest has been made since, that one is current and the leftover is dropped.
for d in (LIB_DIR, CLI_DIR), f in readdir(d)
    m = match(Regex("^((Julia)?Manifest(-v[0-9.]+)?\\.toml)" * replace(ASIDE, "." => "\\.") * "\$"), f)
    m === nothing && continue
    original = joinpath(d, m.captures[1])
    if isfile(original)
        rm(joinpath(d, f))
        println("Removed $(joinpath(d, f)), left by an interrupted build ($(m.captures[1]) is newer).")
    else
        mv(joinpath(d, f), original)
        println("Restored $original, left set aside by an interrupted build.")
    end
end
manifests = [joinpath(d, f) for d in (LIB_DIR, CLI_DIR)
             for f in readdir(d) if occursin(r"^(Julia)?Manifest(-v[0-9.]+)?\.toml$", f)]
setup = """
    import Pkg
    Pkg.develop([Pkg.PackageSpec(path = $(repr(LIB_DIR))), Pkg.PackageSpec(path = $(repr(CLI_DIR)))])
    Pkg.precompile()
    """

# Built in a new directory and moved into place only once complete, so a failed build leaves the installed
# command as it was.
NEW_ENV = ENV_DIR * ".new"
rm(NEW_ENV; force = true, recursive = true)
mkpath(NEW_ENV)
try
    foreach(f -> mv(f, aside(f)), manifests)
    run(`$(Base.julia_cmd()) --startup-file=no --project=$NEW_ENV -e $setup`)
catch
    rm(NEW_ENV; force = true, recursive = true)
    error("mapatlas: building the command's environment failed (see above); the installed `mapatlas` command, if " *
          "any, is unchanged.")
finally
    foreach(f -> isfile(aside(f)) && mv(aside(f), f; force = true), manifests)
end
rm(ENV_DIR; force = true, recursive = true)
mv(NEW_ENV, ENV_DIR)

# 2. The launcher.
julia = joinpath(Sys.BINDIR, Base.julia_exename())
mkpath(dirname(BIN))
write(BIN, """
    #!/usr/bin/env bash
    #=
    # The `mapatlas` command (AtlasCLI), written by $(joinpath(CLI_DIR, "deps", "build.jl")).
    JULIA=$(repr(julia))
    [ -x "\$JULIA" ] || JULIA=\$(command -v julia) || { echo "mapatlas: cannot find julia" >&2; exit 127; }
    JULIA_PROJECT=$(repr(ENV_DIR)) JULIA_LOAD_PATH="@:@stdlib" \\
    exec "\$JULIA" --startup-file=no --color=yes -- "\${BASH_SOURCE[0]}" "\$@"
    =#
    using AtlasCLI
    exit(AtlasCLI.command_main())
    """)
chmod(BIN, 0o755)
println("Installed $BIN (environment $ENV_DIR)")

# 3. Shell completions.
shell = basename(get(ENV, "SHELL", ""))
if shell in ("zsh", "bash")
    options = Comonicon.Configs.read_options(AtlasCLI)
    Comonicon.Builder.install_completion(AtlasCLI, options, shell)
end

# Comonicon's docstring-to-completion-text conversion hardcodes `color = true`
# (see Comonicon.jl `md_to_string`), so the generated zsh completion script embeds
# raw ANSI escape codes in its description strings. zsh's `_arguments` chokes on
# the literal escape bytes ("invalid argument" at runtime), so strip them here.
let path = joinpath(first(DEPOT_PATH), "completions", "_mapatlas")
    if isfile(path)
        text = read(path, String)
        stripped = replace(text, r"\e\[[0-9;]*m" => "")
        stripped == text || write(path, stripped)
    end
end
