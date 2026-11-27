"""
    AtlasCLI

Command-line utilities for redistricting Atlas files (see the Atlas format at
https://github.com/jonmjonm/AtlasIO.jl/blob/main/atlas_format.md).

Installs a single `mapatlas` command with ten subcommands:

  * `mapatlas info <atlas> [--extract-script] [--force]` — print the atlas file
    header, plus the data field names found in its first map; notes when an
    embedded run script, its includes, and/or a TOML config are present, and
    `--extract-script` writes out each of them (whichever exist) into the
    current directory.
  * `mapatlas convert <src> <dst> [--to 1|2] [--quiet]` — convert an atlas between
    Atlas format versions 1 and 2.
  * `mapatlas list-map-data <atlas>` — list the names of the data fields (e.g.
    `log_spanning_trees`) contained in the first map of the atlas, one per line.
  * `mapatlas list-nodes <atlas> [--map k]` — list the node ids in the
    k-th map of the atlas (k=1 by default) as a JSON array of strings.
  * `mapatlas relabel <Atlas1> <Atlas2> [<graph.json>] [--first-map] [--quiet]
    [--weight-population <pop.json> --population-attr <attr>]` — relabel
    district numbers across an atlas so consecutive maps stay consistent.
  * `mapatlas add <functions> <Atlas1> <Atlas2> [--config <param.toml>] [column flags]
    [--overwrite] [--quiet]` — evaluate one or more CycleWalk "pushable writer"
    functions on every map and add the results to the map data.
  * `mapatlas extract-map-data <Atlas1> [--add <functions>] [--max-maps <n>]
    [--no-compression] [--force] [column flags]` — write each map-data field to
    its own CSV file (one row per map) in a directory named after the atlas.
  * `mapatlas extract-map-data-histogram <Atlas1> [--burn-in <n>] [--max-maps <n>]
    [--no-sort] [--add <functions>] [--no-compression] [--force] [column flags]
    [--integer true|false|auto] [--bin-range <lo,hi>] [--bin-num <n>]
    [--bins <e1,e2,...>] [--moment-powers <p1,p2,...>]` — like `extract-map-data`,
    but accumulate each map-data field into a StreamHistogram instead of writing
    per-map CSV rows.
  * `mapatlas summarize-map-data <Atlas1> [--max-maps <n>] [--quiet]` — print, per
    map-data field, its mean, standard deviation, and
    [min, 25% quartile, median, 75% quartile, max].
  * `mapatlas extract-assignments <Atlas1> [--graph <graph.json>] [--no-compression] [--force] [--quiet]` —
    write a single wide CSV of the district assignment of each map, per node (multiscale atlases: per finest unit).

Run `mapatlas --help` or `mapatlas <subcommand> --help` for details.
"""
module AtlasCLI

using AtlasIO
using AtlasUtilities
using AtlasUtilities: atlasHeaderInfo, listWriterDetails, stripAtlasExt, SCRIPT_KEY
using Comonicon
using CycleWalk        # switches on AtlasUtilities' CycleWalk extension, for `add` and `--add`
import JSON
# Not used by name: only listed (with its [sources] URL in Project.toml) so that Julia 1.11 can find it, until
# it is registered.
import StreamHistogram

include("parsers.jl")
include("cli.jl")

"""
Print the header of an Atlas file (metadata and atlas parameters); the bulky embedded generating `script`, its `script_includes`, and the TOML config are never printed, though their presence is noted (use `--extract-script` to write them out).

# Args

- `atlas`: path to the atlas file (`.jsonl`, `.jsonl.gz`, or `.jsonl.bz2`).

# Flags

- `--extract-script`: write the header `script` entry to a file named by the
  header `script_name` entry (falling back to `extracted_script.jl`), and, if
  present, the header `toml_config` entry to a file named by the header
  `toml_config_file` entry (falling back to `extracted_config.toml`) and each
  `script_includes` entry to a file of its own name. Every file is written in the
  current directory, under the basename of the recorded name, so extraction can
  never write back over the original.
- `--force`: overwrite an existing file of that name (otherwise its entry is
  skipped, with a message).
"""
@cast function info(atlas::String; extract_script::Bool = false,
                    force::Bool = false)
    cli("info") do
        print(atlasHeaderInfo(atlas))
        extract_script && printExtracted(extractScripts(atlas; force = force))
    end
end

