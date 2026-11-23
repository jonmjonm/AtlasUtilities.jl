# Changelog

## [0.3.3]

- `atlas info` (and the `about.md` written by `extract-map-data`) shows the atlas's **format version** (`"1"` or
  `"2"`); `atlasInfo` returns it under `"header"` → `"format version"`.
- An error inside a parallel batch (e.g. `extract-assignments` on a multiscale atlas) is now reported as the
  error itself, not wrapped in Julia's `TaskFailedException` with a stack trace.
- New `test/versionsTests.jl`: every subcommand gives the same output on a v1 atlas and on its v2 conversion
  (`relabel` and `add` keep the input's version, with the same maps); and atlases with Float64 weights keep them
  through `relabel`, `add` and `convert`.

## [0.3.2]

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
