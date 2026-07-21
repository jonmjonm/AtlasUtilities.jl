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

Base.@kwdef struct Map{T}
    name::String
    districting::Districting
    weight::Int64 = 1
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

`run_relabel` (and the other subcommand drivers, `run_info`/`run_add`/etc.)
are not exported — they're written for the CLI's file-in/file-out shape —
so call them qualified as `AtlasUtilities.run_relabel(...)` if you want that
behavior without going through `atlas` itself.
