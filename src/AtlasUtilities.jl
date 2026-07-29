"""
    AtlasUtilities

Command-line utilities for redistricting Atlas files (see the Atlas format at
https://github.com/jonmjonm/AtlasIO.jl/blob/main/atlas_format.md).

Installs a single `atlas` command with ten subcommands:

  * `atlas info <atlas> [--extract-script]` — print the atlas file header, plus
    the data field names found in its first map; notes when an embedded run
    script and/or TOML config are present, and `--extract-script` writes out
    both (whichever exist).
  * `atlas list-map-data <atlas>` — list the names of the data fields (e.g.
    `log_spanning_trees`) contained in the first map of the atlas, one per line.
  * `atlas list-nodes <atlas> [--map k]` — list the node ids in the
    k-th map of the atlas (k=1 by default) as a JSON array of strings.
  * `atlas relabel <Atlas1> <Atlas2> [<graph.json>] [--first-map] [--quiet]
    [--weight-population <pop.json> --population-attr <attr>]` — relabel
    district numbers across an atlas so consecutive maps stay consistent.
  * `atlas add <functions> <Atlas1> <Atlas2> [--config <param.toml>] [column flags]
    [--overwrite] [--quiet]` — evaluate one or more CycleWalk "pushable writer"
    functions on every map and add the results to the map data.
  * `atlas extract-map-data <Atlas1> [--add <functions>] [--max-maps <n>]
    [--no-compression] [--force] [column flags]` — write each map-data field to
    its own CSV file (one row per map) in a directory named after the atlas.
  * `atlas extract-map-data-histogram <Atlas1> [--burn-in <n>] [--max-maps <n>]
    [--no-sort] [--add <functions>] [--no-compression] [--force] [column flags]
    [--integer true|false|auto] [--bin-range <lo,hi>] [--bin-num <n>]
    [--bins <e1,e2,...>] [--moment-powers <p1,p2,...>]` — like `extract-map-data`,
    but accumulate each map-data field into a StreamHistogram instead of writing
    per-map CSV rows.
  * `atlas summarize-map-data <Atlas1> [--max-maps <n>] [--quiet]` — print, per
    map-data field, its mean, standard deviation, and
    [min, 25% quartile, median, 75% quartile, max].
  * `atlas extract-assignments <Atlas1> [--no-compression] [--force] [--quiet]` —
    write a single wide CSV of the per-node district assignment for each map.
  * `atlas render <Atlas1> <geo> --key <col> [--map k] [--format png|svg|pdf]
    [--out <path>] [--strip-suffix <regex>] [--county-column <col>]
    [--county-lines] [--no-precinct-lines] [--skip-missing] [--show]
    [--quiet]` — draw a map's districting as a filled-precinct choropleth,
    using a shapefile or a point-position node-link JSON graph for geometry,
    and save it to an image file (optionally opening it).

Run `atlas --help` or `atlas <subcommand> --help` for details.
"""
module AtlasUtilities

using AtlasIO
using CairoMakie
using Colors
using CycleWalk
using Dates
using Hungarian
using JSON3
using LibGEOS
using LinearAlgebra: BLAS
using Makie
using ProgressMeter
using Shapefile
using StreamHistogram
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
include("extractHistogram.jl")
include("summarize.jl")
include("assignments.jl")
include("pointgraph.jl")
include("render.jl")

export confusionMatrix, permutationFromConfusion, hammingDistance, relabelMap,
       findRelabeling, Hierarchy, loadHierarchy, loadPopulation, atlasInfo, listMapData,
       mapDataHistograms, render_map, run_render, districtColors

"""
Print the header of an Atlas file (metadata and atlas parameters); the bulky embedded generating `script` and TOML config are never printed, though their presence is noted (use `--extract-script` to write them out).

# Args

- `atlas`: path to the atlas file (`.jsonl`, `.jsonl.gz`, or `.jsonl.bz2`).

# Flags

- `--extract-script`: write the header `script` entry to a file named by the
  header `script_name` entry (falling back to `extracted_script.jl`), and, if
  present, the header `toml_config` entry to a file named by the header
  `toml_config_file` entry (falling back to `extracted_config.toml`).
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
  `--population-attr`, and are keyed by the `"levels in graph"` param of the atlas.
  Requires `--population-attr`.
- `--population-attr <name>`: the population attribute name on the nodes of
  `<pop.json>` (e.g. `pop2020cen`). Required by `--weight-population`.

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

- `--config <param.toml>`: a CycleWalk TOML; its plans table supplies the
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
- `--max-maps <n>`: stop after extracting this many maps (default 0, unlimited).
  Output filenames get a `-partial` suffix so a partial run never collides with
  the output of a full run in the same directory, and `about.md` notes the limit.

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
                                max_maps::Int = 0,
                                quiet::Bool = false)
    run_extract(atlas1; add = add, compress = !no_compression, force = force,
                config = config, graph = graph, pop_col = pop_col,
                node_col = node_col, area_col = area_col, border_col = border_col,
                edge_perimeter_col = edge_perimeter_col, node_data = node_data,
                vote_cols = vote_cols, max_maps = max_maps, quiet = quiet)
end

"""
Like `extract-map-data`, but instead of writing per-map CSV rows, accumulate the values of each map-data field into a StreamHistogram: a single histogram for a scalar field, or one histogram per index for a vector field (with `--no-sort`, index `j` gets raw entry `j`; by default entry `j` of each map vector is sorted ascending first, so histogram `j` holds the `j`-th order statistic across maps rather than raw index `j`). The first `--burn-in` maps are skipped entirely. Writes a CSV + JSON pair per field, named `<field>-histogram.csv` and `<field>-histogram.json` (or `.csv.gz`/`.json.gz`), plus `about.md`, to the same directory `extract-map-data` uses. The CSV holds only the exact per-bin edges and counts (a plain numeric table for loading straight into a histogram plot); the JSON holds everything else -- per-index summary statistics, moment errors, the ASH-density bin counts, and the bin edges again -- as a human-readable dictionary keyed by index.

