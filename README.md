# AtlasUtilities

[![CI](https://github.com/jonmjonm/AtlasUtilities.jl/actions/workflows/ci.yml/badge.svg)](https://github.com/jonmjonm/AtlasUtilities.jl/actions/workflows/ci.yml)
[![codecov](https://codecov.io/gh/jonmjonm/AtlasUtilities.jl/graph/badge.svg)](https://codecov.io/gh/jonmjonm/AtlasUtilities.jl)

Tools for working with redistricting **Atlas** files (the map container produced by
the Quantifying Gerrymandering tooling; see the
[Atlas format](https://github.com/jonmjonm/AtlasIO.jl/blob/main/atlas_format.md)),
in two packages that live in this repository:

- **AtlasUtilities** (the repository root): a Julia library, for use from other code.
  See [library.md](library.md). `using CycleWalk` adds the CycleWalk writer statistics.
- **AtlasCLI** ([`AtlasCLI/`](AtlasCLI)): the `mapatlas` command, built on the library.

`mapatlas` has ten subcommands:

| Command | What it does |
|---------|--------------|
| `mapatlas info <atlas> [--extract-script] [--force]` | Print an atlas file's header — the metadata line, the atlas-parameter line, and the data field names found in its first map. The bulky embedded sources (`script`, `script_includes`, `toml_config`) are never printed; `--extract-script` writes each to its own file in the current directory instead. |
| `mapatlas convert <src> <dst> [--to 1\|2] [--quiet]` | Convert an atlas between Atlas format versions 1 and 2 (default `--to 2`), copying everything but the district assignment byte for byte. |
| `mapatlas list-map-data <atlas>` | List the names of the data fields (e.g. `log_spanning_trees`) contained in the atlas's first map, one per line. |
| `mapatlas list-nodes <atlas> [--map k]` | List the node ids in the atlas's k-th map (k=1 by default) as a JSON array of strings. |
| `mapatlas relabel <Atlas1> <Atlas2> [<graph.json>] [--first-map] [--quiet] [--weight-population <pop.json> --population-attr <attr>]` | Relabel district numbers across every map in atlas `Atlas1` so consecutive maps stay as consistent as possible, writing the result to `Atlas2`. |
| `mapatlas add <functions> <Atlas1> <Atlas2> [--config <param.toml>] [column flags] [--overwrite] [--quiet]` / `mapatlas add --list-writers` | Evaluate one or more CycleWalk "pushable writer" functions (e.g. `get_log_spanning_trees`) on every map in `Atlas1` and add the results to the map data, writing to `Atlas2`; `--list-writers` prints the usable writer function names instead. |
| `mapatlas extract-map-data <Atlas1> [--add <functions>] [--no-compression] [--force] [column flags]` | Write each map-data field to its own CSV (one row per map) in a directory named after the atlas; `--add` also computes writer functions to extract. |
| `mapatlas extract-map-data-histogram <Atlas1> [--burn-in n] [--bin-range lo,hi \| --bins edges] [--integer true\|false\|auto] [--add <functions>] [...]` | Accumulate each map-data field into a histogram (one per index for a vector field) and write its bins as CSV and its statistics, density-based counts and moment checks as JSON. |
| `mapatlas summarize-map-data <Atlas1> [--max-maps n]` | Print each map-data field's mean, std and quartiles, and their weighted versions when the map weights vary. |
| `mapatlas extract-assignments <Atlas1> [--graph <graph.json>] [--no-compression] [--force] [--quiet]` | Write a single wide CSV (`name`, then one column per node) with each map's per-node district number; multiscale atlases are written per finest unit (the graph's with `--graph`). |

Run `mapatlas --help` or `mapatlas <subcommand> --help` for full option details.

Everything the commands do is also available from Julia code; see
[library.md](library.md).

## Installation

Both packages need Julia 1.11 or later. One dependency,
[`StreamHistogram`](https://github.com/jonmjonm/StreamHistogram.jl), is not yet in the
Julia General registry, so it is named by URL in `Project.toml`'s `[sources]` table.
Installing straight from GitHub relies on Julia following that table, which Julia 1.13
does; 1.11 and 1.12 are untested that way, so with those work from a clone. Once
StreamHistogram is registered this restriction goes away.

### The library

With Julia 1.13 or later, in the environment of your project:

```bash
julia --project -e 'import Pkg; Pkg.add(url="https://github.com/jonmjonm/AtlasUtilities.jl")'
```

From a clone: `julia --project=. -e 'using Pkg; Pkg.instantiate()'`. The library does
not install CycleWalk; add it (`Pkg.add("CycleWalk")`) for the writer functions.

### The `mapatlas` command

The build step (`AtlasCLI/deps/build.jl`) puts a `mapatlas` launcher in `~/.julia/bin/`
and gives the command its own Julia environment
(`~/.julia/scratchspaces/633115ed-…/env`), with both packages developed into it and
precompiled, plus shell completions (zsh or bash) in `~/.julia/completions`.

**With Julia 1.13 or later**, straight from GitHub. Add **both** packages in one call:
AtlasCLI finds the library next to it in the repository, which an installed copy of
AtlasCLI alone cannot do. `@mapatlas` is a named environment that holds them, kept out
of your default one; Julia runs the build step on install:

```bash
julia --project=@mapatlas -e 'import Pkg; url = "https://github.com/jonmjonm/AtlasUtilities.jl"
    Pkg.add([Pkg.PackageSpec(url = url), Pkg.PackageSpec(url = url, subdir = "AtlasCLI")])'
```

To update later:

```bash
julia --project=@mapatlas -e 'import Pkg; Pkg.update(); Pkg.build("AtlasCLI")'
```

**From a clone** (any supported Julia, and for working on the packages):

```bash
git clone https://github.com/jonmjonm/AtlasUtilities.jl
cd AtlasUtilities.jl
julia --project=AtlasCLI -e 'using Pkg; Pkg.instantiate()'
julia --project=AtlasCLI AtlasCLI/deps/build.jl
```

After `git pull`, rerun the last line.

Then add `~/.julia/bin` to your `PATH` (one time):

```bash
echo 'export PATH="$HOME/.julia/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc
```

Now the command is available:

```bash
mapatlas info some_atlas.jsonl.gz
```

> No system image is built. The launcher uses the Julia that ran the build, or `julia`
> on your `PATH` if that version has since been removed.

**Coming from the `atlas` command** (AtlasUtilities 0.3.2 and earlier): the command is
now `mapatlas`, and `atlas render` and `atlas install-render` are gone for now. Installing
`mapatlas` leaves an old `atlas` in place; remove it with
`rm ~/.julia/bin/atlas ~/.julia/completions/_atlas`.

## Usage

> **`--quiet`** — the map-processing subcommands (`relabel`, `add`,
> `extract-map-data`) show a live progress bar by default; pass `--quiet` to turn
> it off (e.g. for logs or non-interactive runs). `info` prints only a header, so
> it has no progress bar and no `--quiet` flag.

> **A failed run leaves no partial output.** `relabel`, `add`, `extract-map-data`,
> `extract-map-data-histogram` and `extract-assignments` write each file under a
> temporary name and move it into place only when it is complete, so an existing
> output is never replaced by a truncated one. A damaged map in the input is reported
> with its file, line and map number (`cut.jsonl, line 23 (map 20): not a valid Atlas
> map line ...`); look at it with `gzip -dc atlas.jsonl.gz | sed -n 23p`. To debug,
> `--keep-partial` (on `relabel`, `add`, `extract-map-data` and `extract-assignments`)
> keeps what a failed run wrote, as `out.incomplete.jsonl.gz` (or `<field>.incomplete.csv.gz`).

### `mapatlas info`

```bash
mapatlas info examples/cycleWalk_ct_metadata.jsonl.gz
```

Sample atlases ship in [`examples/`](examples) (see [Example atlases](#example-atlases)
below). The command above prints the header metadata and the atlas parameters
(alphabetized, nested values indented). The `cycleWalk_ct_metadata` atlas embeds
its run script in the header — pull it out to its own file with:

```bash
mapatlas info examples/cycleWalk_ct_metadata.jsonl.gz --extract-script
```

The script is written to the filename recorded in the header's `script_name`
entry (falling back to `extracted_script.jl`). A CycleWalk run also embeds the TOML
config it was given (`toml_config`) and the source of every file its script
`include`s (`script_includes`); `--extract-script` writes those out too, under the
names the header records them by.

Every file is written **into the current directory**, under the basename of the
recorded name: a run records its config under the path it was invoked with, which is
usually the live config file, and extraction must not write back over it. A name
already taken in the current directory is left alone and its entry skipped — pass
`--force` to overwrite.

The same metadata is available as data (not just printed text) via the
`atlasInfo` library function — see [library.md](library.md#atlasinfo).

### `mapatlas convert`

```bash
mapatlas convert examples/cycleWalk_ct_slice.jsonl.gz ct_v2.jsonl.gz --to 2
mapatlas convert ct_v2.jsonl.gz ct_v1.jsonl --to 1
```

Converts an atlas between [Atlas format](https://github.com/jonmjonm/AtlasIO.jl/blob/main/atlas_format.md)
versions 1 and 2. v2 stores each map's district assignment as a sorted tree; it is about a third the size of
v1 and faster to read. Only the header's `formatVersion` and each map's assignment are rewritten; the banner,
the atlas parameters and every map's name, weight and data are copied byte for byte, and converting back gives
the same districting for every map. A districting v2 cannot hold (a region assigned both whole and split)
stops the conversion with an error naming the line and map. Reading v2 needs AtlasIO 0.2.1 or later (Python:
AtlasIO.py from v0.2.1, or the `atlasio` package, which has the same converter: `python -m atlasio convert`).

`mapatlas relabel` and `mapatlas add` keep their input's format version: given a v2 atlas they write a v2 atlas.

### `mapatlas list-map-data`

```bash
mapatlas list-map-data examples/cycleWalk_ct_metadata.jsonl.gz
```

Prints the names of the data fields (e.g. `log_spanning_trees`) contained in the
atlas's first map, one per line, sorted. This is the same field list shown in the
"Map Data Fields" section of `mapatlas info` and in the `about.md` written by `mapatlas
extract-map-data`.

### `mapatlas list-nodes`

```bash
mapatlas list-nodes examples/demo_grid_3x3.jsonl.gz
mapatlas list-nodes examples/demo_grid_3x3.jsonl.gz --map 2
```

Prints the node ids in the atlas's k-th map (`k=1` by default; `--map` selects
another 1-based map index) as a sorted JSON array of strings, e.g.
`["n0","n1",...,"n8"]`. For multiscale atlases, whose node ids have more than
one component (e.g. county + tract), each id's components are joined with `:`
(e.g. `"county:tract"`).

### `mapatlas relabel`

```bash
mapatlas relabel examples/demo_grid_4x4.jsonl.gz relabeled.jsonl.gz
```

The `demo_grid_4x4` demo holds the same partition in every map but with the
district labels permuted; `mapatlas relabel` canonicalizes them so map-to-map labels stay
consistent.

- `--first-map` — align every map to map 1 (the anchor) instead of to its
  predecessor.
- `--quiet` — suppress the progress bar.
- A third positional argument is an optional dual-graph hierarchy
  (NetworkX node-link JSON), **required** for multiscale/hierarchical atlases
  whose per-map node sets vary. The `demo_multiscale` example ships with its
  graph:

  ```bash
  mapatlas relabel examples/demo_multiscale.jsonl.gz out.jsonl.gz \
      examples/demo_multiscale_graph.json
  ```

  The real NC multiscale atlases use the precinct graph as their dual graph:

  ```bash
  mapatlas relabel examples/atlas_ordered.jsonl.gz out.jsonl.gz Data/NC_pct21.json
  ```

- `--weight-population <pop.json>` / `--population-attr <attr>` — weight the
  alignment by population instead of raw node counts. `<pop.json>` is a
  node-link JSON (often the same file as the dual graph) whose nodes carry a
  population attribute named by `--population-attr` (e.g. `pop2020cen`); both
  flags are required together:

  ```bash
  mapatlas relabel examples/atlas_ordered.jsonl.gz out.jsonl.gz Data/NC_pct21.json \
      --weight-population Data/NC_pct21.json --population-attr pop2020cen
  ```

  See [`relabel.md`](relabel.md) for the full specification.

## Threading

`relabel`, `add`, and `extract-map-data` process maps in parallel across the
threads Julia was started with (each map is independent; results are written in
input order). For `add` and `extract-map-data --add` the win is large — the
per-map partition reconstruction and writer-function evaluation dominate — while
for `relabel` and plain extraction it speeds up map parsing.

The installed command starts Julia itself, so control the
thread count with the `JULIA_NUM_THREADS` environment variable, e.g.:

```bash
JULIA_NUM_THREADS=8 mapatlas add get_log_spanning_trees Atlas1.jsonl.gz Atlas2.jsonl.gz --config param.toml
JULIA_NUM_THREADS=8 mapatlas relabel input.jsonl.gz relabeled.jsonl.gz
JULIA_NUM_THREADS=8 mapatlas extract-map-data run.jsonl.gz --add get_log_spanning_trees --config param.toml
```

Threaded and serial runs agree to machine precision. They are not bitwise
identical, because CycleWalk reconstructs each map's partition from a fresh random
spanning tree, so a few floating-point sums (e.g. in `get_isoperimetric_scores`)
land in a different order — an inherent ~1e-15 difference that also appears
between two serial runs, not an artifact of threading.

### `mapatlas add`

Add one or more CycleWalk **pushable writer functions** to every map in an atlas.
These are the same functions you would hand to `push_writer!` during a CycleWalk
run — for example `get_log_spanning_trees`, `get_log_spanning_forests`, or
`get_isoperimetric_scores`. Each is evaluated on every map and its result is
stored in the map's data under the function's name, exactly as CycleWalk does
when it writes out the data:

```bash
mapatlas add get_log_spanning_trees Atlas1.jsonl.gz Atlas2.jsonl.gz --config param.toml
```

Not sure which writer names are available? `--list-writers` prints every usable
CycleWalk writer function (and exits — `functions`/`Atlas1`/`Atlas2` aren't required with
this flag). "Usable" is checked, not assumed: each candidate is smoke-tested against
a real reconstructed partition, so a writer that merely has a matching method
signature but errors when actually called (e.g. an internal bug referencing an
undefined name) is left off the list:

```bash
mapatlas add --list-writers
```

Pass a single name, a comma-separated list, or a bracketed list to add several in
one pass:

```bash
mapatlas add "get_log_spanning_trees,get_isoperimetric_scores" Atlas1.jsonl.gz Atlas2.jsonl.gz --config param.toml
```

Because a CycleWalk atlas stores only districtings (not the graph), the **dual
graph the atlas was sampled on must be supplied** so each map's partition can be
rebuilt. Give it either as a CycleWalk TOML config (its `[plans]` table provides
the graph path and column names) or with explicit column flags — or a mix, where
a flag overrides / fills in the TOML:

```bash
mapatlas add get_isoperimetric_scores Atlas1.jsonl.gz Atlas2.jsonl.gz \
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
mapatlas add get_isoperimetric_scores Atlas1.jsonl.gz Atlas2.jsonl.gz \
  --config param.toml --pop-col TOTPOP
```

`--node-data` keeps extra node attributes on the reconstructed graph so writers
that read them (or downstream analysis of the extracted CSVs) can see them —
for example, carrying the county each node belongs to:

```bash
mapatlas add get_isoperimetric_scores Atlas1.jsonl.gz Atlas2.jsonl.gz \
  --graph NC_pct21.json --pop-col POP20 --node-col NAME \
  --area-col area --border-col border_length --edge-perimeter-col length \
  --node-data COUNTY
```

By default it is an error for a requested field to already exist on a map; pass
`--overwrite` to recompute it instead, e.g. after fixing a bug in a writer:

```bash
mapatlas add get_isoperimetric_scores Atlas1.jsonl.gz Atlas2.jsonl.gz \
  --graph NC_pct21.json --pop-col POP20 --node-col NAME --overwrite
```

The output atlas's header records an
`"added map data"` provenance entry (visible in `mapatlas info`) listing the added
fields, the graph used, and the date; adding fields does not change the map data
type (`Dict{String,Any}`), so the atlas stays readable by any existing reader.

#### Partisan writers (vote margins / seats)

The writers `get_partisan_margins` (each district's first-party two-party vote
share, `100·votes1/(votes1+votes2)`) and `get_partisan_seats` (count of districts
the first party wins) are parameterized by a pair of vote columns, supplied with
`--vote-cols` (columns your graph JSON must carry). Give one or more `votes1,votes2`
pairs separated by `;`:

```bash
mapatlas add get_partisan_margins run.jsonl.gz out.jsonl.gz \
  --graph NC_pct21.json --pop-col TOTPOP --node-col NAME \
  --vote-cols "G20_PR_D,G20_PR_R;G16_PR_D,G16_PR_R"
```

Each pair adds its own field `get_partisan_margins_<votes1>_<votes2>` (here two
fields, one per election); the vote columns are kept on the graph automatically. The
same `--add get_partisan_margins --vote-cols …` works for `mapatlas extract-map-data`,
writing one CSV per expanded field.

### `mapatlas extract-map-data`

Write the per-map data of an atlas to CSV — one file per data field:

```bash
mapatlas extract-map-data cycleWalk_ct_slice.jsonl.gz
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

Each map is one row. The first column is the map name, then the field's value — a
scalar is a single column, a vector is one column per entry — and last the map's
weight, under a header row
(`name,get_isoperimetric_scores_1,get_isoperimetric_scores_2,…,map_weight`).

`about.md` describes the extraction: the source atlas name, the extraction date, and
the atlas's header information — everything [`mapatlas info`](#mapatlas-info) prints except
the bulky embedded generating script.

Output is gzip-compressed by default; `--no-compression` writes plain `.csv`. A
field whose output file already exists is **skipped**; pass `--force` to overwrite.
One stream is kept open per file for the whole pass, so each file is opened once.

`--add` additionally computes CycleWalk pushable writer functions (fields that may
not be in the atlas yet) and extracts them alongside the existing data, using the
same graph inputs as [`mapatlas add`](#mapatlas-add):

```bash
mapatlas extract-map-data run.jsonl.gz --add get_log_spanning_trees --config param.toml
mapatlas extract-map-data run.jsonl.gz \
  --add "get_log_spanning_trees,get_isoperimetric_scores" \
  --graph NC_pct21.json --pop-col POP20 --node-col NAME \
  --area-col area --border-col border_length --edge-perimeter-col length
```

Without `--add`, no graph is needed — it simply streams the maps and dumps their
existing data.

### `mapatlas extract-map-data-histogram` and `mapatlas summarize-map-data`

```bash
mapatlas extract-map-data-histogram cycleWalk_ct_slice.jsonl.gz
mapatlas summarize-map-data cycleWalk_ct_slice.jsonl.gz
```

`extract-map-data-histogram` accumulates each map-data field into a
[StreamHistogram](https://github.com/jonmjonm/StreamHistogram.jl) (one per index
for a vector field, each map's vector sorted first unless `--no-sort`) and writes,
in the directory `extract-map-data` uses, a pair of files per field:

- `<field>-histogram.csv.gz`: `index,edge_lo,edge_hi,exact_count,weight_sum`, the
  exact bins: the number of maps in each bin and the sum of their weights;
- `<field>-histogram.json.gz`: per index, the summary statistics (`nobs`,
  `exact_min`/`exact_max`, `mean`, `std`, ...), the values outside the range
  (`underflow`, `overflow`), the ASH density's expected count per bin
  (`ash_count`), how well its moments match the exact ones (`relerr_moments`), and
  the bin edges.

`summarize-map-data` prints each field's mean, std and `[min, 25%, median, 75%,
max]` instead, with warnings when many values fall outside the histogram range or
a quartile disagrees with the density.

**Map weights.** Each value is counted both once and with its map's weight, so
weighted ensembles (e.g. importance-sampled CycleWalk runs) get weighted results
without changing the unweighted ones. The JSON adds `total_weight`,
`effective_sample_size` (Kish's `(Σw)²/Σw²`: how many equally weighted maps the
sample is worth), `underflow_weight`/`overflow_weight`, `weighted_mean`,
`weighted_std`, ..., `weighted_relerr_moments` and `ash_weight`. When the weights
vary, `summarize-map-data` adds the weighted mean, std and quartiles with the
effective sample size. A negative or non-finite weight is an error naming the map.

### `mapatlas extract-assignments`

```bash
mapatlas extract-assignments examples/demo_grid_3x3.jsonl.gz
```

Writes a single wide CSV named after the atlas (its path with the `.jsonl` /
`.jsonl.gz` / `.jsonl.bz2` extension removed, plus `-assignments` — e.g.
`demo_grid_3x3-assignments.csv.gz`): one row per map, first column `name` (the
map name), remaining columns one per node, sorted, holding that node's district
number in the map:

```
name,n0,n1,n2,n3,n4,n5,n6,n7,n8
map1,1,1,1,2,2,2,3,3,3
map2,3,3,3,1,1,1,2,2,2
```

**Multiscale atlases** (whose maps keep some counties whole and split others into
precincts) are written at the finest scale: one column per finest unit, holding
the district of the region that covers it in each map — the precinct itself where
its county is split, the whole county where it is not. A node id with several
components is written joined with `:` (e.g. `MECKLENBURG:052`), as `list-nodes`
does. Which units become columns:

- With `--graph <graph.json>`, the dual graph's finest units, read with the
  atlas's `levels in graph` parameter (as `mapatlas relabel` does). This is the true
  finest scale: every precinct, including those in counties that no map splits.

  ```bash
  mapatlas extract-assignments examples/demo_multiscale.jsonl.gz --graph examples/demo_multiscale_graph.json
  ```

- Without a graph, the finest regions seen anywhere in the atlas: a county that no
  map splits stays a single column. The command says so when it switches to this
  (it reads the atlas a second time to collect every region).

A single-level atlas (every map has the same nodes) is written exactly as before
and read only once.

Output is gzip-compressed by default; `--no-compression` writes plain `.csv`.
The output file is **skipped** if it already exists; pass `--force` to
overwrite. A map that leaves a unit uncovered, or (with `--graph`) uses a node the
graph does not have, stops the command with an error naming the map and node, and
no partial output file is left behind.

## Example atlases

All files below live in [`examples/`](examples) and are gzip-compressed.

| File | Maps | Description |
|------|-----:|-------------|
| `cycleWalk_ct_metadata.jsonl.gz` | few | A real CycleWalk **CT** run whose header embeds its run script — use it with `mapatlas info --extract-script`. |
| `cycleWalk_ct_slice.jsonl.gz` | 41 | A short real CycleWalk **CT** run (5 districts) whose maps carry the writer fields; paired with `Data/CT_pct20.json` it is the `mapatlas add` oracle fixture (recomputed values reproduce CycleWalk's own to machine precision). |
| `demo_grid_4x4.jsonl.gz` | 6 | Toy 4×4 grid, 4 districts, same partition with permuted labels — shows `mapatlas relabel` canonicalization. |
| `demo_grid_3x3.jsonl.gz` | 4 | Toy 3×3 grid, 3 row districts, permuted labels across four maps. |
| `demo_multiscale.jsonl.gz` (+ `demo_multiscale_graph.json`) | 3 | Tiny mixed-resolution atlas + its dual graph — shows graph-based relabeling. |
| `atlas_ordered.jsonl.gz`, `atlas_measureID12.jsonl.gz` | 100 | **NC** multiscale atlases (county/precinct levels, 14 districts). Relabel with `Data/NC_pct21.json` as the dual graph. |
| `cycleWalk_v0p2_thread3_walkVSinternal_0.01_gamma0.5.jsonl.gz`, `…_iso0.15.jsonl.gz` | 100 | **NC** single-resolution CycleWalk atlases (14 districts). Relabel directly, no graph needed. |

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
julia --project=AtlasCLI --threads=8 -e 'using AtlasCLI; AtlasCLI.command_main()' -- \
    relabel input.jsonl.gz relabeled.jsonl.gz --quiet
```

## Development

```bash
julia --project=. -e 'using Pkg; Pkg.test()'          # the library
julia --project=AtlasCLI -e 'using Pkg; Pkg.test()'   # the command
```

The library tests run first without CycleWalk, then the tests in `test/process/` load it.
Both packages run [Aqua](https://github.com/JuliaTesting/Aqua.jl) quality checks, and CI
reports their coverage to Codecov separately, running each suite on 1 and on 4 threads.

The command tests include snapshot tests (`AtlasCLI/test/snapshotTests.jl`): every subcommand
is run on the example atlases, in format v1 and v2, and what it prints is compared with
`AtlasCLI/test/snapshots/printed/`, and a fingerprint of every file it writes with
`snapshots/fingerprints.txt`. After an intended change to what a command prints or writes,
rewrite them and review the diff:

```bash
UPDATE_SNAPSHOTS=1 julia --project=AtlasCLI -e 'using Pkg; Pkg.test()'
```

## Repository layout

```
src/                    the AtlasUtilities library
ext/AtlasUtilitiesCycleWalkExt/
                        CycleWalk writers, loaded by `using CycleWalk`
test/                   library tests (test/process/: the CycleWalk ones)
AtlasCLI/src/           the `mapatlas` commands
AtlasCLI/deps/build.jl  installs the `mapatlas` launcher, its environment and completions
AtlasCLI/test/          command tests
examples/               sample atlases (+ make_demos.jl that generates them)
relabel.md              relabel command / findRelabeling algorithm spec
library.md              API reference of the library
docs/refactor-plan.md   plan of the library / command split
```
