# AtlasUtilities

Command-line utilities for working with redistricting **Atlas** files (the map
container produced by the Quantifying Gerrymandering tooling; see the
[Atlas format](https://github.com/jonmjonm/AtlasIO.jl/blob/main/atlas_format.md)).

The package installs a single `atlas` command with seven subcommands:

| Command | What it does |
|---------|--------------|
| `atlas info <atlas> [--extract-script]` | Print an atlas file's header — the metadata line, the atlas-parameter line, and the data field names found in its first map. The bulky embedded `script` source is never printed; `--extract-script` writes it to its own file instead. |
| `atlas list-map-data <atlas>` | List the names of the data fields (e.g. `log_spanning_trees`) contained in the atlas's first map, one per line. |
| `atlas list-nodes <atlas> [--map k]` | List the node ids in the atlas's k-th map (k=1 by default) as a JSON array of strings. |
| `atlas relabel <Atlas1> <Atlas2> [<graph.json>] [--first-map] [--quiet]` | Relabel district numbers across every map in atlas `Atlas1` so consecutive maps stay as consistent as possible, writing the result to `Atlas2`. |
| `atlas add <functions> <Atlas1> <Atlas2> [--config <param.toml>] [column flags] [--overwrite] [--quiet]` / `atlas add --list-writers` | Evaluate one or more CycleWalk "pushable writer" functions (e.g. `get_log_spanning_trees`) on every map in `Atlas1` and add the results to the map data, writing to `Atlas2`; `--list-writers` prints the usable writer function names instead. |
| `atlas extract-map-data <Atlas1> [--add <functions>] [--no-compression] [--force] [column flags]` | Write each map-data field to its own CSV (one row per map) in a directory named after the atlas; `--add` also computes writer functions to extract. |
| `atlas extract-assignments <Atlas1> [--no-compression] [--force] [--quiet]` | Write a single wide CSV (`name`, then one column per node) with each map's per-node district number; errors on multiscale atlases. |

Run `atlas --help` or `atlas <subcommand> --help` for full option details.

## Installation

`atlas` is built with [Comonicon](https://comonicon.org). Installing the package
runs a build step that drops an `atlas` launcher into `~/.julia/bin/` and
compiles a system image so the command starts fast.

### Install from GitHub

Install directly from the GitHub repository with Julia's package manager — this
clones the package, resolves its dependencies from the General registry, and runs
the build step that installs the `atlas` command:

```julia
julia -e 'using Pkg; Pkg.add(url="https://github.com/jonmjonm/AtlasUtilities.jl")'
```

Equivalently, from the Julia REPL package mode (press `]`):

```julia-repl
pkg> add https://github.com/jonmjonm/AtlasUtilities.jl
```

To pin a specific version or branch, append `#tag`/`#branch` to the URL (e.g.
`…/AtlasUtilities.jl#v0.1.0`). To update later, `Pkg.update("AtlasUtilities")`.

Then add `~/.julia/bin` to your `PATH` (one time):

```bash
echo 'export PATH="$HOME/.julia/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc
```

Now the command is available:

```bash
atlas info some_atlas.jsonl.gz
```

> The first install compiles a system image and takes a few minutes. All
> dependencies (including `AtlasIO`) resolve from the Julia General registry.

### Installing from a local clone (development)

```bash
git clone https://github.com/jonmjonm/AtlasUtilities.jl
cd AtlasUtilities.jl
julia --project -e 'using Pkg; Pkg.instantiate()'
julia --project deps/build.jl        # installs the `atlas` launcher + sysimg
```

## Usage

> **`--quiet`** — the map-processing subcommands (`relabel`, `add`,
> `extract-map-data`) show a live progress bar by default; pass `--quiet` to turn
> it off (e.g. for logs or non-interactive runs). `info` prints only a header, so
> it has no progress bar and no `--quiet` flag.

### `atlas info`

```bash
atlas info examples/cycleWalk_ct_metadata.jsonl.gz
```

Sample atlases ship in [`examples/`](examples) (see [Example atlases](#example-atlases)
below). The command above prints the header metadata and the atlas parameters
(alphabetized, nested values indented). The `cycleWalk_ct_metadata` atlas embeds
its run script in the header — pull it out to its own file with:

```bash
atlas info examples/cycleWalk_ct_metadata.jsonl.gz --extract-script
```

The script is written to the filename recorded in the header's `script_name`
entry (falling back to `extracted_script.jl`).

### `atlas list-map-data`

```bash
atlas list-map-data examples/cycleWalk_ct_metadata.jsonl.gz
```

Prints the names of the data fields (e.g. `log_spanning_trees`) contained in the
atlas's first map, one per line, sorted. This is the same field list shown in the
"Map Data Fields" section of `atlas info` and in the `about.md` written by `atlas
extract-map-data`.

### `atlas list-nodes`

```bash
atlas list-nodes examples/demo_grid_3x3.jsonl.gz
atlas list-nodes examples/demo_grid_3x3.jsonl.gz --map 2
```

Prints the node ids in the atlas's k-th map (`k=1` by default; `--map` selects
another 1-based map index) as a sorted JSON array of strings, e.g.
`["n0","n1",...,"n8"]`. For multiscale atlases, whose node ids have more than
one component (e.g. county + tract), each id's components are joined with `:`
(e.g. `"county:tract"`).

### `atlas relabel`

```bash
atlas relabel examples/demo_grid_4x4.jsonl.gz relabeled.jsonl.gz
```

The `demo_grid_4x4` demo holds the same partition in every map but with the
district labels permuted; `atlas relabel` canonicalizes them so map-to-map labels stay
consistent.

- `--first-map` — align every map to map 1 (the anchor) instead of to its
  predecessor.
- `--quiet` — suppress the progress bar.
- A third positional argument is an optional dual-graph hierarchy
  (NetworkX node-link JSON), **required** for multiscale/hierarchical atlases
  whose per-map node sets vary. The `demo_multiscale` example ships with its
  graph:

  ```bash
  atlas relabel examples/demo_multiscale.jsonl.gz out.jsonl.gz \
      examples/demo_multiscale_graph.json
  ```

  The real NC multiscale atlases use the precinct graph as their dual graph:

  ```bash
  atlas relabel examples/atlas_ordered.jsonl.gz out.jsonl.gz Data/NC_pct21.json
  ```

  See [`relabel.md`](relabel.md) for the full specification.

## Threading

`relabel`, `add`, and `extract-map-data` process maps in parallel across the
threads Julia was started with (each map is independent; results are written in
input order). For `add` and `extract-map-data --add` the win is large — the
per-map partition reconstruction and writer-function evaluation dominate — while
for `relabel` and plain extraction it speeds up map parsing.

Because the installed command runs on the Comonicon system image, control the
thread count with the `JULIA_NUM_THREADS` environment variable, e.g.:

```bash
JULIA_NUM_THREADS=8 atlas add get_log_spanning_trees Atlas1.jsonl.gz Atlas2.jsonl.gz --config param.toml
JULIA_NUM_THREADS=8 atlas relabel input.jsonl.gz relabeled.jsonl.gz
JULIA_NUM_THREADS=8 atlas extract-map-data run.jsonl.gz --add get_log_spanning_trees --config param.toml
```

Threaded and serial runs agree to machine precision. They are not bitwise
identical, because CycleWalk reconstructs each map's partition from a fresh random
spanning tree, so a few floating-point sums (e.g. in `get_isoperimetric_scores`)
land in a different order — an inherent ~1e-15 difference that also appears
between two serial runs, not an artifact of threading.

### `atlas add`

Add one or more CycleWalk **pushable writer functions** to every map in an atlas.
These are the same functions you would hand to `push_writer!` during a CycleWalk
run — for example `get_log_spanning_trees`, `get_log_spanning_forests`, or
`get_isoperimetric_scores`. Each is evaluated on every map and its result is
stored in the map's data under the function's name, exactly as CycleWalk does
when it writes out the data:

```bash
atlas add get_log_spanning_trees Atlas1.jsonl.gz Atlas2.jsonl.gz --config param.toml
```

Not sure which writer names are available? `--list-writers` prints every usable
CycleWalk writer function (and exits — `functions`/`Atlas1`/`Atlas2` aren't required with
this flag). "Usable" is checked, not assumed: each candidate is smoke-tested against
a real reconstructed partition, so a writer that merely has a matching method
signature but errors when actually called (e.g. an internal bug referencing an
undefined name) is left off the list:

```bash
atlas add --list-writers
```

Pass a single name, a comma-separated list, or a bracketed list to add several in
one pass:

```bash
atlas add "get_log_spanning_trees,get_isoperimetric_scores" Atlas1.jsonl.gz Atlas2.jsonl.gz --config param.toml
```

Because a CycleWalk atlas stores only districtings (not the graph), the **dual
graph the atlas was sampled on must be supplied** so each map's partition can be
rebuilt. Give it either as a CycleWalk TOML config (its `[plans]` table provides
the graph path and column names) or with explicit column flags — or a mix, where
a flag overrides / fills in the TOML:

```bash
atlas add get_isoperimetric_scores Atlas1.jsonl.gz Atlas2.jsonl.gz \
  --graph NC_pct21.json --pop-col POP20 --node-col NAME \
  --area-col area --border-col border_length --edge-perimeter-col length
```

The graph columns are: `--pop-col` (population), `--node-col` (the node id column
that districting keys use), `--area-col`, `--border-col` (node border length),
`--edge-perimeter-col` (shared-edge perimeter), and `--node-data` (a
comma-separated list of extra node attributes to keep). From a `--config`, these
come from the `[plans]` keys `pop_col`, `geo_units`, `area_col`,
`node_border_col`, `edge_perimeter_col`, and `node_data`, with the graph path
built from `map_directory` + `map_file`.

A flag overrides / fills in the same key from `--config`, so you can start from a
run's TOML and swap in just the piece that's different — e.g. reuse `param.toml`'s
graph and columns but point at a different population column:

```bash
atlas add get_isoperimetric_scores Atlas1.jsonl.gz Atlas2.jsonl.gz \
  --config param.toml --pop-col TOTPOP
```

`--node-data` keeps extra node attributes on the reconstructed graph so writers
that read them (or downstream analysis of the extracted CSVs) can see them —
for example, carrying the county each node belongs to:

```bash
atlas add get_isoperimetric_scores Atlas1.jsonl.gz Atlas2.jsonl.gz \
  --graph NC_pct21.json --pop-col POP20 --node-col NAME \
  --area-col area --border-col border_length --edge-perimeter-col length \
  --node-data COUNTY
```

By default it is an error for a requested field to already exist on a map; pass
`--overwrite` to recompute it instead, e.g. after fixing a bug in a writer:

```bash
atlas add get_isoperimetric_scores Atlas1.jsonl.gz Atlas2.jsonl.gz \
  --graph NC_pct21.json --pop-col POP20 --node-col NAME --overwrite
```

The output atlas's header records an
`"added map data"` provenance entry (visible in `atlas info`) listing the added
fields, the graph used, and the date; adding fields does not change the map data
type (`Dict{String,Any}`), so the atlas stays readable by any existing reader.

#### Partisan writers (vote margins / seats)

The writers `get_partisan_margins` (each district's first-party two-party vote
share, `100·votes1/(votes1+votes2)`) and `get_partisan_seats` (count of districts
the first party wins) are parameterized by a pair of vote columns, supplied with
`--vote-cols` (columns your graph JSON must carry). Give one or more `votes1,votes2`
pairs separated by `;`:

```bash
atlas add get_partisan_margins run.jsonl.gz out.jsonl.gz \
  --graph NC_pct21.json --pop-col TOTPOP --node-col NAME \
  --vote-cols "G20_PR_D,G20_PR_R;G16_PR_D,G16_PR_R"
```

Each pair adds its own field `get_partisan_margins_<votes1>_<votes2>` (here two
fields, one per election); the vote columns are kept on the graph automatically. The
same `--add get_partisan_margins --vote-cols …` works for `atlas extract-map-data`,
writing one CSV per expanded field.

### `atlas extract-map-data`

Write the per-map data of an atlas to CSV — one file per data field:

```bash
atlas extract-map-data cycleWalk_ct_slice.jsonl.gz
```

This creates a directory named after the atlas (its path with the `.jsonl` /
`.jsonl.gz` / `.jsonl.bz2` extension removed — e.g. `cycleWalk_ct_slice/`) and
writes one CSV per field found in the map data, plus an `about.md`:

```
cycleWalk_ct_slice/
  about.md
  get_log_spanning_trees.csv.gz
  get_log_spanning_forests.csv.gz
  get_isoperimetric_scores.csv.gz
```

Each map is one row. The first column is the map name; the remaining columns are
the field's value — a scalar is a single column, a vector is one column per entry
— under a header row (`name,get_isoperimetric_scores_1,get_isoperimetric_scores_2,…`).

`about.md` describes the extraction: the source atlas name, the extraction date, and
the atlas's header information — everything [`atlas info`](#atlas-info) prints except
the bulky embedded generating script.

Output is gzip-compressed by default; `--no-compression` writes plain `.csv`. A
field whose output file already exists is **skipped**; pass `--force` to overwrite.
One stream is kept open per file for the whole pass, so each file is opened once.

`--add` additionally computes CycleWalk pushable writer functions (fields that may
not be in the atlas yet) and extracts them alongside the existing data, using the
same graph inputs as [`atlas add`](#atlas-add):

```bash
atlas extract-map-data run.jsonl.gz --add get_log_spanning_trees --config param.toml
atlas extract-map-data run.jsonl.gz \
  --add "get_log_spanning_trees,get_isoperimetric_scores" \
  --graph NC_pct21.json --pop-col POP20 --node-col NAME \
  --area-col area --border-col border_length --edge-perimeter-col length
```

Without `--add`, no graph is needed — it simply streams the maps and dumps their
existing data.

### `atlas extract-assignments`

```bash
atlas extract-assignments examples/demo_grid_3x3.jsonl.gz
```

Writes a single wide CSV named after the atlas (its path with the `.jsonl` /
`.jsonl.gz` / `.jsonl.bz2` extension removed, plus `-assignments` — e.g.
`demo_grid_3x3-assignments.csv.gz`): one row per map, first column `name` (the
map name), remaining columns one per node — the sorted node ids found in the
first map — holding that node's district number in the map:

```
name,n0,n1,n2,n3,n4,n5,n6,n7,n8
map1,1,1,1,2,2,2,3,3,3
map2,3,3,3,1,1,1,2,2,2
```

Output is gzip-compressed by default; `--no-compression` writes plain `.csv`.
The output file is **skipped** if it already exists; pass `--force` to
overwrite. Every map must have exactly the first map's node set — **multiscale
atlases are not supported yet** and produce an error (with no partial output
file left behind).

## Example atlases

All files below live in [`examples/`](examples) and are gzip-compressed.

| File | Maps | Description |
|------|-----:|-------------|
| `cycleWalk_ct_metadata.jsonl.gz` | few | A real CycleWalk **CT** run whose header embeds its run script — use it with `atlas info --extract-script`. |
| `cycleWalk_ct_slice.jsonl.gz` | 41 | A short real CycleWalk **CT** run (5 districts) whose maps carry the writer fields; paired with `Data/CT_pct20.json` it is the `atlas add` oracle fixture (recomputed values reproduce CycleWalk's own to machine precision). |
| `demo_grid_4x4.jsonl.gz` | 6 | Toy 4×4 grid, 4 districts, same partition with permuted labels — shows `atlas relabel` canonicalization. |
| `demo_grid_3x3.jsonl.gz` | 4 | Toy 3×3 grid, 3 row districts, permuted labels across four maps. |
| `demo_multiscale.jsonl.gz` (+ `demo_multiscale_graph.json`) | 3 | Tiny mixed-resolution atlas + its dual graph — shows graph-based relabeling. |
| `atlas_ordered.jsonl.gz`, `atlas_measureID12.jsonl.gz` | 100 | **NC** multiscale atlases (county/precinct levels, 14 districts). Reorder with `Data/NC_pct21.json` as the dual graph. |
| `cycleWalk_v0p2_thread3_walkVSinternal_0.01_gamma0.5.jsonl.gz`, `…_iso0.15.jsonl.gz` | 100 | **NC** single-resolution CycleWalk atlases (14 districts). Reorder directly, no graph needed. |

The toy grid/multiscale demos are generated by
[`examples/make_demos.jl`](examples/make_demos.jl). The `demo_grid_*` and
`demo_multiscale` files are self-contained. The four **NC** atlases are the first
100 maps of full CycleWalk runs (the complete multi-hundred-MB atlases live in the
Duke GitLab `Data/` directory); they were sliced with:

```bash
gzip -dc full_atlas.jsonl.gz | head -n 103 | gzip -c > examples/slice.jsonl.gz
```

(3 header lines + 100 map lines = 103.)

## Running from source without installing

You can also drive the commands directly through the package without installing
the launcher:

```bash
julia --project=. --threads=8 -e 'using AtlasUtilities; AtlasUtilities.command_main()' -- \
    relabel input.jsonl.gz relabeled.jsonl.gz --quiet
```

## Development

```bash
julia --project=. -e 'using Pkg; Pkg.test()'
```

The suite covers the relabel logic (`test/runtests.jl`) and the info formatting
and extraction (`test/infoTests.jl`).

## Repository layout

```
src/AtlasUtilities.jl   module + Comonicon @cast subcommands (the CLI surface)
src/info.jl             `atlas info` implementation
src/reorder.jl          `atlas relabel` implementation
deps/build.jl           Comonicon install (launcher + sysimg)
deps/precompile.jl      exercises both subcommands while the sysimg is built
test/                   test suite
examples/               sample atlases (+ make_demos.jl that generates them)
relabel.md              relabel command / reOrder algorithm spec
```
