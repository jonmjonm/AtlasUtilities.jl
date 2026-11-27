# Running `mapatlas` subcommands from the tests through `command_main`, the entry point the installed command uses.
using AtlasCLI: command_main

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

"Run `mapatlas args...`; returns the exit code. Print with `capture_stdout` to see the output."
atlas_cmd(args...) = command_main(collect(String, args))

flag(on, name) = on ? [name] : String[]

cli_info(path; extract_script = false, force = false) =
    atlas_cmd("info", path, flag(extract_script, "--extract-script")..., flag(force, "--force")...)
cli_list_map_data(path) = atlas_cmd("list-map-data", path)
cli_list_nodes(path; map = 1) = atlas_cmd("list-nodes", path, "--map", string(map))
cli_list_writers() = atlas_cmd("add", "--list-writers")
cli_extract_assignments(path; graph = nothing, compress = true, force = false, quiet = false) =
    atlas_cmd("extract-assignments", path, (graph === nothing ? String[] : ["--graph", graph])...,
              flag(!compress, "--no-compression")..., flag(force, "--force")..., flag(quiet, "--quiet")...)