# Args

- `atlas1`: input atlas (`.jsonl` / `.jsonl.gz` / `.jsonl.bz2`).

# Options

- `--burn-in <n>`: skip the first `n` maps (default 0).
- `--max-maps <n>`: stop after accumulating this many maps past the burn-in
  (default 0, unlimited). Output filenames get a `-histogram-partial` suffix so a
  partial run never collides with the output of a full run in the same directory,
  and `about.md` notes the limit.
- `--add <functions>`: also compute and accumulate these writer function(s).
- `--config <param.toml>`: CycleWalk TOML supplying the graph (for `--add`).
- `--graph <graph.json>`: dual-graph JSON (overrides the TOML path).
- `--pop-col <col>`: population column.
- `--node-col <col>`: node id column (the districting key column).
- `--area-col <col>`: node area column.
- `--border-col <col>`: node border-length column.
- `--edge-perimeter-col <col>`: shared-edge perimeter column.
- `--node-data <cols>`: extra node attributes to keep (comma-separated list).
- `--vote-cols <pairs>`: vote columns for the partisan `--add` writers, as
  `votes1,votes2` pairs separated by `;` (see `atlas add --help`).
- `--bin-range <range>`: fix the bin range of every histogram up front instead of
  learning it from its own data, as `lo,hi` (e.g. `0,1`).
- `--bin-num <n>`: number of histogram bins (default 50; ignored with `--integer`).
- `--bins <edges>`: explicit bin edges, comma separated, overriding
  `--bin-range`/`--bin-num`.
- `--moment-powers <powers>`: moment orders to accumulate and report, comma
  separated (default `1,2,4,8`).
- `--integer <mode>`: `true`, `false` (default), or `auto`. `true` means the data
  is integer valued: bins are one per integer and the ASH-derived counts are
  omitted from the output. `auto` decides `true`/`false` independently for each
  histogram (each index of a vector field included) from its own learn-phase
  sample; it requires `--bin-range`/`--bins` to be left unset.

# Flags

- `--no-sort`: do not sort the entries of a vector field before accumulating (so
  histogram `j` gets raw entry `j` of each map vector, not the `j`-th order
  statistic).
- `--no-compression`: write plain `.csv` instead of gzip-compressed `.csv.gz`.
- `--force`: overwrite an output file that already exists (otherwise it is skipped).
- `--quiet`: suppress the progress bar.
"""
@cast function extract_map_data_histogram(atlas1::String; burn_in::Int = 0,
                                          max_maps::Int = 0,
                                          no_sort::Bool = false, add::String = "",
                                          config::String = "", graph::String = "",
                                          pop_col::String = "", node_col::String = "",
                                          area_col::String = "", border_col::String = "",
                                          edge_perimeter_col::String = "",
                                          node_data::String = "", vote_cols::String = "",
                                          bin_range::String = "", bin_num::Int = 50,
                                          bins::String = "",
                                          moment_powers::String = "1,2,4,8",
                                          integer::String = "false",
                                          no_compression::Bool = false, force::Bool = false,
                                          quiet::Bool = false)
    parsedBinRange = isempty(bin_range) ? nothing : Tuple(parse.(Float64, split(bin_range, ",")))
    parsedBins = isempty(bins) ? nothing : parse.(Float64, split(bins, ","))
    parsedPowers = parse.(Int, split(moment_powers, ","))
    parsedInteger = integer == "auto" ? :auto :
                    integer == "true" ? true :
                    integer == "false" ? false :
                    error("atlas extract-map-data-histogram: --integer must be " *
                          "true, false, or auto, got \"$integer\".")
    run_extract_map_data_histogram(atlas1; add = add, vote_cols = vote_cols,
        config = config, graph = graph, pop_col = pop_col, node_col = node_col,
        area_col = area_col, border_col = border_col,
        edge_perimeter_col = edge_perimeter_col, node_data = node_data,
        burn_in = burn_in, max_maps = max_maps, sortVals = !no_sort,
        compress = !no_compression, force = force, integer = parsedInteger,
        bin_range = parsedBinRange, bin_num = bin_num, bins = parsedBins,
        moment_powers = parsedPowers, quiet = quiet)
end

"""
Print, for every map-data field of atlas Atlas1, its mean, standard deviation, and [min, 25% quartile, median, 75% quartile, max], each computed from a StreamHistogram built over the field values (one histogram per index for a vector field, each map vector sorted ascending first, so histogram j holds the j-th order statistic across maps). Warns when too much of a field data set fell outside its histogram learned range (the tail quantile estimates lean on a single coarse interpolation across that whole bucket), or when a quartile estimate disagrees with the ASH density estimate for that field by more than a couple of percentage points (the within-bin-uniform interpolation may not fit the shape of that field).

