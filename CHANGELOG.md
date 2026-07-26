# Changelog

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