"""
Convert atlas `src` to Atlas format version `--to` (1 or 2), writing `dst`.

Only the `formatVersion` in the header and the district assignment of each map are rewritten; the banner, the
atlas parameters and the name, weight and data of every map are copied byte for byte. Converting back gives the same
districting for every map. A districting that format v2 cannot hold (a region both whole and split) stops
the conversion with an error naming the line and map. The two versions are described in `atlas_format.md` of AtlasIO.

# Args

- `src`: the atlas to convert (`.jsonl`, `.jsonl.gz`, or `.jsonl.bz2`).
- `dst`: the converted atlas to write (`.jsonl`, `.jsonl.gz`, or `.jsonl.bz2`).

# Options

- `--to <version>`: the format version to write, 1 or 2 (default: 2).

# Flags

- `--quiet`: do not print the number of maps converted.
"""
@cast function convert(src::String, dst::String; to::Int = 2, quiet::Bool = false)
    cli("convert") do
        to in (1, 2) || error("mapatlas convert: --to must be 1 or 2, got $to.")
        n = convertAtlas(src, dst; formatVersion = to, cores = Threads.nthreads())
        quiet || println("converted $n maps to format v$to: $dst")
    end
end

"""
List the names of the data fields (e.g. `log_spanning_trees`) contained in atlas Atlas1 first map, one per line, sorted.

# Args

- `atlas`: path to the atlas file (`.jsonl`, `.jsonl.gz`, or `.jsonl.bz2`).
"""
@cast function list_map_data(atlas::String)
    cli("list-map-data") do
        fieldNames = listMapData(atlas)
        if fieldNames === nothing
            println("mapatlas list-map-data: $atlas has no maps; nothing to list.")
        elseif isempty(fieldNames)
            println("mapatlas list-map-data: $atlas's first map has no data fields.")
        else
            foreach(println, fieldNames)
        end
    end
end

"""
List the node ids in atlas Atlas1 k-th map (1-based, k=1 by default), as a JSON array of strings.

# Args

- `atlas`: path to the atlas file (`.jsonl`, `.jsonl.gz`, or `.jsonl.bz2`).

# Options

- `--map <k>`: 1-based index of the map to list nodes from (default: 1).
"""
@cast function list_nodes(atlas::String; map::Int = 1)
    cli("list-nodes") do
        map >= 1 || error("mapatlas list-nodes: --map must be >= 1 (got $map).")
        JSON.json(stdout, listNodes(atlas; map = map))
        println()
    end
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
- `--keep-partial`: if the command fails partway, keep what it wrote, as OUT.incomplete.EXT, for debugging
  (otherwise nothing is left; an existing output is never replaced by an incomplete one).
"""
@cast function relabel(atlas1::String, atlas2::String, graph::String = "";
                       first_map::Bool = false, quiet::Bool = false,
                       weight_population::String = "", population_attr::String = "",
                       keep_partial::Bool = false)
    cli("relabel") do
        relabelAtlas(atlas1, atlas2; graph = isempty(graph) ? nothing : graph, first_map = first_map,
                     population_file = isempty(weight_population) ? nothing : weight_population,
                     population_attr = isempty(population_attr) ? nothing : population_attr,
                     progress = !quiet, keep_partial = keep_partial)
    end
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
- `--keep-partial`: if the command fails partway, keep what it wrote, as OUT.incomplete.EXT, for debugging
  (otherwise nothing is left; an existing output is never replaced by an incomplete one).
"""
@cast function add(functions::String = "", atlas1::String = "", atlas2::String = "";
                   list_writers::Bool = false,
                   config::String = "", graph::String = "",
                   pop_col::String = "", node_col::String = "",
                   area_col::String = "", border_col::String = "",
                   edge_perimeter_col::String = "", node_data::String = "",
                   vote_cols::String = "",
                   overwrite::Bool = false, quiet::Bool = false, keep_partial::Bool = false)
    cli("add") do
        list_writers && return printWriterList()
        (isempty(functions) || isempty(atlas1) || isempty(atlas2)) &&
            error("mapatlas add: <functions> <atlas1> <atlas2> are required (unless --list-writers).")
        ws = cliWriterSet(functions; config, graph, pop_col, node_col, area_col, border_col,
                          edge_perimeter_col, node_data, vote_cols)
        addMapData(atlas1, atlas2, ws; overwrite = overwrite, progress = !quiet, keep_partial = keep_partial)
    end
end