# Args

- `atlas1`: input atlas (`.jsonl` / `.jsonl.gz` / `.jsonl.bz2`).

# Options

- `--max-maps <n>`: only consider the first `n` maps of the atlas (default 0,
  unlimited).

# Flags

- `--quiet`: suppress the progress bar.
"""
@cast function summarize_map_data(atlas1::String; max_maps::Int = 0, quiet::Bool = false)
    run_summarize_map_data(atlas1; max_maps = max_maps, quiet = quiet)
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

"""
Draw the districting of map `map` (1-based, default 1) of atlas Atlas1 as a filled-precinct choropleth, colored by district, and save it to an image file. Geometry comes from `geo` -- a shapefile (a `.shp` file, or a `.zip` bundling `.shp`/`.shx`/`.dbf`), or a point-position node-link JSON graph (e.g. `Data/hex_graph_10_by_10.json`), whose nodes' Voronoi cells are used -- matched to the atlas's node ids via the attribute named by `--key`. By default errors if any node id has no matching geometry record; `--skip-missing` renders anyway, leaving those areas blank.

# Args

- `atlas1`: input atlas (`.jsonl` / `.jsonl.gz` / `.jsonl.bz2`).
- `geo`: path to a `.shp` file, a `.zip` bundling one (e.g. `Data/shapefile_CT.zip`), or a point-position node-link `.json` graph (e.g. `Data/hex_graph_10_by_10.json`).

# Options

- `--key <col>`: required; the attribute whose values match the atlas's node ids --
  a shapefile column (e.g. `NAME` for the CT/OH example data) or a point-graph node
  attribute (e.g. `node_name` for the hex/grid example data). For atlases whose node
  id has more than one component (e.g. NC's `(county, prec_id)`), pass a
  comma-separated list of attributes in the same order (e.g. `county,prec_id`); they
  are joined with `:`, matching how the atlas's own node id is rendered as a string.
  Use `atlas list-nodes` on the atlas first to see the exact id format expected.
- `--strip-suffix <regex>`: strip a trailing regex match from each node id before
  matching it against the geometry source (e.g. some CycleWalk graphs built for
  legislative-district consistency suffix node ids with `__SD<n>__HD<n>` tags
  that have no geometry counterpart; pass `"__SD\\d+__HD\\d+"` to strip them).
- `--county-column <col>`: the geometry source's county attribute (a shapefile
  column, or a point-graph node attribute). Some graphs only keep precinct-level
  detail for counties split by a district line, collapsing an entire unsplit
  county into one node (e.g. NC's `("GASTON",)`); a node id matching no precinct
  token at all is then tried case-insensitively against this attribute, and on a
  match falls back to every precinct in that county (all drawn in the node's
  district color). Required by `--county-lines`.
- `--map <k>`: 1-based index of the map to draw (default: 1).
- `--format <png|svg|pdf>`: output image format when `--out` is not given
  (default `png`).
- `--out <path>`: output file path (default `<Atlas1 basename>-map<k>.<format>`).

# Flags

- `--county-lines`: draw each county's outline (needs `--county-column`) -- for a
  shapefile, its rows are dissolved into that county's true polygon via LibGEOS; for
  a point-graph, the graph's own adjacency supplies the exact shared edge between
  differing-county neighbors.
- `--no-precinct-lines`: omit the per-row stroke (drawn by default).
- `--skip-missing`: render even if some node ids have no (or only a partial)
  matching geometry record, leaving those areas blank, instead of erroring.
- `--show`: open the saved image in the OS's default viewer (`open` on macOS,
  `xdg-open` on Linux) after writing it.
- `--quiet`: suppress the confirmation message.
"""
@cast function render(atlas1::String, geo::String;
                      key::String = "", map::Int = 1,
                      format::String = "png", out::String = "",
                      strip_suffix::String = "", county_column::String = "",
                      county_lines::Bool = false, no_precinct_lines::Bool = false,
                      skip_missing::Bool = false, show::Bool = false,
                      quiet::Bool = false)
    run_render(atlas1, geo; key = key, map = map,
              format = format, out = out, strip_suffix = strip_suffix,
              county_column = county_column, county_lines = county_lines,
              precinct_lines = !no_precinct_lines, skip_missing = skip_missing,
              show = show, quiet = quiet)
end

# Designate this module as the CLI entry point; its `@cast` functions above
# become subcommands, and the root command's help is this module's docstring.
# Qualified because Base also exports `@main` (Julia's script entry point).
Comonicon.@main

end # module
