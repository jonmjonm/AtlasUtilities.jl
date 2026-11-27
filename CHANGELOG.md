# Changelog

## [0.4.0]

**Breaking.** AtlasUtilities is now a library, and the command is a separate package, AtlasCLI (in `AtlasCLI/`), first released as 0.1.0.

### Atlas output

- The `"added map data"` header entry now reads `"by": "addMapData"` (was `"atlas add"`) and records the
  AtlasUtilities `version`. Entries already in an atlas are left as they are.
- The `about.md` of `extract-map-data` names `mapatlas info`.

### The command

- **Renamed from `atlas` to `mapatlas`** (`atlas` collides with MongoDB's command). Its subcommands, options and
  output files are otherwise unchanged; messages name `mapatlas`.
- Installed from AtlasCLI (see README.md). An old `atlas` launcher is left in place: remove it with
  `rm ~/.julia/bin/atlas ~/.julia/completions/_atlas`.
- **`render` and `install-render` are removed** (plotting is being redesigned; the code is on the `pre-refactor`
  branch), with `render_map`, `run_render` and `districtColors`.
- The zsh completion script no longer fails to parse (apostrophes in help text left it unbalanced).
- Some error messages are reworded: each names `mapatlas <command>` and its flags.

### The library

- The `run_*` drivers are gone. In their place are exported functions that print nothing and return what they did:
  `relabelAtlas`, `listNodes`, `extractScripts`, `addMapData`, `extractMapData`, `writeHistograms`,
  `summarizeMapData` (a `MapDataSummary` of `FieldSummary`s, both
  exported; displayed, it gives the command's text, and printed, one line) and `extractAssignments`.
  `convert` is AtlasIO's `convertAtlas`. See library.md.
- **Changed keywords:** `quiet = false` is now `progress = false` (silent by default), `sortVals` is `sort_values`,
  and the `add` and graph keywords of `extractMapData`/`mapDataHistograms` are now `writers = WriterSet(...)`.
- **`WriterSet` takes typed arguments:** a vector of names (or one name), not a comma-separated string;
  `vote_cols` as `(votes1, votes2)` pairs; `node_data` as a vector. Graph keywords default to `nothing`.
- **CycleWalk is a weak dependency.** `using AtlasUtilities` no longer loads it; `using CycleWalk` switches on
  the extension holding `addMapData`, `computeWriters`, `listWriters` and the `WriterSet` constructor, and calling
  them without it says so. `WriterSet`, `writerFields` and their types stay in the library.
- **No partial output on failure.** `relabelAtlas`, `addMapData`, `extractMapData`, `writeHistograms` and
  `extractAssignments` write each file under a temporary name and move it into place only when it is complete:
  a run that fails (a damaged map, a writer error) leaves an existing output as it was and no truncated file that
  a rerun would skip as done. An output atlas may now be its input (`mapatlas relabel a.jsonl.gz a.jsonl.gz`).
  `keep_partial = true` (`--keep-partial`) keeps what a failed run wrote, as `out.incomplete.jsonl.gz`, for
  debugging: every map before the one that failed.
- **A damaged map is located.** Its `AtlasFormatError` names the file, line and map
  (`cut.jsonl, line 23 (map 20): not a valid Atlas map line ...`); before, it said neither.
- New `public` (not exported) names: `nodeIdString`, `atlasHeaderInfo`, `listWriterDetails`, `loadGraph`.
- Comonicon and Pkg are no longer dependencies.
- **Julia 1.11 or later** (was 1.10).

### Development

- Tests are split between the packages; the library tests run without CycleWalk, then the CycleWalk ones.
- Aqua checks, and CI jobs with Codecov coverage for both packages.

## [0.3.2]

Everything since 0.3.1, which was the last version installed (none of 0.3.2–0.4.0 was released; they are folded in
here).

### Library API

- **`WriterSet` and `computeWriters`**: CycleWalk writer statistics computed on maps in memory, the library form
  of `atlas add`. `WriterSet(functions; graph keywords or config, vote_cols)` resolves the writers and builds the
  graph once; `computeWriters(ws, m)` returns each field's value in the map's own district numbering, and
  `computeWriters(ws, maps)` does a vector of maps in parallel. `writerFields(ws)` lists the fields (partisan
  writers expanded per vote pair), `listWriters()` the accepted names. Error messages shared with `atlas add` now
  name both the flag and the keyword (e.g. `--graph (graph =)`).
- **`assignmentMatrix(atlas; graph)`**: the district assignments as data instead of a CSV: map names, weights,
  the units (as node keys and as `extract-assignments` column names) and a maps × units matrix of district numbers.
  It uses the same units as `atlas extract-assignments` (now built on it), multiscale atlases and `graph`
  included.
- `mapDataHistograms` is documented in library.md, with the weighted statistics.
- Quantile estimates moved to StreamHistogram (`quantile`, `weightedQuantile`); `histQuantile` is gone.
  `summarize-map-data` prints the same values, except that integer-valued histograms now give the bin's integer
  instead of a value interpolated across it.

### Installing the `atlas` command

- `deps/build.jl` builds the command's environment in a new directory and swaps it in only on success: a failed
  build used to delete the environment first, leaving `atlas` broken and its plotting packages gone.
- The build ignores the checkout's own `Manifest.toml` (not in git) while it resolves. A stale one pinned
  StreamHistogram, which the checkout gets by URL, to an old commit, so the build failed or installed an old
  version. The manifest is put back unchanged.
- CI's install job builds again when the launcher is missing, and fails on a failed build.

### Map weights

`extract-map-data-histogram`, `summarize-map-data` and `extract-map-data` use each map's weight,
for weighted ensembles such as CycleWalk's importance-sampled atlases. Every unweighted result is unchanged: each
value is counted both once and with its map's weight.

- `extract-map-data-histogram`:
  - the CSV gains a last column, `weight_sum`: each bin's sum of map weights, next to `exact_count`;
  - the JSON gains, per histogram: `total_weight`, `effective_sample_size` (Kish's `(Σw)²/Σw²`),
    `underflow_weight` and `overflow_weight`, `weighted_mean`, `weighted_variance`, `weighted_std`,
    `weighted_skewness`, `weighted_excess_kurtosis`, `weighted_relerr_moments` and `ash_weight` (the weighted ASH
    density's expected weight per bin, next to `ash_count`).
- `summarize-map-data`: when the maps' weights vary, each field also gets the weighted mean, std and quartiles,
  with its effective sample size and the same warnings. Unweighted atlases (or equal weights) print what they
  did before.
- `extract-map-data`: every CSV gains a last column, `map_weight`, so existing
  readers see the field columns where they were.
- A map whose weight is negative or not finite stops these commands with an error naming the map.
- **Breaking: the JSON's `kurtosis` field is now `excess_kurtosis`**, the kurtosis minus 3 (0 for a normal), as
  StreamHistogram 0.2.1 and StatsBase compute it; it was the kurtosis itself, 3 for a normal. Renamed, not just
  changed, so a reader of the old field fails loudly instead of being 3 off. The weighted one is
  `weighted_excess_kurtosis`.
- **Breaking: StreamHistogram 0.2.1** (compat `"0.2.1"`), which renames its type `StreamHist` to `StreamingHistogram`;
  `mapDataHistograms` returns the renamed type. It has the excess kurtosis and fixes the ASH-derived
  counts (`ash_count`) when some values fall outside the histogram's range: they were scaled by every value, not only
  those in range.
- New `test/weightsTests.jl`: the weighted results are those of the weighted map values, the unweighted ones
  don't change, an integer weight `k` counts like the map repeated `k` times, and the CSV, JSON and summary
  output. `test/cliTests.jl` also runs `extract-map-data-histogram` with a `--bin-range` no value falls in.

### `atlas extract-assignments` on multiscale atlases

- **`atlas extract-assignments` supports multiscale atlases**, writing them at the finest scale: one column per
  finest unit, holding the district of the region that covers it in each map (the precinct where its county is
  split, the whole county where it is not). Node ids with several components are joined with `:`
  (e.g. `MECKLENBURG:052`).
  - New `--graph <graph.json>`: the columns are the dual graph's finest units (read with the atlas's
    `levels in graph` parameter, as `relabel` does), including precincts in counties no map splits.
  - Without a graph, the columns are the finest regions seen in the atlas (a county no map splits stays one
    column); the command says when it switches to this, and reads the atlas a second time to collect them.
  - Single-level atlases are written exactly as before, in one pass.
  - Errors name the map and node: a unit no key covers, or (with `--graph`) a node the graph does not have. No
    partial file is left behind.
  - On the NC example atlas (100 maps): 2,650 precinct columns with the precinct graph, 2,194 without, in about
    6 s.
- Multi-component node ids that are the same in every map were rejected before; they are now written like any
  others.

### Reading maps with AtlasIO's `eachMap`

- `extract-map-data`, `extract-map-data-histogram`, `extract-assignments` and `add` read and process the maps
  with AtlasIO 0.2.5's `eachMap(f, ...)` (compat `"0.2.5"`) instead of their own batches: the per-map work runs
  in its parallel tasks, each taking the next map as it finishes one, so a slow map no longer holds up a whole
  batch. `relabel` keeps its own batches (its relabeling is a serial chain).
- An error is now raised at the first map in file order that fails (it used to be the first task that failed),
  and each map line is checked against the format version in the header, as AtlasIO's readers do.
- An unexpected error inside a writer is logged by AtlasIO, naming the map, with the backtrace from inside the
  writer, before it is raised. Errors meant for the user (a field `add` would overwrite, a map that doesn't fit
  `extract-assignments`' columns) are raised without that log.
- Progress bars update per map.
- **`computeWriters(ws, path)`** (or an open `Atlas`; keywords `cores`, `skip`, `max`): the writers on every map
  of an atlas file, streamed, giving `(name, weight, values)` per map in file order.
- `readBatch` is gone; `parallelDo!` remains for `relabel` and `computeWriters` on maps in memory.

### Format version, parallel errors, tests

- `atlas info` (and the `about.md` written by `extract-map-data`) shows the atlas's **format version** (`"1"` or
  `"2"`); `atlasInfo` returns it under `"header"` → `"format version"`.
- An error inside a parallel batch (e.g. `extract-assignments` on a multiscale atlas) is now reported as the
  error itself, not wrapped in Julia's `TaskFailedException` with a stack trace.
- New `test/versionsTests.jl`: every subcommand gives the same output on a v1 atlas and on its v2 conversion
  (`relabel` and `add` keep the input's version, with the same maps); and atlases with Float64 weights keep them
  through `relabel`, `add` and `convert`.

- **Fix:** `atlas extract-map-data-histogram --moment-powers` with a highest power below 4 (e.g. `1,2`) failed
  with "moment order 3 not tracked": the summary always computed skewness and kurtosis. Each statistic is now
  reported only when its moments are tracked (variance and std need 2, skewness 3, kurtosis 4) and is `null`
  otherwise.
- New `test/cliTests.jl`: every subcommand run through `command_main`, the installed command's entry point, so
  option parsing and flag handling are tested (they were covered only for `convert`). It also tests
  `relabel --weight-population` end to end with its two error messages, and `add` refusing to overwrite a field
  without `--overwrite`.

## [0.3.1]

- **JSON3 is no longer a dependency** (it is deprecated in the General registry). AtlasUtilities now reads and
  writes all JSON with JSON.jl, like AtlasIO, CycleWalk and MetropolizedForestRecom: dual graphs (`relabel`,
  `render`), `list-nodes` output and the histogram summaries of `extract-map-data-histogram`.
- No change in results. Graph attributes used as node keys keep their spelling: a whole-number float such as
  `5.0` still matches the key `"5"`, as when JSON3 read it as an integer. `list-nodes` output is byte-identical.
  Histogram JSON holds the same values; its keys are now written in sorted order instead of hash order, so the
  same run always gives the same file.
- New helpers `readJSONFile` and `jsonKeyString` (src/json.jl), also used by the render extension.

## [0.3.0]

- **`atlas render` is now a package extension.** Its plotting packages -- CairoMakie (with Makie and Colors),
  Shapefile and LibGEOS, about 170 of the ~280 packages AtlasUtilities depended on -- are weak dependencies:
  not installed or loaded unless you render. Loading AtlasUtilities drops from about 5 s to about 1.5 s, and
  installing or updating precompiles far fewer packages.
- New `atlas install-render`: installs those packages into the `atlas` command's environment, once. Until then
  `atlas render` stops with a message saying so.
- Breaking for Julia users of the render internals: they live in the `AtlasUtilitiesRenderExt` extension
  (`Base.get_extension(AtlasUtilities, :AtlasUtilitiesRenderExt)`) after `using CairoMakie, Shapefile, LibGEOS`.
  The exported `run_render`, `render_map` and `districtColors` still work, loading the extension on first use.
- **No system image.** `deps/build.jl` no longer compiles one (it was about 1.2 GB and took several minutes).
  It now gives the `atlas` command its own environment, with the clone developed into it and precompiled; that is
  what lets `atlas install-render` add packages. Installing takes under a minute when packages are cached, and
  `atlas info` starts in about 3.5 s. The build removes an old system image. Rebuilding keeps the plotting
  packages if they were installed.
- The launcher no longer breaks when its Julia version is removed (e.g. by juliaup): it falls back to `julia`
  on the `PATH`. It also ignores the user's global environment (`JULIA_LOAD_PATH="@:@stdlib"`).

## [0.2.1]

- New `atlas convert <src> <dst> [--to 1|2]`: convert an atlas between Atlas format versions 1 and 2 (AtlasIO's
  `convertAtlas`). Only the header's `formatVersion` and each map's district assignment are rewritten; the
  banner, the atlas parameters and every map's name, weight and data are copied byte for byte.
- `atlas relabel` and `atlas add` keep their input's format version. They copy the input's header, so given a
  format v2 atlas they now also write its maps as v2; before, they would have written v1 maps under a v2
  header, a file no reader accepts.
- Requires AtlasIO 0.2.2 (reads and writes format v2).

## [0.2.0]

- Uses AtlasIO 0.2 (JSON.jl instead of JSON3): map lines are parsed with `parseMap`. `atlas add` no longer
  rewrites the atlas parameters line (fixed `provenanceHeaderBytes`).

## [0.1.9]

- `atlas info`: keep up with the header CycleWalk 0.2.2+ writes. `script_includes`
  -- the full source of every file the run script `include`s -- joins `script` and
  `toml_config` as a bulky entry that is noted but never printed (it was being
  dumped into the printed header and into `extract-map-data`'s `about.md`, tens of
  kilobytes of Julia), and `--extract-script` now writes each included source out
  alongside the script and config.
- `atlas info --extract-script` writes every extracted file into the current
  directory, under the basename of the name the header records. CycleWalk records
  the TOML config under the path the run was invoked with, so extraction was
  writing back over the live config file. An existing file of that name is now kept
  and its entry skipped; the new `--force` flag overwrites.

## [0.1.8]

- `atlas render` now accepts a point-position node-link JSON graph (e.g.
  `Data/hex_graph_10_by_10.json`) as a geometry source, alongside a shapefile: each
  node's Voronoi cell is built directly from the graph's own adjacency (half-plane
  clipping, no new dependency, no Delaunay/Voronoi re-triangulation), so it stays
  correct for whatever adjacency the graph actually encodes and reproduces true
  hexagons/squares for the hex/grid example graphs as a side effect. The shapefile
  attribute flag is renamed `--shapefile-key` -> `--key` (now applies to either
  source); `--county-column` similarly names either a shapefile column or a
  point-graph node attribute.
- Add `--county-lines`/`--no-precinct-lines` to `atlas render`: a shapefile's
  `--county-column` rows are dissolved into each county's true polygon via a new
  LibGEOS dependency and its outline drawn; a point-graph's exact shared border
  between differing-county neighbors is read straight off its own adjacency (no
  geometry library needed there). `--no-precinct-lines` turns off the per-row
  stroke drawn by default. New dependency: LibGEOS.
- `atlas render`: add `--strip-suffix` (strip a trailing regex, e.g. legislative-
  district `__SD<n>__HD<n>` tags, from node ids before matching them against the
  shapefile), `--county-column` (fall back a node id matching no precinct token
  at all to every precinct in that county, e.g. for graphs that collapse whole
  unsplit counties into one node), `--skip-missing` (render anyway when some
  node ids don't match, leaving those areas blank, instead of erroring), and
  `--show` (open the saved image in the OS's default viewer after writing it).
- Figure-building is factored out of `atlas render` into `render_map`, which
  returns a backend-agnostic `Makie.Figure` without saving or displaying it;
  `run_render` is the thin `atlas render` driver that activates CairoMakie and
  saves. `render_map`, `run_render`, and `districtColors` are now exported for
  library use. New dependency: Makie.

## [0.1.7]

- Add `atlas render`: draw a map's districting as a filled-precinct choropleth
  using a shapefile for geometry, matched to the atlas's node ids via
  `--shapefile-key` (a single column, or a comma-separated list for
  multi-component node ids like NC's `(county, prec_id)`). New dependencies:
  Shapefile, CairoMakie, Colors.

## [0.1.6]

- `atlas info` now notes when an atlas has an embedded run script and/or TOML
  config, and `--extract-script` extracts both (whichever are present) instead
  of just the run script.
