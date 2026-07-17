"""
    AtlasUtilities

Command-line utilities for redistricting Atlas files (see the Atlas format at
https://github.com/jonmjonm/AtlasIO.jl/blob/main/atlas_format.md).

Installs a single `atlas` command with two subcommands:

  * `atlas info <atlas> [--extract-script]` — print an atlas file's header.
  * `atlas reorder <A1> <A2> [<graph.json>] [--first-map] [--quiet]` — relabel
    district numbers across an atlas so consecutive maps stay consistent.

Run `atlas --help`, `atlas info --help`, or `atlas reorder --help` for details.
"""
module AtlasUtilities

using AtlasIO
using Hungarian
using JSON3
using ProgressMeter
using Comonicon

include("info.jl")
include("reorder.jl")

"""
Print the header information of an Atlas file: the header metadata (line 2) and
the atlas parameters (line 3). The bulky "script" entry — the full source of the
script that generated the atlas — is never printed.

# Args

- `atlas`: path to the atlas file (`.jsonl`, `.jsonl.gz`, or `.jsonl.bz2`).

# Flags

- `--extract-script`: write the header's "script" entry to a file named by the
  header's "script_name" entry (falling back to `extracted_script.jl`).
"""
@cast function info(atlas::String; extract_script::Bool = false)
    run_info(atlas; extract_script = extract_script)
end

"""
Walk every map in input atlas A1, relabel district numbers so consecutive maps
are as similar as possible, and write the relabeled maps to a new atlas A2.

Parsing is threaded across the threads Julia was started with (`julia
--threads=N`); with one thread it runs serially.

# Args

- `a1`: input atlas (`.jsonl` / `.jsonl.gz` / `.jsonl.bz2`).
- `a2`: output atlas.
- `graph`: optional dual-graph hierarchy (NetworkX node-link JSON). Required for
  multiscale/hierarchical atlases whose per-map node sets vary.

# Flags

- `--first-map`: align every map to map 1 (anchor) instead of to its predecessor.
- `--quiet`: suppress the progress bar.
"""
@cast function reorder(a1::String, a2::String, graph::String = "";
                       first_map::Bool = false, quiet::Bool = false)
    run_reorder(a1, a2, isempty(graph) ? nothing : graph;
                firstMap = first_map, quiet = quiet)
end

# Designate this module as the CLI entry point; its `@cast` functions above
# become subcommands, and the root command's help is this module's docstring.
# Qualified because Base also exports `@main` (Julia's script entry point).
Comonicon.@main

end # module