"""
Write each map-data field of atlas Atlas1 to its own CSV (one row per map: the map name, the field value, then the map weight in a last `map_weight` column) in a directory named after the atlas, plus an `about.md` describing the atlas (its `mapatlas info` header, minus the embedded script, with the source atlas name and extraction date); `--add` also computes CycleWalk writer functions to extract, using the same graph inputs as `mapatlas add`.

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
- `--keep-partial`: if the command fails partway, keep what it wrote, as FIELD.incomplete.csv.gz, for debugging
  (otherwise nothing is left; an existing output is never replaced by an incomplete one).
"""
@cast function extract_map_data(atlas1::String; add::String = "",
                                no_compression::Bool = false, force::Bool = false,
                                config::String = "", graph::String = "",
                                pop_col::String = "", node_col::String = "",
                                area_col::String = "", border_col::String = "",
                                edge_perimeter_col::String = "",
                                node_data::String = "", vote_cols::String = "",
                                max_maps::Int = 0,
                                quiet::Bool = false, keep_partial::Bool = false)
    cli("extract-map-data") do
        max_maps < 0 && error("mapatlas extract-map-data: --max-maps must be ≥ 0, got $max_maps.")
        ws = isempty(add) ? nothing :
             cliWriterSet(add; config, graph, pop_col, node_col, area_col, border_col, edge_perimeter_col,
                          node_data, vote_cols)
        r = extractMapData(atlas1; writers = ws, compress = !no_compression, force = force, max_maps = max_maps,
                           progress = !quiet, keep_partial = keep_partial)
        if isempty(r.written)
            println("mapatlas extract-map-data: $atlas1 has no maps; nothing written.")
            return
        end
        isempty(r.skipped) || @info "extract-map-data: skipping existing file(s) " *
            "(use --force to overwrite): " * join(basename.(r.skipped), ", ")
        if length(r.written) == 1           # about.md only
            println("mapatlas extract-map-data: nothing to write (all target files exist; pass --force to overwrite).")
            return
        end
        quiet || println("Wrote ", length(r.written) - 1, " file(s) + about.md to ", r.outdir, "/")
    end
end

"""
Like `extract-map-data`, but instead of writing per-map CSV rows, accumulate the values of each map-data field into a StreamHistogram: a single histogram for a scalar field, or one histogram per index for a vector field (with `--no-sort`, index `j` gets raw entry `j`; by default entry `j` of each map vector is sorted ascending first, so histogram `j` holds the `j`-th order statistic across maps rather than raw index `j`). The first `--burn-in` maps are skipped entirely. Writes a CSV + JSON pair per field, named `<field>-histogram.csv` and `<field>-histogram.json` (or `.csv.gz`/`.json.gz`), plus `about.md`, to the same directory `extract-map-data` uses. Each value is counted both once and with its map weight. The CSV holds only the exact per-bin edges, counts (`exact_count`) and sums of map weights (`weight_sum`), a plain numeric table for loading straight into a histogram plot; the JSON holds everything else -- per-index summary statistics, unweighted and weighted (`total_weight`, `effective_sample_size`, `weighted_mean`, ...), moment errors, the ASH-density bin counts and weights, and the bin edges again -- as a human-readable dictionary keyed by index.

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
  `votes1,votes2` pairs separated by `;` (see `mapatlas add --help`).
- `--bin-range <range>`: fix the bin range of every histogram up front instead of
  learning it from its own data, as `lo,hi` (e.g. `0,1`).
- `--bin-num <n>`: number of histogram bins (default 50; ignored with `--integer`).
- `--bins <edges>`: explicit bin edges, comma separated, overriding
  `--bin-range`/`--bin-num`.
- `--moment-powers <powers>`: moment orders to accumulate and report, comma
  separated (default `1,2,4,8`). Variance and std need a highest power of at least 2, skewness 3 and
  excess kurtosis 4; with a lower one they are written as null.
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
    cli("extract-map-data-histogram") do
        max_maps < 0 && error("mapatlas extract-map-data-histogram: --max-maps must be ≥ 0, got $max_maps.")
        parsedBinRange = isempty(bin_range) ? nothing : Tuple(parse.(Float64, split(bin_range, ",")))
        parsedBins = isempty(bins) ? nothing : parse.(Float64, split(bins, ","))
        parsedPowers = parse.(Int, split(moment_powers, ","))
        parsedInteger = integer == "auto" ? :auto :
                        integer == "true" ? true :
                        integer == "false" ? false :
                        error("mapatlas extract-map-data-histogram: --integer must be " *
                              "true, false, or auto, got \"$integer\".")
        outdir = stripAtlasExt(atlas1)
        isdir(outdir) || mkpath(outdir)
        if listMapData(atlas1) === nothing
            println("mapatlas extract-map-data-histogram: $atlas1 has no maps; nothing written.")
            return
        end
        ws = isempty(add) ? nothing :
             cliWriterSet(add; config, graph, pop_col, node_col, area_col, border_col, edge_perimeter_col,
                          node_data, vote_cols)
        hists, _ = mapDataHistograms(atlas1; writers = ws, burn_in = burn_in, max_maps = max_maps,
                                     sort_values = !no_sort, progress = !quiet, integer = parsedInteger,
                                     bin_range = parsedBinRange, bin_num = bin_num, bins = parsedBins,
                                     moment_powers = parsedPowers)
        r = writeHistograms(outdir, hists; atlas = atlas1, burn_in = burn_in, max_maps = max_maps,
                            compress = !no_compression, force = force)
        isempty(r.skipped) || @info "extract-map-data-histogram: skipping existing file(s) " *
            "(use --force to overwrite): " * join(r.skipped, ", ")
        quiet || println("Wrote ", length(r.written) - 1, " file(s) + about.md to ", outdir, "/")
    end
end

"""
Print, for every map-data field of atlas Atlas1, its mean, standard deviation, and [min, 25% quartile, median, 75% quartile, max], each computed from a StreamHistogram built over the field values (one histogram per index for a vector field, each map vector sorted ascending first, so histogram j holds the j-th order statistic across maps). When the map weights vary, the weighted mean, standard deviation and quartiles (each map counting its weight) follow, with the effective sample size. Warns when too much of a field data set fell outside its histogram learned range (the tail quantile estimates lean on a single coarse interpolation across that whole bucket), or when a quartile estimate disagrees with the ASH density estimate for that field by more than a couple of percentage points (the within-bin-uniform interpolation may not fit the shape of that field).

