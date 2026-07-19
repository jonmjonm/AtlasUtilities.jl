"""
    AtlasUtilities

Command-line utilities for redistricting Atlas files (see the Atlas format at
https://github.com/jonmjonm/AtlasIO.jl/blob/main/atlas_format.md).

Installs a single `atlas` command with five subcommands:

  * `atlas info <atlas> [--extract-script]` — print an atlas file's header, plus
    the data field names found in its first map.
  * `atlas list-map-data <atlas>` — list the names of the data fields (e.g.
    `log_spanning_trees`) contained in the atlas's first map, one per line.
  * `atlas relabel <A1> <A2> [<graph.json>] [--first-map] [--quiet]` — relabel
    district numbers across an atlas so consecutive maps stay consistent.
  * `atlas add <functions> <A1> <A2> [--config <param.toml>] [column flags]
    [--overwrite] [--quiet]` — evaluate one or more CycleWalk "pushable writer"
    functions on every map and add the results to the map data.
  * `atlas extract-map-data <A1> [--add <functions>] [--no-compression] [--force]
    [column flags]` — write each map-data field to its own CSV file (one row per
    map) in a directory named after the atlas.

Run `atlas --help` or `atlas <subcommand> --help` for details.
"""
module AtlasUtilities

using AtlasIO
using CycleWalk
using Dates
using Hungarian
using JSON3
using LinearAlgebra: BLAS
using ProgressMeter
using TOML
using Comonicon

# Byte-targeted parallel gzip atlas output (`AtlasOutput`/`openAtlasOutput`/
# `writeMaps!`/`atlasHeaderBytes`) is provided by AtlasIO (>= 0.1.3) and used below.
include("threading.jl")
include("info.jl")
include("reorder.jl")
include("add.jl")
include("extract.jl")

"""
Print an Atlas file's header (metadata and atlas parameters); the bulky embedded generating "script" is never printed (use `--extract-script` to write it out).

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
List the names of the data fields (e.g. `log_spanning_trees`) contained in atlas A1's first map, one per line, sorted.

# Args

- `atlas`: path to the atlas file (`.jsonl`, `.jsonl.gz`, or `.jsonl.bz2`).
"""
@cast function list_map_data(atlas::String)
    run_list_map_data(atlas)
end

"""
Relabel district numbers across atlas A1 so consecutive maps stay as similar as possible, writing the result to A2.

# Args

- `a1`: input atlas (`.jsonl` / `.jsonl.gz` / `.jsonl.bz2`).
- `a2`: output atlas.
- `graph`: optional dual-graph hierarchy (NetworkX node-link JSON). Required for
  multiscale/hierarchical atlases whose per-map node sets vary.

# Flags

- `--first-map`: align every map to map 1 (anchor) instead of to its predecessor.
- `--quiet`: suppress the progress bar.
"""
@cast function relabel(a1::String, a2::String, graph::String = "";
                       first_map::Bool = false, quiet::Bool = false)
    run_reorder(a1, a2, isempty(graph) ? nothing : graph;
                firstMap = first_map, quiet = quiet)
end

"""
Add CycleWalk "pushable writer" function(s) (e.g. `get_log_spanning_trees`) to every map in atlas A1, writing the augmented atlas to A2; the dual graph is supplied via `--config` and/or the column flags.

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
- `--vote-cols <pairs>`: vote columns for the partisan writers
  (`get_partisan_margins`, `get_partisan_seats`), as `votes1,votes2` pairs
  separated by `;` (e.g. `"G20_PR_D,G20_PR_R;G16_PR_D,G16_PR_R"`). Each pair adds a
  field `<writer>_<votes1>_<votes2>`; the columns are kept on the graph automatically.

# Flags

- `--list-writers`: print the CycleWalk writer function names usable as `functions`
  (plain and partisan) and exit; `functions`/`a1`/`a2` are not required with this flag.
- `--overwrite`: recompute a field even if a map already has it (otherwise it is
  an error for a requested field to already exist).
- `--quiet`: suppress the progress bar.
"""
@cast function add(functions::String = "", a1::String = "", a2::String = "";
                   list_writers::Bool = false,
                   config::String = "", graph::String = "",
                   pop_col::String = "", node_col::String = "",
                   area_col::String = "", border_col::String = "",
                   edge_perimeter_col::String = "", node_data::String = "",
                   vote_cols::String = "",
                   overwrite::Bool = false, quiet::Bool = false)
    if list_writers
        run_list_writers()
        return
    end
    (isempty(functions) || isempty(a1) || isempty(a2)) &&
        error("atlas add: <functions> <a1> <a2> are required (unless --list-writers).")
    run_add(functions, a1, a2; config = config, graph = graph, pop_col = pop_col,
            node_col = node_col, area_col = area_col, border_col = border_col,
            edge_perimeter_col = edge_perimeter_col, node_data = node_data,
            vote_cols = vote_cols, overwrite = overwrite, quiet = quiet)
end

"""
Write each map-data field of atlas A1 to its own CSV (one row per map) in a directory named after the atlas, plus an `about.md` describing the atlas (its `atlas info` header, minus the embedded script, with the source atlas name and extraction date); `--add` also computes CycleWalk writer functions to extract, using the same graph inputs as `atlas add`.

# Args

- `a1`: input atlas (`.jsonl` / `.jsonl.gz` / `.jsonl.bz2`).

# Options

- `--add <functions>`: also compute and extract these writer function(s).
- `--config <param.toml>`: CycleWalk TOML supplying the graph (for `--add`).
- `--graph <graph.json>`: dual-graph JSON (overrides the TOML's path).
- `--pop-col <col>`: population column.
- `--node-col <col>`: node id column (the districting key column).
- `--area-col <col>`: node area column.
- `--border-col <col>`: node border-length column.
- `--edge-perimeter-col <col>`: shared-edge perimeter column.
- `--node-data <cols>`: extra node attributes to keep (comma-separated list).
- `--vote-cols <pairs>`: vote columns for the partisan `--add` writers
  (`get_partisan_margins`, `get_partisan_seats`), as `votes1,votes2` pairs separated
  by `;` (e.g. `"G20_PR_D,G20_PR_R;G16_PR_D,G16_PR_R"`); each pair yields a field
  `<writer>_<votes1>_<votes2>`.

# Flags

- `--no-compression`: write plain `.csv` instead of gzip-compressed `.csv.gz`.
- `--force`: overwrite an output file that already exists (otherwise it is skipped).
- `--quiet`: suppress the progress bar.
"""
@cast function extract_map_data(a1::String; add::String = "",
                                no_compression::Bool = false, force::Bool = false,
                                config::String = "", graph::String = "",
                                pop_col::String = "", node_col::String = "",
                                area_col::String = "", border_col::String = "",
                                edge_perimeter_col::String = "",
                                node_data::String = "", vote_cols::String = "",
                                quiet::Bool = false)
    run_extract(a1; add = add, compress = !no_compression, force = force,
                config = config, graph = graph, pop_col = pop_col,
                node_col = node_col, area_col = area_col, border_col = border_col,
                edge_perimeter_col = edge_perimeter_col, node_data = node_data,
                vote_cols = vote_cols, quiet = quiet)
end

# Designate this module as the CLI entry point; its `@cast` functions above
# become subcommands, and the root command's help is this module's docstring.
# Qualified because Base also exports `@main` (Julia's script entry point).
Comonicon.@main

end # module
