# Using AtlasUtilities.jl as a library

AtlasUtilities installs the `atlas` CLI (see [README.md](README.md)), but the
district-relabeling/alignment logic underneath `atlas relabel` is also usable
directly from other Julia code — e.g. to align maps in memory, compute
distances between districtings for analysis, or drive a custom relabeling
loop instead of the CLI's atlas-to-atlas pipeline.

This page covers the exported library API. For the CLI itself, see
[README.md](README.md); for the algorithm and file-format spec behind it, see
[relabel.md](relabel.md).

## Setup

```julia
using AtlasIO         # Map, Districting, and atlas I/O — required alongside AtlasUtilities
using AtlasUtilities
```

Every function below operates on `Map`/`Districting`, which are defined by
[AtlasIO.jl](https://github.com/jonmjonm/AtlasIO.jl), not re-exported here —
`using AtlasIO` yourself gets you `Map`, `Districting`, and the atlas
read/write functions (`smartOpen`, `openAtlas`, `nextMap`, `addMap`, ...).

```julia
Districting = Dict{Tuple{Vararg{String}}, Int64}   # node key -> district label

Base.@kwdef struct Map{T,W<:Real}
    name::String
    districting::Districting
    weight::W          # Int64 (the default) or Float64, as the atlas header's weightType says
    data::T
end
```

## Exported API

| Function | Purpose |
|----------|---------|
| [`findRelabeling`](#findrelabeling) | Find the permutation `σ` that best aligns one map's labels to another's. |
| [`relabelMap`](#relabelmap) | Apply a permutation `σ` to a map, returning a relabeled copy. |
| [`confusionMatrix`](#confusionmatrix-and-permutationfromconfusion) | Build the district-overlap matrix `findRelabeling` optimizes over. |
| [`permutationFromConfusion`](#confusionmatrix-and-permutationfromconfusion) | Solve a confusion matrix for its optimal permutation directly. |
| [`hammingDistance`](#hammingdistance) | District-wise Hamming distance between two maps *as currently labeled*. |
| [`Hierarchy`](#hierarchy-loadhierarchy-and-loadpopulation), [`loadHierarchy`](#hierarchy-loadhierarchy-and-loadpopulation) | Represent/load a dual-graph hierarchy for multiscale atlases. |
| [`loadPopulation`](#hierarchy-loadhierarchy-and-loadpopulation) | Load per-node population from a dual-graph JSON, for population-weighted alignment. |
| [`atlasInfo`](#atlasinfo) | Structured atlas metadata (header, parameters, map data field names) — the data behind `atlas info`. |
| [`listMapData`](#listmapdata) | List the data field names in an atlas's first map. |
| [`mapDataHistograms`](#mapdatahistograms) | A StreamHistogram of every map-data field, weighted by the maps' weights — the data behind `extract-map-data-histogram` and `summarize-map-data`. |
| [`WriterSet`](#writerset-and-computewriters), [`computeWriters`](#writerset-and-computewriters) | Compute CycleWalk writer statistics (spanning trees, isoperimetric scores, partisan margins, ...) on maps in memory — what `atlas add` writes. |
| [`writerFields`](#writerset-and-computewriters), [`listWriters`](#writerset-and-computewriters) | The fields a `WriterSet` computes; the writer names it accepts. |
| [`assignmentMatrix`](#assignmentmatrix) | Every map's district assignment as a maps × units matrix — the data behind `extract-assignments`. |
| [`render_map`](#render_map-and-run_render) | Build (but don't save or display) a `Makie.Figure` drawing a map's districting from a shapefile or point-position JSON graph. |
| [`run_render`](#render_map-and-run_render) | `render_map` plus saving to a file (`atlas render`'s driver). |
| [`districtColors`](#render_map-and-run_render) | The categorical color palette `render_map` uses, one color per district. |

`findRelabeling`, `confusionMatrix`, and `hammingDistance` each have two
methods: a 3-argument form for maps that share one fixed node-key set, and a
4-argument form (with a `Hierarchy`) for multiscale atlases whose maps encode
districts at varying resolutions. Both forms accept a `pop` keyword to weight
by population instead of raw node counts.

### `findRelabeling`

```julia
findRelabeling(ref::Map, cur::Map, d::Int; pop = nothing) -> Vector{Int}
findRelabeling(ref::Map, cur::Map, d::Int, h::Hierarchy; pop = nothing) -> Vector{Int}
```

Returns the permutation `σ` of `1:d` that minimizes the district-wise Hamming
distance between `ref` and `cur` after relabeling — i.e. the same alignment
`atlas relabel` computes for each map against its reference. `d` is the
district count. The 3-arg form requires `ref` and `cur` to share the same
node-key set; the `Hierarchy` form resolves both to finest units first, so
node sets may differ (a multiscale atlas).

```julia
σ = findRelabeling(ref, cur, d)
```

### `relabelMap`

```julia
relabelMap(m::Map, σ::Vector{Int}) -> Map
```

Applies `σ` (from `findRelabeling`, or any permutation of `1:d`) to `m`,
returning a map with `name`/`weight`/`data` preserved and district labels
mapped `j -> σ[j]`. **Mutates `m.districting`'s values in place** — the
returned `Map` shares the same underlying `Dict` as `m`, so `m` is *also*
changed and must not be read under its old labels after this call:

```julia
aligned = relabelMap(cur, σ)
cur.districting  # already holds the new labels too — cur and aligned alias
```

If you need `cur` under its old labels afterward (e.g. to compare
before/after distance), compute what you need from `cur` *before* calling
`relabelMap`, or pass a copy: `relabelMap(Map(cur.name, copy(cur.districting), cur.weight, cur.data), σ)`.

### `confusionMatrix` and `permutationFromConfusion`

```julia
confusionMatrix(ref::Map, cur::Map, d::Int; pop = nothing) -> Matrix{Int}
confusionMatrix(ref::Map, cur::Map, d::Int, h::Hierarchy; pop = nothing) -> Matrix{Int}
permutationFromConfusion(O::Matrix{Int}, d::Int) -> Vector{Int}
```

`findRelabeling(ref, cur, d; pop) == permutationFromConfusion(confusionMatrix(ref, cur, d; pop), d)`
— these are its two halves, exposed separately for callers who want the
overlap matrix itself (e.g. to also compute a distance from it without
rescanning nodes — see `hammingDistance`'s docstring for the pattern) or who
want to solve a confusion matrix built some other way.

`O[i,j]` is the overlap between `ref`'s district `i` and `cur`'s district `j`
— a node count, or (if `pop` is given) a population sum.

### `hammingDistance`

```julia
hammingDistance(ref::Map, cur::Map, d::Int; pop = nothing) -> Int
hammingDistance(ref::Map, cur::Map, d::Int, h::Hierarchy; pop = nothing) -> Int
```

The district-wise Hamming distance between `ref` and `cur` **as currently
labeled** (no realignment): `Σᵢ |Dᵢ Δ D̂ᵢ|`, or its population-weighted
analogue if `pop` is given. Useful for measuring how similar two districtings
already are, e.g. to compare a set of maps to a common reference, or to check
how much `findRelabeling`/`relabelMap` improved alignment:

```julia
before = hammingDistance(ref, cur, d)
σ = findRelabeling(ref, cur, d)
after = hammingDistance(ref, relabelMap(cur, σ), d)   # after <= before
```

### `Hierarchy`, `loadHierarchy`, and `loadPopulation`

```julia
Hierarchy(levels::Vector{String}, finest::Vector{Tuple{Vararg{String}}})
loadHierarchy(jsonPath, levels) -> Hierarchy
loadPopulation(jsonPath, levels, attr::AbstractString) -> Dict{Tuple{Vararg{String}}, Int}
```

`Hierarchy` represents a dual-graph hierarchy: `levels` are the attribute
names (finest last, e.g. `["county","prec_id"]`), and `finest` is every
finest-resolution unit as a key tuple, in a fixed order. `loadHierarchy`
builds one from a NetworkX node-link JSON (the same dual-graph file used by
`atlas relabel`'s `<graph.json>` argument), reading each node's `levels`
attributes.

`loadPopulation` reads a population attribute (e.g. `"pop2020cen"`) from the
same kind of JSON — often literally the same file — keyed the same way, for
use as the `pop` argument to `findRelabeling`/`confusionMatrix`/`hammingDistance`.

```julia
h   = loadHierarchy("graph.json", ["county", "prec_id"])
pop = loadPopulation("graph.json", ["county", "prec_id"], "pop2020cen")

σ = findRelabeling(ref, cur, d, h; pop)
```

### `atlasInfo`

```julia
atlasInfo(atlasPath::AbstractString) -> Dict{String,Any}
atlasInfo(atlas) -> Dict{String,Any}
```

Returns the same metadata `atlas info` prints, as data rather than formatted
text: `"header"` (description, date, map param type, weight type, format version),
`"parameters"` (`atlas.atlasParam` verbatim, including the bulky `script`
entry — unlike the CLI's printed output, nothing is filtered out here), and
`"map_data"` (the sorted field names found in the atlas's first map, or an
empty vector if it has no maps).

The path/URL form opens and closes the atlas for you (via `smartOpen`/
`openAtlas`); the other form takes an atlas you already have open — useful if
you're already mid-stream and don't want to reopen the file.

```julia
info = atlasInfo("atlas.jsonl.gz")
info["header"]["description"]
info["parameters"]["districts"]
info["map_data"]                  # e.g. ["log_spanning_trees", ...]
### `listMapData`

```julia
listMapData(atlasPath::AbstractString) -> Union{Vector{String}, Nothing}
```

Returns the sorted data field names (e.g. `log_spanning_trees`) found in the
first map of the atlas at `atlasPath`, or `nothing` if the atlas has no maps
(as opposed to a map whose data is empty, which returns `String[]`). This is
the function `atlas list-map-data` uses to print its output.

```julia
fieldNames = listMapData("atlas.jsonl.gz")
```

### `mapDataHistograms`

```julia
mapDataHistograms(atlasPath; burn_in = 0, max_maps = 0, sortVals = true,
                  integer = false, bin_range = nothing, bin_num = 50, bins = nothing,
                  moment_powers = [1, 2, 4, 8], add = "", ..., quiet = false)
    -> (Dict{String,Union{StreamingHistogram,Vector{StreamingHistogram}}}, nmaps)
```

Reads the atlas once and accumulates each map-data field into a
[StreamHistogram](https://github.com/jonmjonm/StreamHistogram.jl) `StreamingHistogram`: one
for a scalar field, a vector of them (one per index) for a vector field. With
`sortVals` (the default) each map's vector is sorted first, so histogram `j` holds
the `j`-th smallest value of each map — the `j`-th order statistic, which is
comparable across maps even when district labels are not. The keywords are the
`extract-map-data-histogram` options: `burn_in`/`max_maps` choose the maps,
`integer`/`bin_range`/`bin_num`/`bins`/`moment_powers` are passed to every
`StreamingHistogram`, and `add` (with the graph keywords of `atlas add`) also computes
writer functions. Returns the histograms and the number of maps read.

Each value is added with its map's weight, so every histogram answers both
unweighted and weighted questions (StreamHistogram's `weighted*` functions); with
an unweighted atlas the two agree. A negative or non-finite weight is an error.

```julia
using AtlasUtilities, StreamHistogram
hists, n = mapDataHistograms("atlas.jsonl.gz"; quiet = true)
h = hists["get_log_spanning_trees"]           # a vector field: one StreamingHistogram per sorted index
mean(h[1]), quantile(h[1], [0.05, 0.5, 0.95])  # unweighted
weightedMean(h[1]), weightedQuantile(h[1], 0.5), effectivesamplesize(h[1])
f = density(h[1])                              # the density, as a function; also cdf, histogram(oh, edges)
```

### `WriterSet` and `computeWriters`

```julia
WriterSet(functions; config = "", graph = "", pop_col = "", node_col = "", area_col = "",
          border_col = "", edge_perimeter_col = "", node_data = "", vote_cols = "")
computeWriters(ws, m::Map) -> Dict{String,Any}
computeWriters(ws, maps::AbstractVector{<:Map}; cores = Threads.nthreads()) -> Vector{Dict{String,Any}}
computeWriters(ws, path::AbstractString; cores = Threads.nthreads(), skip = 0, max = typemax(Int))
    -> iterator of (name, weight, values::Dict{String,Any})
writerFields(ws) -> Vector{String}
listWriters() -> Vector{String}
```

The library form of `atlas add`: it computes CycleWalk writer statistics on maps in
memory instead of writing them into a new atlas. A `WriterSet` resolves the writer
functions and builds the dual graph once; `computeWriters` evaluates them on one
map, on a vector of maps in parallel, or on every map of an atlas file, streamed (read
and evaluated in parallel with AtlasIO's `eachMap`, without holding the atlas in
memory; run it with `BLAS.set_num_threads(1)` when using several threads). Each field's value is a per-district vector
indexed by the map's own district numbers (entry `i` describes district `i` of
`m.districting`), or a scalar, exactly as `atlas add` writes it.

- `functions`: a writer name, a vector of names, or a comma-separated list;
  `listWriters()` gives the names (it smoke-tests every CycleWalk `get_*` writer, so
  it takes a moment).
- The graph is described as for `atlas add`: a CycleWalk TOML `config` (its
  `[plans]` table) and/or the keywords, which override it — `graph` (the dual-graph
  JSON), `pop_col`, `node_col` (the column the districting keys use) and the
  geometry columns some writers need.
- The partisan writers `get_partisan_margins` and `get_partisan_seats` need
  `vote_cols`, `"votes1,votes2"` pairs separated by `;`; each pair gives a field
  `<writer>_<votes1>_<votes2>`. `writerFields(ws)` lists the fields in order.

Writers with a partition-free method are evaluated straight from the districting;
the others on the map's partition rebuilt as CycleWalk does at startup, which draws
a random spanning tree per district: the values don't depend on it, but their last
digits' rounding can.

```julia
using AtlasIO, AtlasUtilities
ws = WriterSet(["get_log_spanning_trees", "get_isoperimetric_scores", "get_partisan_margins"];
               graph = "CT_pct20.json", pop_col = "POP20", node_col = "NAME", area_col = "area",
               border_col = "border_length", edge_perimeter_col = "length",
               vote_cols = "G20PREDEM,G20PREREP")
maps = collect(eachMap("atlas.jsonl.gz"))
stats = computeWriters(ws, maps)               # one Dict per map, in parallel
stats[1]["get_partisan_margins_G20PREDEM_G20PREREP"]   # district 1's margin first
for r in computeWriters(ws, "atlas.jsonl.gz")  # streamed from the file, in parallel, in file order
    println(r.name, " ", r.values["get_log_spanning_trees"])
end
```

### `assignmentMatrix`

```julia
assignmentMatrix(atlasPath; graph = nothing, quiet = true)
    -> (names, weights, units, unitNames, districts)
```

Every map's district assignment, as data: `districts[i, j]` is the district number
of unit `j` in map `i` (a `Matrix{Int}`, maps × units); `names` and `weights` are
the maps' names and weights; `units` are the units' node keys (as in a
`Districting`) and `unitNames` their names as `atlas extract-assignments` writes
them (components joined by `:`). The table is the same as that command's CSV.

The units: with `graph`, the dual graph's finest units, read with the atlas's
`levels in graph` parameter; otherwise the maps' nodes when every map has the same
ones, or for a multiscale atlas the finest regions seen in it (a county no map
splits stays one unit). A unit's district is that of the map's key covering it:
the unit itself, or the whole county containing it.

The matrix holds 8 bytes per map per unit (800 MB for 100,000 maps of 1,000 units).

```julia
A = assignmentMatrix("atlas.jsonl.gz"; graph = "NC_pct21.json")
# how often two units share a district, weighted by the maps' weights
together(i, j) = sum(A.weights[A.districts[:, i] .== A.districts[:, j]]) / sum(A.weights)
```

### `render_map` and `run_render`

```julia
render_map(atlasPath::AbstractString, geo::AbstractString;
           key::AbstractString, map::Integer = 1,
           strip_suffix::AbstractString = "", county_column::AbstractString = "",
           county_lines::Bool = false, precinct_lines::Bool = true,
           skip_missing::Bool = false, quiet::Bool = false) -> Makie.Figure
```

Builds a `Makie.Figure` drawing the `map`-th map of the atlas at `atlasPath` as
a choropleth colored by district, using `geo` for precinct geometry matched to
node ids via `key` -- either a shapefile (a `.shp` path, or a `.zip` bundling
one) or a point-position node-link `.json` graph (e.g.
`Data/hex_graph_10_by_10.json`), whose nodes' Voronoi cells (built from the
graph's own adjacency) are used instead (see `atlas render --help` for the
matching rules, `--strip-suffix`, `--county-column`, and `--county-lines`).
Nothing is saved or displayed — that's the caller's job, via whichever Makie
backend is active:

```julia
using AtlasUtilities, CairoMakie   # or add GLMakie yourself for an interactive window

fig = render_map("atlas.jsonl.gz", "shapefile.zip"; key = "NAME")
save("map.png", fig)               # CairoMakie: write to a file
# or: display(fig)                 # GLMakie: open an interactive window
```

CairoMakie is the only backend AtlasUtilities depends on; `render_map` itself
is backend-agnostic, so any other Makie backend you install and activate
yourself works just as well.

`run_render` is the driver behind `atlas render` — it calls `render_map` for a
single map and activates CairoMakie to save it:

```julia
run_render("atlas.jsonl.gz", "shapefile.zip"; key = "NAME", out = "map.png")
run_render("atlas.jsonl.gz", "hex_graph.json"; key = "node_name", out = "hex.png")
```

`districtColors(ndists::Integer) -> Vector` returns the mutually-distinguishable
color palette `render_map` colors districts with, one entry per district number
`1:ndists`, if you want the same palette for your own plot.

## Worked example

```julia
using AtlasIO
using AtlasUtilities

io = smartOpen("atlas.jsonl.gz", "r")
atlas = openAtlas(io)
d = Int(atlas.atlasParam["districts"])

ref = nextMap(atlas)
maps = Map[]
while !eof(atlas)
    cur = nextMap(atlas)
    σ = findRelabeling(ref, cur, d)
    aligned = relabelMap(cur, σ)
    push!(maps, aligned)
    ref = aligned              # chain, matching atlas relabel's default mode
end
close(atlas)
```

For the equivalent atlas-to-atlas workflow (including progress reporting,
population weighting, and multiscale support) without writing this loop
yourself, call the driver `atlas relabel` itself uses:

```julia
AtlasUtilities.run_relabel(atlas1_path, atlas2_path, graph_path;
                            firstMap = false, quiet = true,
                            popJsonPath = pop_path, popAttr = "pop2020cen")
```

`run_relabel` (and most other subcommand drivers, `run_info`/`run_add`/etc.)
are not exported — they're written for the CLI's file-in/file-out shape —
so call them qualified as `AtlasUtilities.run_relabel(...)` if you want that
behavior without going through `atlas` itself. `run_render`
(see [above](#render_map-and-run_render)) is the exception: rendering
has no smaller reusable piece worth exposing separately from the whole
atlas-to-image pipeline, so it is exported directly.
