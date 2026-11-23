# Changelog

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
