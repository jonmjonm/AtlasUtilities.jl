# Changelog

## [Unreleased]

- `atlas render`/`atlas view` now accept a point-position node-link JSON graph (e.g.
  `Data/hex_graph_10_by_10.json`) as a geometry source, alongside a shapefile: each
  node's Voronoi cell is built directly from the graph's own adjacency (half-plane
  clipping, no new dependency, no Delaunay/Voronoi re-triangulation), so it stays
  correct for whatever adjacency the graph actually encodes and reproduces true
  hexagons/squares for the hex/grid example graphs as a side effect. The shapefile
  attribute flag is renamed `--shapefile-key` -> `--key` (now applies to either
  source); `--county-column` similarly names either a shapefile column or a
  point-graph node attribute.
- Add `--county-lines`/`--no-precinct-lines` to `atlas render`/`atlas view`: a
  shapefile's `--county-column` rows are dissolved into each county's true polygon
  via a new LibGEOS dependency and its outline drawn; a point-graph's exact
  shared border between differing-county neighbors is read straight off its own
  adjacency (no geometry library needed there). `--no-precinct-lines` turns off
  the per-row stroke drawn by default.
- `atlas view` now loads every map up front and steps through them interactively
  instead of only ever showing one: `←`/`→` step maps (wrapping at either end),
  `space` toggles autoplay (`--play`/`--delay <ms>` set the initial state), `c`/`b`
  toggle the county-line/precinct-line overlays at runtime, `q`/`Escape` closes the
  window. District colors are assigned once across every loaded map, so a district
  number is the same color on every map. New dependency: LibGEOS.
- `atlas render`: add `--strip-suffix` (strip a trailing regex, e.g. legislative-
  district `__SD<n>__HD<n>` tags, from node ids before matching them against the
  shapefile), `--county-column` (fall back a node id matching no precinct token
  at all to every precinct in that county, e.g. for graphs that collapse whole
  unsplit counties into one node), `--skip-missing` (render anyway when some
  node ids don't match, leaving those areas blank, instead of erroring), and
  `--show` (open the saved image in the OS's default viewer after writing it).
- Add `atlas view`: like `atlas render`, but opens an interactive GLMakie window
  (pan/zoom/hover) instead of saving to a file, blocking until it's closed.
  Figure-building is factored out into `render_map` (returns a `Makie.Figure`,
  no save/display), shared by `atlas render` (CairoMakie, saves to disk) and
  `atlas view` (GLMakie, interactive). `render_map`, `run_render`, `run_view`,
  and `districtColors` are now exported. New dependencies: GLMakie, Makie.

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
