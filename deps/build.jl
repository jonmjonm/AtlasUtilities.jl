# Runs on `Pkg.add` / `Pkg.build("AtlasUtilities")`. Comonicon reads the
# [comonicon] config in Project.toml and installs the `atlas` launcher into
# ~/.julia/bin, compiling a system image (per [comonicon.sysimg]) so the command
# starts fast. Add ~/.julia/bin to your PATH to use it.
using AtlasUtilities
AtlasUtilities.comonicon_install()

# Comonicon's docstring-to-completion-text conversion hardcodes `color = true`
# (see Comonicon.jl `md_to_string`), so the generated zsh completion script embeds
# raw ANSI escape codes in its description strings. zsh's `_arguments` chokes on
# the literal escape bytes ("invalid argument" at runtime), so strip them here.
let path = joinpath(homedir(), ".julia", "completions", "_atlas")
    if isfile(path)
        text = read(path, String)
        stripped = replace(text, r"\e\[[0-9;]*m" => "")
        stripped == text || write(path, stripped)
    end
end