# Args

- `atlas1`: input atlas (`.jsonl` / `.jsonl.gz` / `.jsonl.bz2`).

# Options

- `--max-maps <n>`: only consider the first `n` maps of the atlas (default 0,
  unlimited).

# Flags

- `--quiet`: suppress the progress bar.
"""
@cast function summarize_map_data(atlas1::String; max_maps::Int = 0, quiet::Bool = false)
    cli("summarize-map-data") do
        max_maps < 0 && error("mapatlas summarize-map-data: --max-maps must be ≥ 0, got $max_maps.")
        show(stdout, MIME"text/plain"(), summarizeMapData(atlas1; max_maps = max_maps, progress = !quiet))
    end
end

"""
Write atlas Atlas1 per-map district assignments to a single wide CSV, named from the Atlas1 basename plus `-assignments.csv` (or `.csv.gz`): one row per map, columns `name` (the map name) then one column per unit holding the district number of that unit in the map. For a single-level atlas the units are its nodes. For a multiscale atlas (whose maps mix whole counties and split ones) the district of each unit is that of the region covering it in each map; the units are the finest units of the dual graph with `--graph`, otherwise the finest regions seen in the atlas.

# Args

- `atlas1`: input atlas (`.jsonl` / `.jsonl.gz` / `.jsonl.bz2`).

# Options

- `--graph <graph.json>`: dual-graph JSON whose finest units (per the `levels in graph` parameter of the atlas) become the columns, e.g. every precinct, including those in counties never split.

# Flags

- `--no-compression`: write plain `.csv` instead of gzip-compressed `.csv.gz`.
- `--force`: overwrite the output file if it already exists (otherwise it is skipped).
- `--quiet`: suppress the progress bar and messages.
- `--keep-partial`: if the command fails partway, keep what it wrote, as OUT.incomplete.EXT, for debugging
  (otherwise nothing is left; an existing output is never replaced by an incomplete one).
"""
@cast function extract_assignments(atlas1::String; graph::String = "",
                                   no_compression::Bool = false, force::Bool = false,
                                   quiet::Bool = false, keep_partial::Bool = false)
    cli("extract-assignments") do
        outpath = stripAtlasExt(atlas1) * "-assignments" * (no_compression ? ".csv" : ".csv.gz")
        r = extractAssignments(atlas1, outpath; graph = isempty(graph) ? nothing : graph, force = force,
                               progress = !quiet, keep_partial = keep_partial)
        if r === nothing
            println("mapatlas extract-assignments: $outpath already exists; pass --force to overwrite.")
        elseif r.nmaps == 0
            println("mapatlas extract-assignments: $atlas1 has no maps; nothing written.")
        elseif !quiet
            isempty(graph) && r.scale !== nothing &&
                println("The maps' node sets differ (a multiscale atlas); using the finest regions seen in the " *
                        "atlas as columns.")
            println("Wrote ", r.nmaps, " map(s) to ", r.path)
            r.scale === nothing ||
                println("Columns (", length(r.units), "): ", replace(r.scale, "graph = <graph.json>" => "--graph"), ".")
        end
    end
end

# Designate this module as the CLI entry point; its `@cast` functions above
# become subcommands, and the root command's help is this module's docstring.
# Qualified because Base also exports `@main` (Julia's script entry point).
Comonicon.@main

end # module
