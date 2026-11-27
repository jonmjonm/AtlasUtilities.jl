# Running `atlas` subcommands from the tests through `command_main`, the entry point the installed command uses,
# for the tests that check what a command prints (the library functions return their results instead).
using AtlasUtilities: command_main

"Run `atlas args...`; returns the exit code. Print with `capture_stdout` to see the output."
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

using AtlasUtilities: mapDataHistograms, writeHistograms, stripAtlasExt

"`extract-map-data-histogram` from the library: `mapDataHistograms`, then `writeHistograms` next to the atlas."
function histogramFiles(path; burn_in = 0, max_maps = 0, compress = true, force = false, kw...)
    hists, _ = mapDataHistograms(path; burn_in, max_maps, kw...)
    return writeHistograms(stripAtlasExt(path), hists; atlas = path, burn_in, max_maps, compress, force)
end
