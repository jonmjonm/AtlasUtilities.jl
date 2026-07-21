"""
    AtlasUtilities

Command-line utilities for redistricting Atlas files (see the Atlas format at
https://github.com/jonmjonm/AtlasIO.jl/blob/main/atlas_format.md).

Installs a single `atlas` command with seven subcommands:

  * `atlas info <atlas> [--extract-script]` — print an atlas file's header, plus
    the data field names found in its first map.
  * `atlas list-map-data <atlas>` — list the names of the data fields (e.g.
    `log_spanning_trees`) contained in the atlas's first map, one per line.
  * `atlas list-nodes <atlas> [--map k]` — list the node ids in the atlas's
    k-th map (k=1 by default) as a JSON array of strings.
  * `atlas relabel <Atlas1> <Atlas2> [<graph.json>] [--first-map] [--quiet]
    [--weight-population <pop.json> --population-attr <attr>]` — relabel
    district numbers across an atlas so consecutive maps stay consistent.
  * `atlas add <functions> <Atlas1> <Atlas2> [--config <param.toml>] [column flags]
    [--overwrite] [--quiet]` — evaluate one or more CycleWalk "pushable writer"
    functions on every map and add the results to the map data.
  * `atlas extract-map-data <Atlas1> [--add <functions>] [--no-compression] [--force]
    [column flags]` — write each map-data field to its own CSV file (one row per
    map) in a directory named after the atlas.
  * `atlas extract-assignments <Atlas1> [--no-compression] [--force] [--quiet]` —
    write a single wide CSV of each map's per-node district assignment.

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
include("nodes.jl")
include("relabel.jl")
include("add.jl")
include("extract.jl")
include("assignments.jl")

export confusionMatrix, permutationFromConfusion, hammingDistance, relabelMap,
       findRelabeling, Hierarchy, loadHierarchy, loadPopulation, atlasInfo

"""
Print the header of an Atlas file (metadata and atlas parameters); the bulky embedded generating `script` is never printed (use `--extract-script` to write it out).

# Args

- `atlas`: path to the atlas file (`.jsonl`, `.jsonl.gz`, or `.jsonl.bz2`).

# Flags

- `--extract-script`: write the header `script` entry to a file named by the
  header `script_name` entry (falling back to `extracted_script.jl`).
"""
@cast function info(atlas::String; extract_script::Bool = false)
    run_info(atlas; extract_script = extract_script)
end

"""
List the names of the data fields (e.g. `log_spanning_trees`) contained in atlas Atlas1 first map, one per line, sorted.

# Args

- `atlas`: path to the atlas file (`.jsonl`, `.jsonl.gz`, or `.jsonl.bz2`).
"""
@cast function list_map_data(atlas::String)
    run_list_map_data(atlas)
end

"""
List the node ids in atlas Atlas1 k-th map (1-based, k=1 by default), as a JSON array of strings.

# Args

- `atlas`: path to the atlas file (`.jsonl`, `.jsonl.gz`, or `.jsonl.bz2`).

# Options

- `--map <k>`: 1-based index of the map to list nodes from (default: 1).
"""
@cast function list_nodes(atlas::String; map::Int = 1)
    run_list_nodes(atlas; map = map)
end

"""
Relabel district numbers across atlas Atlas1 so consecutive maps stay as similar as possible, writing the result to Atlas2.

# Args

- `atlas1`: input atlas (`.jsonl` / `.jsonl.gz` / `.jsonl.bz2`).
- `atlas2`: output atlas.
- `graph`: optional dual-graph hierarchy (NetworkX node-link JSON). Required for
  multiscale/hierarchical atlases whose per-map node sets vary.

# Options

- `--weight-population <pop.json>`: weight the alignment by population instead
  of raw node counts. `<pop.json>` is a node-link JSON (often the same file as
  `graph`) whose nodes carry a population attribute, named by
  `--population-attr`, and are keyed by the atlas's `"levels in graph"` param.
  Requires `--population-attr`.
- `--population-attr <name>`: the population attribute name on `<pop.json>`'s
  nodes (e.g. `pop2020cen`). Required by `--weight-population`.

# Flags

- `--first-map`: align every map to map 1 (anchor) instead of to its predecessor.
- `--quiet`: suppress the progress bar.
"""
@cast function relabel(atlas1::String, atlas2::String, graph::String = "";
                       first_map::Bool = false, quiet::Bool = false,
                       weight_population::String = "", population_attr::String = "")
    run_relabel(atlas1, atlas2, isempty(graph) ? nothing : graph;
                firstMap = first_map, quiet = quiet,
                popJsonPath = isempty(weight_population) ? nothing : weight_population,
                popAttr = isempty(population_attr) ? nothing : population_attr)
end

"""
Add CycleWalk pushable writer function(s) (e.g. `get_log_spanning_trees`) to every map in atlas Atlas1, writing the augmented atlas to Atlas2; the dual graph is supplied via `--config` and/or the column flags.

# Args

- `functions`: writer function name, or a comma-separated / bracketed list.
- `atlas1`: input atlas (`.jsonl` / `.jsonl.gz` / `.jsonl.bz2`).
- `atlas2`: output atlas.

# Options

- `--config <param.toml>`: a CycleWalk TOML; its `[plans]` table supplies the
  graph path (`map_directory`/`map_file`) and columns (`pop_col`, `geo_units`,
  `area_col`, `node_border_col`, `edge_perimeter_col`, `node_data`).
