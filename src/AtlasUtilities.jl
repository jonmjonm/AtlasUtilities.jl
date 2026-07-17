"""
    AtlasUtilities

Command-line utilities for redistricting Atlas files (see the Atlas format at
https://github.com/jonmjonm/AtlasIO.jl/blob/main/atlas_format.md).

Installs a single `atlas` command with three subcommands:

  * `atlas info <atlas> [--extract-script]` — print an atlas file's header.
  * `atlas reorder <A1> <A2> [<graph.json>] [--first-map] [--quiet]` — relabel
    district numbers across an atlas so consecutive maps stay consistent.
  * `atlas add <functions> <A1> <A2> [--config <param.toml>] [column flags]
    [--overwrite] [--quiet]` — evaluate one or more CycleWalk "pushable writer"
    functions on every map and add the results to the map data.

Run `atlas --help` or `atlas <subcommand> --help` for details.
"""
module AtlasUtilities

using AtlasIO
using CycleWalk
using Dates
using Hungarian
using JSON3
using ProgressMeter
using TOML
using Comonicon

include("info.jl")
include("reorder.jl")
include("add.jl")

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

"""
Add one or more CycleWalk "pushable writer" functions to every map in input atlas
A1, writing the augmented atlas to A2.

`functions` names the function(s) to add — the same functions you would pass to
`push_writer!` during a CycleWalk run (e.g. `get_log_spanning_trees`). Pass a
single name, a comma-separated list, or a bracketed list to add several in one
pass:

    atlas add get_log_spanning_trees A1 A2 --config param.toml
    atlas add "get_log_spanning_trees,get_isoperimetric_scores" A1 A2 --graph g.json --pop-col POP20 --node-col NAME --area-col area --border-col border_length --edge-perimeter-col length

A CycleWalk atlas stores only districtings, so the dual graph the atlas was
sampled on must be supplied — via a CycleWalk `--config` TOML, via the column
flags below, or a mix (a flag overrides / fills in the TOML). Each map's
partition is rebuilt on that graph and the function evaluated on it exactly as
CycleWalk does when it writes out the data.

# Args

- `functions`: writer function name, or a comma-separated / bracketed list.
- `a1`: input atlas (`.jsonl` / `.jsonl.gz` / `.jsonl.bz2`).
- `a2`: output atlas.

# Options

- `--config <param.toml>`: a CycleWalk TOML; its `[plans]` table supplies the
  graph path (`map_directory`/`map_file`) and columns (`pop_col`, `geo_units`,
  `area_col`, `node_border_col`, `edge_perimeter_col`, `node_data`).
- `--graph <graph.json>`: dual-graph JSON (overrides the TOML's path).
- `--pop-col <col>`: population column.
- `--node-col <col>`: node id column (the districting key column).
- `--area-col <col>`: node area column.
- `--border-col <col>`: node border-length column.
- `--edge-perimeter-col <col>`: shared-edge perimeter column.
- `--node-data <cols>`: extra node attributes to keep (comma-separated list).

# Flags

- `--overwrite`: recompute a field even if a map already has it (otherwise it is
  an error for a requested field to already exist).
- `--quiet`: suppress the progress bar.
"""
@cast function add(functions::String, a1::String, a2::String;
                   config::String = "", graph::String = "",
                   pop_col::String = "", node_col::String = "",
                   area_col::String = "", border_col::String = "",
                   edge_perimeter_col::String = "", node_data::String = "",
                   overwrite::Bool = false, quiet::Bool = false)
    run_add(functions, a1, a2; config = config, graph = graph, pop_col = pop_col,
            node_col = node_col, area_col = area_col, border_col = border_col,
            edge_perimeter_col = edge_perimeter_col, node_data = node_data,
            overwrite = overwrite, quiet = quiet)
end

# Designate this module as the CLI entry point; its `@cast` functions above
# become subcommands, and the root command's help is this module's docstring.
# Qualified because Base also exports `@main` (Julia's script entry point).
Comonicon.@main

end # module
