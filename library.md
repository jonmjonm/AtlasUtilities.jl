# AtlasUtilities library reference

AtlasUtilities is the library behind the `mapatlas` command (see [README.md](README.md)): everything the
command does is a function here, usable from other Julia code. For the relabeling algorithm and its file formats,
see [relabel.md](relabel.md).

## Setup

```julia
using AtlasIO         # Map, Districting and atlas I/O: not re-exported by AtlasUtilities
using AtlasUtilities
using CycleWalk       # only for the writer functions (see "Writers")
using StreamHistogram # only to query the histograms (add it from its GitHub URL until it is registered)
```

[AtlasIO](https://github.com/jonmjonm/AtlasIO.jl) defines the types the functions work on:

```julia
Districting = Dict{Tuple{Vararg{String}}, Int64}   # node key -> district label

Base.@kwdef struct Map{T,W<:Real}
    name::String
    districting::Districting
    weight::W          # Int64 (the default) or Float64, as the atlas header's weightType says
    data::T
end
```

Conventions: function names are camelCase and keywords snake_case. Functions print nothing and return what they
did; `progress = true` shows a progress bar. Existing output files are kept unless `force = true`. `cores`
defaults to `Threads.nthreads()`. Atlases may be format v1 or v2 (see AtlasIO's
[atlas_format.md](https://github.com/jonmjonm/AtlasIO.jl/blob/main/atlas_format.md)); an atlas written from
another keeps its format version. To convert between versions use AtlasIO's `convertAtlas`.

## What is exported

| Group | Exported | Public, not exported |
|-------|----------|----------------------|
| [Reading](#reading) | `atlasInfo`, `listMapData`, `listNodes`, `extractScripts` | `atlasHeaderInfo`, `nodeIdString` |
| [Relabeling](#relabeling) | `relabelAtlas`, `findRelabeling`, `relabelMap`, `confusionMatrix`, `permutationFromConfusion`, `hammingDistance`, `Hierarchy`, `loadHierarchy`, `loadPopulation` | |
| [Analysis](#analysis) | `summarizeMapData`, `mapDataHistograms`, `writeHistograms`, `extractMapData`, `extractAssignments`, `assignmentMatrix` | |
| [Writers](#writers) (need CycleWalk) | `addMapData`, `WriterSet`, `computeWriters`, `writerFields`, `listWriters` | `listWriterDetails`, `loadGraph` |

Use a public, unexported name qualified, e.g. `AtlasUtilities.loadGraph`.

## Reading

### `atlasInfo`

```julia
atlasInfo(atlasPath) -> Dict{String,Any}
atlasInfo(atlas)     -> Dict{String,Any}      # an atlas already open
```

The metadata of an atlas as data: `"header"` (description, date, map param type, weight type, format version),
`"parameters"` (the atlas parameters verbatim, including the bulky embedded `script`) and `"map_data"` (the
sorted field names in the first map, empty if there are no maps).

```julia
info = atlasInfo("atlas.jsonl.gz")
info["parameters"]["districts"]
info["map_data"]                   # e.g. ["get_log_spanning_trees", ...]
```

`AtlasUtilities.atlasHeaderInfo(atlasPath) -> String` renders it as the text `mapatlas info` prints (without the
embedded sources).

### `listMapData`

```julia
listMapData(atlasPath) -> Union{Vector{String},Nothing}
```

The sorted data field names of the first map; `nothing` if the atlas has no maps (a map whose data is empty
gives `String[]`).

### `listNodes`

```julia
listNodes(atlasPath; map = 1) -> Vector{String}
```

The node ids of the `map`-th map, sorted; the components of a multiscale id are joined with `:` (as
`AtlasUtilities.nodeIdString(key)` does).

### `extractScripts`

```julia
extractScripts(atlasPath, dir = pwd(); force = false) -> (written, skipped, entries)
```

Writes the sources embedded in the header (the run script, its includes and the TOML config) into `dir`, under
the basename the run recorded, never to the recorded path. `written` and `skipped` are paths; `entries` lists
each handled entry as `entry => path` in order, with `entry` one of `"script"`, `"toml_config"` or
`"script_includes[<name>]"`.

## Relabeling

### `relabelAtlas`

```julia
relabelAtlas(src, dst; graph = nothing, first_map = false, population_file = nothing,
             population_attr = nothing, cores, progress = false) -> Int
```

Relabels the district numbers of every map of `src` so consecutive maps are as similar as possible, writes `dst`
and returns the number of maps. `graph` (a dual-graph JSON) is needed for multiscale atlases, whose node sets
vary. `first_map = true` aligns every map to map 1 instead of to its predecessor. `population_file` and
`population_attr` weight the alignment by population.

```julia
relabelAtlas("atlas.jsonl.gz", "relabeled.jsonl.gz")
relabelAtlas("ms.jsonl.gz", "out.jsonl.gz"; graph = "nc.json",
             population_file = "nc.json", population_attr = "pop2020cen")
```

### `findRelabeling`, `relabelMap`

```julia
findRelabeling(ref::Map, cur::Map, d::Int; pop = nothing) -> Vector{Int}
findRelabeling(ref::Map, cur::Map, d::Int, h::Hierarchy; pop = nothing) -> Vector{Int}
relabelMap(m::Map, σ::Vector{Int}) -> Map
```

`findRelabeling` returns the permutation `σ` of `1:d` that minimizes the district-wise Hamming distance between
`ref` and `cur` after relabeling; `d` is the number of districts. The first form needs both maps to have the
same node keys, the `Hierarchy` form resolves both to the finest units first. `relabelMap` applies `σ`
(`j -> σ[j]`), keeping name, weight and data. **It changes `m.districting` in place**: the returned map shares
that `Dict`, so pass a copy if you need `m` under its old labels.

```julia
σ = findRelabeling(ref, cur, d)
aligned = relabelMap(cur, σ)
```

### `confusionMatrix`, `permutationFromConfusion`, `hammingDistance`

```julia
confusionMatrix(ref, cur, d; pop = nothing) -> Matrix{Int}          # and the Hierarchy form
permutationFromConfusion(O, d) -> Vector{Int}
hammingDistance(ref, cur, d; pop = nothing) -> Int                  # and the Hierarchy form
```

`O[i,j]` is the overlap (node count, or population with `pop`) of district `i` of `ref` and district `j` of
`cur`; `findRelabeling` is `permutationFromConfusion(confusionMatrix(...), d)`. `hammingDistance` is the distance
**as currently labeled**, `Σᵢ |Dᵢ Δ D̂ᵢ|`, or its population-weighted analogue.

### `Hierarchy`, `loadHierarchy`, `loadPopulation`

```julia
loadHierarchy(jsonPath, levels) -> Hierarchy
loadPopulation(jsonPath, levels, attr) -> Dict{Tuple{Vararg{String}},Int}
```

A `Hierarchy` holds the level names (finest last, e.g. `["county", "prec_id"]`, the atlas parameter
`"levels in graph"`) and every finest unit's key, read from a node-link dual-graph JSON. `loadPopulation` reads
a population attribute keyed the same way, for the `pop` keyword above.

## Analysis

### `summarizeMapData`

```julia
summarizeMapData(atlasPath; max_maps = 0, cores, progress = false) -> MapDataSummary
```

For every map-data field, the mean, standard deviation and min, quartiles and max (one entry per index for a
vector field, each map's vector sorted first), with weighted versions when the map weights vary. Printing the
result gives the text of `mapatlas summarize-map-data`. Both types, `MapDataSummary` and `FieldSummary`, are
exported. As data: `s.nmaps`, and `s.fields[name]`, a summary with
`nobs`, `min`, `max`, `unweighted` (`mean`, `std`, `quartiles`, ...), `weighted` (or `nothing`),
`effective_sample_size` and `total_weight`, or a vector of them for a vector field.

```julia
s = summarizeMapData("atlas.jsonl.gz")
print(s)
s.fields["get_log_spanning_forests"].unweighted.mean
```

### `mapDataHistograms`

```julia
mapDataHistograms(atlasPath; writers = nothing, burn_in = 0, max_maps = 0, sort_values = true,
                  cores, progress = false, integer = false, bin_range = nothing, bin_num = 50,
                  bins = nothing, moment_powers = [1, 2, 4, 8])
    -> (Dict{String,Union{StreamingHistogram,Vector{StreamingHistogram}}}, nmaps)
```

Reads the atlas once and accumulates each field into a
[StreamHistogram](https://github.com/jonmjonm/StreamHistogram.jl) `StreamingHistogram`: one for a scalar field,
one per index for a vector field. With `sort_values` (the default) each map's vector is sorted first, so
histogram `j` holds the `j`-th smallest value of each map, comparable across maps even when district labels are
not. `writers` (a [`WriterSet`](#writers)) also computes writer fields. Every value is added with its map's
weight, so each histogram answers unweighted and weighted questions; a negative or non-finite weight is an error.

```julia
using AtlasUtilities, StreamHistogram
hists, n = mapDataHistograms("atlas.jsonl.gz")
h = hists["get_log_spanning_trees"]             # a vector field: one histogram per sorted index
mean(h[1]), quantile(h[1], [0.05, 0.5, 0.95])
weightedMean(h[1]), effectivesamplesize(h[1])
```

### `writeHistograms`

```julia
writeHistograms(outdir, hists; atlas = nothing, burn_in = 0, max_maps = 0, compress = true, force = false)
    -> (written, skipped)
```

Writes each field's histograms to `<field>-histogram.csv[.gz]` (the exact bins) and
`<field>-histogram.json[.gz]` (the statistics), and with `atlas` given an `about.md` (listed first in
`written`). A nonzero `max_maps` adds `-partial` to the file names; pass the `burn_in` and `max_maps` the
histograms were built with.

### `extractMapData`

```julia
extractMapData(atlasPath, outdir = <atlas path without its extension>; writers = nothing, compress = true,
               force = false, max_maps = 0, cores, progress = false) -> (outdir, written, skipped, nmaps)
```

One CSV per data field (a row per map: name, values, `map_weight`) and an `about.md`, which is first in
`written`. `writers` computes more fields; a field whose file is kept is not computed. A nonzero `max_maps` adds
`-partial` to the file names. An atlas with no maps writes nothing.

```julia
ws = WriterSet(["get_isoperimetric_scores"]; graph = "CT_pct20.json", pop_col = "POP20", node_col = "NAME",
               area_col = "area", border_col = "border_length", edge_perimeter_col = "length")
extractMapData("run.jsonl.gz"; writers = ws)
```

### `extractAssignments`, `assignmentMatrix`

```julia
extractAssignments(atlasPath, outpath = <default>; graph = nothing, compress = true, force = false,
                   cores, progress = false) -> (path, nmaps, units, scale) or nothing
assignmentMatrix(atlasPath; graph = nothing, cores, progress = false)
    -> (names, weights, units, unitNames, districts)
```

The district of every unit in every map: written as one wide CSV (`<atlas>-assignments.csv[.gz]`), or returned
as a `maps × units` matrix. With `graph`, the units are the dual graph's finest ones; otherwise the maps' nodes,
or for a multiscale atlas the finest regions seen in it. `extractAssignments` returns `nothing` if the file
exists and `force` is not set, and `nmaps = 0` for an atlas with no maps; `scale` describes the columns when they
are not simply the maps' nodes. The matrix holds 8 bytes per map per unit.

```julia
A = assignmentMatrix("atlas.jsonl.gz"; graph = "NC_pct21.json")
# how often two units share a district, weighted by the maps' weights
together(i, j) = sum(A.weights[A.districts[:, i] .== A.districts[:, j]]) / sum(A.weights)
```

## Writers

CycleWalk writer statistics (spanning-tree counts, isoperimetric scores, partisan margins, ...). These live in
an extension: run `using CycleWalk` first, or calling them says to.

### `WriterSet`

```julia
WriterSet(functions; config = nothing, graph = nothing, pop_col = nothing, node_col = nothing,
          area_col = nothing, border_col = nothing, edge_perimeter_col = nothing,
          node_data = String[], vote_cols = Tuple{String,String}[])
writerFields(ws) -> Vector{String}
```

The writers, ready to evaluate, with their dual graph built once. `functions` is a vector of writer names (or one
name). The graph is described by a CycleWalk TOML `config` (its `[plans]` table) and/or the keywords, which
override it: `graph` (the dual-graph JSON), `pop_col`, `node_col` (the column the districting keys use) and the
geometry columns some writers need. The partisan writers `get_partisan_margins` and `get_partisan_seats` need
`vote_cols`, a vector of `(votes1, votes2)` column pairs; each pair gives a field
`<writer>_<votes1>_<votes2>`. `writerFields` lists the fields in order.

### `addMapData`

```julia
addMapData(src, dst, ws::WriterSet; overwrite = false, cores, progress = false) -> Int
addMapData(src, dst, functions; <WriterSet's keywords>, overwrite = false, cores, progress = false) -> Int
```

Adds the writers' values to every map's data, writes `dst` and returns the number of maps. A field that already
exists is an error unless `overwrite = true`. The header of `dst` records an `"added map data"` entry
(`"by": "addMapData"`, the AtlasUtilities `version`, `fields`, `graph`, `date`).

```julia
using AtlasUtilities, CycleWalk
addMapData("in.jsonl.gz", "out.jsonl.gz", ["get_log_spanning_trees"]; graph = "CT_pct20.json",
           pop_col = "POP20", node_col = "NAME", progress = true)
```

### `computeWriters`

```julia
computeWriters(ws, m::Map) -> Dict{String,Any}
computeWriters(ws, maps::AbstractVector{<:Map}; cores) -> Vector{Dict{String,Any}}
computeWriters(ws, path_or_atlas; cores, skip = 0, max = typemax(Int))
    -> iterator of (name, weight, values)
```

The same statistics on maps in memory, or streamed from a file in file order. Each value is a scalar or a
per-district vector indexed by the map's own district numbers, exactly as `addMapData` writes it. When streaming
with several threads, set `BLAS.set_num_threads(1)`.

```julia
ws = WriterSet(["get_log_spanning_trees", "get_partisan_margins"];
               graph = "CT_pct20.json", pop_col = "POP20", node_col = "NAME",
               vote_cols = [("G20PREDEM", "G20PREREP")])
maps = collect(eachMap("atlas.jsonl.gz"))
stats = computeWriters(ws, maps)                        # one Dict per map, in parallel
stats[1]["get_partisan_margins_G20PREDEM_G20PREREP"]    # district 1 first
for r in computeWriters(ws, "atlas.jsonl.gz")           # streamed
    println(r.name, " ", r.values["get_log_spanning_trees"])
end
```

Writers with a partition-free method are evaluated straight from the districting; the others on the map's
partition rebuilt as CycleWalk does at startup, which draws a random spanning tree per district. The values do
not depend on the tree, but their last digits can.

### `listWriters`, `listWriterDetails`, `loadGraph`

```julia
listWriters() -> Vector{String}
AtlasUtilities.listWriterDetails() -> (plain = [(name, fast), ...], partisan = [...])
AtlasUtilities.loadGraph(; <graph keywords of WriterSet>) -> the CycleWalk graph
```

`listWriters` gives the names `WriterSet` accepts (it runs every CycleWalk `get_*` writer once, so it takes a
moment). `listWriterDetails` also says which are fast (partition-free) and which are partisan.

## Worked example: relabeling in memory

```julia
using AtlasIO, AtlasUtilities

atlas = openAtlas(smartOpen("atlas.jsonl.gz", "r"))
d = Int(atlas.atlasParam["districts"])
ref = nextMap(atlas)
maps = Map[]
while !eof(atlas)
    global ref
    cur = nextMap(atlas)
    aligned = relabelMap(cur, findRelabeling(ref, cur, d))
    push!(maps, aligned)
    ref = aligned              # chain, as relabelAtlas does by default
end
close(atlas)
```

`relabelAtlas` does this from file to file, in parallel and with the multiscale and population options.
