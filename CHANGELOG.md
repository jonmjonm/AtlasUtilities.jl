# Changelog

## [Unreleased]

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