- `--graph <graph.json>`: dual-graph JSON (overrides the TOML path).
- `--pop-col <col>`: population column.
- `--node-col <col>`: node id column (the districting key column).
- `--area-col <col>`: node area column.
- `--border-col <col>`: node border-length column.
- `--edge-perimeter-col <col>`: shared-edge perimeter column.
- `--node-data <cols>`: extra node attributes to keep (comma-separated list).
- `--vote-cols <pairs>`: vote columns for the partisan writers
  (`get_partisan_margins`, `get_partisan_seats`), as `votes1,votes2` pairs
  separated by `;` (e.g. `G20_PR_D,G20_PR_R;G16_PR_D,G16_PR_R` — quote it in your
  shell since it contains a `;`). Each pair adds a field
  `writer_votes1_votes2`; the columns are kept on the graph automatically.

# Flags

- `--list-writers`: print the CycleWalk writer function names usable as `functions`
  (plain and partisan) and exit; `functions`/`atlas1`/`atlas2` are not required with this flag.
- `--overwrite`: recompute a field even if a map already has it (otherwise it is
  an error for a requested field to already exist).
- `--quiet`: suppress the progress bar.
"""
@cast function add(functions::String = "", atlas1::String = "", atlas2::String = "";
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
    (isempty(functions) || isempty(atlas1) || isempty(atlas2)) &&
        error("atlas add: <functions> <atlas1> <atlas2> are required (unless --list-writers).")
    run_add(functions, atlas1, atlas2; config = config, graph = graph, pop_col = pop_col,
            node_col = node_col, area_col = area_col, border_col = border_col,
            edge_perimeter_col = edge_perimeter_col, node_data = node_data,
            vote_cols = vote_cols, overwrite = overwrite, quiet = quiet)
end

"""
Write each map-data field of atlas Atlas1 to its own CSV (one row per map) in a directory named after the atlas, plus an `about.md` describing the atlas (its `atlas info` header, minus the embedded script, with the source atlas name and extraction date); `--add` also computes CycleWalk writer functions to extract, using the same graph inputs as `atlas add`.

# Args

- `atlas1`: input atlas (`.jsonl` / `.jsonl.gz` / `.jsonl.bz2`).

# Options

- `--add <functions>`: also compute and extract these writer function(s).
- `--config <param.toml>`: CycleWalk TOML supplying the graph (for `--add`).
- `--graph <graph.json>`: dual-graph JSON (overrides the TOML path).
- `--pop-col <col>`: population column.
- `--node-col <col>`: node id column (the districting key column).
- `--area-col <col>`: node area column.
- `--border-col <col>`: node border-length column.
- `--edge-perimeter-col <col>`: shared-edge perimeter column.
- `--node-data <cols>`: extra node attributes to keep (comma-separated list).
- `--vote-cols <pairs>`: vote columns for the partisan `--add` writers
  (`get_partisan_margins`, `get_partisan_seats`), as `votes1,votes2` pairs separated
  by `;` (e.g. `G20_PR_D,G20_PR_R;G16_PR_D,G16_PR_R` — quote it in your shell since
  it contains a `;`); each pair yields a field `writer_votes1_votes2`.

# Flags

- `--no-compression`: write plain `.csv` instead of gzip-compressed `.csv.gz`.
- `--force`: overwrite an output file that already exists (otherwise it is skipped).
- `--quiet`: suppress the progress bar.
"""
@cast function extract_map_data(atlas1::String; add::String = "",
                                no_compression::Bool = false, force::Bool = false,
                                config::String = "", graph::String = "",
                                pop_col::String = "", node_col::String = "",
                                area_col::String = "", border_col::String = "",
                                edge_perimeter_col::String = "",
                                node_data::String = "", vote_cols::String = "",
                                quiet::Bool = false)
    run_extract(atlas1; add = add, compress = !no_compression, force = force,
                config = config, graph = graph, pop_col = pop_col,
                node_col = node_col, area_col = area_col, border_col = border_col,
                edge_perimeter_col = edge_perimeter_col, node_data = node_data,
                vote_cols = vote_cols, quiet = quiet)
end

"""
Write atlas Atlas1 per-map district assignments to a single wide CSV, named from the Atlas1 basename plus `-assignments.csv` (or `.csv.gz`): one row per map, columns `name` (the map name) then one column per node (the sorted node ids found in the first map of Atlas1) holding that node district number in the map. Errors if any map node set does not exactly match the first map node set, including multiscale atlases (whose node ids have more than one component) — those are not supported yet.

# Args

- `atlas1`: input atlas (`.jsonl` / `.jsonl.gz` / `.jsonl.bz2`).

# Flags

- `--no-compression`: write plain `.csv` instead of gzip-compressed `.csv.gz`.
- `--force`: overwrite the output file if it already exists (otherwise it is skipped).
- `--quiet`: suppress the progress bar.
"""
@cast function extract_assignments(atlas1::String;
                                   no_compression::Bool = false, force::Bool = false,
                                   quiet::Bool = false)
    run_extract_assignments(atlas1; compress = !no_compression, force = force, quiet = quiet)
end

# Designate this module as the CLI entry point; its `@cast` functions above
# become subcommands, and the root command's help is this module's docstring.
# Qualified because Base also exports `@main` (Julia's script entry point).
Comonicon.@main

end # module
