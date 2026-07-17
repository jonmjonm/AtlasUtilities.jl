# `atlas reorder` — Specification

The `atlas reorder` command (from the AtlasUtilities package) steps over every
map in an input atlas **A1**, relabels district numbers so that consecutive maps
are as similar as possible, and writes the relabeled maps to a new atlas **A2**.

## Purpose

Districting maps in an atlas use district labels `1…d`, but those labels are
arbitrary: the same geographic district may be called `3` in one map and `1` in
the next. This script **canonicalizes the labels** so a district keeps a
consistent number as you step through the atlas, by choosing, for each map, the
label permutation that minimizes its distance to a reference map.

## Atlas format (from AtlasIO.jl)

An atlas is a JSONL file (`.jsonl`, `.jsonl.gz`, or `.jsonl.bz2`):

```
Line 1   comment identifying the file as an Atlas
Line 2   header metadata  {description, date, atlasParamType, mapParamType}
Line 3   atlas params      {..., "districts": d, ...}
Line 4+  one map per line  {name, weight, data, districting}
```

In Julia (AtlasIO.jl):

```julia
Districting = Dict{Tuple{Vararg{String}}, Int64}   # node key -> district label

Base.@kwdef struct Map{T}
    name::String
    districting::Districting
    weight::Int64 = 1
    data::T
end
```

The number of districts `d` is `atlas.atlasParam["districts"]`. The districting
keys (precinct-unit node identifiers) are identical across all maps in A1, which
is what makes a node-by-node comparison well defined.

## Distance

For a map, label `i ∈ {1…d}` defines the **set** of precinct-units assigned to it:

```
Dᵢ = { node : districting[node] == i }
```

Given a reference map with sets `(D₁,…,D_d)` and a current map with sets
`(D̂₁,…,D̂_d)`, the distance is the sum of per-district **Hamming** distances
(equal weight per precinct-unit):

```
distance = Σᵢ |Dᵢ Δ D̂ᵢ|        where Δ is symmetric difference
```

## reOrder

`reOrder(ref, cur)` returns a permutation `σ` of `{1…d}` such that relabeling
`cur`'s districts by `σ` minimizes `distance(ref, σ(cur))`. In `σ(cur)`, a node
whose label was `j` becomes `σ[j]`; the set carrying label `i` is `D̂_{σ⁻¹(i)}`,
so

```
distance(ref, σ(cur)) = Σᵢ |Dᵢ Δ D̂_{σ⁻¹(i)}|
```

### Algorithm (exact, optimal)

1. **Confusion matrix.** One pass over all nodes builds the `d×d` overlap matrix
   `O[i][j] = |Dᵢ ∩ D̂ⱼ|` via `O[ref[node]][cur[node]] += 1`.
2. **Assignment.** Because `Σᵢ|Dᵢ| = Σⱼ|D̂ⱼ| = N` is constant for any bijection,
   minimizing total Hamming distance is equivalent to **maximizing total
   overlap** `Σ O[i][j]` over a bijection `i ↔ j`. This is the linear assignment
   problem, solved optimally by the Hungarian algorithm (`Hungarian.jl`).
   We minimize the cost matrix `C = max(O) − O`.
3. **Build σ.** If the optimal matching pairs reference label `i` with current
   label `j`, then current label `j` must become `i`: `σ[j] = i`.

Greedy nearest-match is **not** used — it can double-assign labels; the global
assignment is required for optimality.

## Main loop

Map₁ is the **anchor**: it is copied to A2 verbatim and defines the label
convention the rest of the atlas is aligned to.

```
copy A1 header to A2
read map₁;  write map₁ to A2 verbatim
ref ← map₁

for m = 2 … M:
    σ ← reOrder(ref, mapₘ)
    r ← σ(mapₘ)                 # relabel districting values; keep name/weight/data
    write r to A2
    if not --firstMap:  ref ← r # chain: align next map to this reordered map
```

`σ(mapₘ)` changes only the districting label values; `name`, `weight`, and
`data` are preserved unchanged.

## Flags

- **(default)** Chained alignment: `ref` advances to the just-written reordered
  map each step, so each map is aligned to its reordered predecessor. Keeps
  labels locally consistent along the walk.
- **`--first-map`** Absolute alignment: `ref` stays fixed at map₁ for every map.
  Every map is aligned directly to the anchor. (If the walk drifts far from
  map₁, alignment quality can degrade and labels may jump — expected for this
  mode.)

## CLI

```
atlas reorder <A1> <A2> [<graph.json>] [--first-map] [--quiet]
```

- `<A1>` input atlas filename (any AtlasIO-supported extension)
- `<A2>` output atlas filename
- `<graph.json>` optional dual-graph hierarchy (see below); required for
  multiscale atlases whose per-map node sets vary
- `--first-map` optional; switches from chained to anchor alignment
- `--quiet` optional; suppresses the progress bar

Parsing/serialization runs across the threads Julia was started with. Because the
installed command runs on a prebuilt system image, set `JULIA_NUM_THREADS`
(e.g. `JULIA_NUM_THREADS=8 atlas reorder …`) to enable parallelism; the default
of one thread runs serially.

A progress bar (live count of maps written, on `stderr`) is shown by default
since the atlas header carries no map count; `--quiet` turns it off.

## Performance & threading

Profiling shows runtime is dominated (~80%) by **parsing the maps** — specifically
the thousands of stringified-tuple districting keys per map — which is per-map
independent. The reorder chain is only a few percent, and decompress/IO is
negligible. So maps are processed in **batches**:

```
read batch (serial, cheap)
  → parse batch        (parallel, the bottleneck)
  → reorder            (serial; the chain `ref` carries across batches)
  → serialize batch    (parallel)
  → write batch        (serial, in order)
```

The worker count is `Threads.nthreads()` — whatever Julia was started with via
`julia --threads=N` (or `--threads=auto`, or `JULIA_NUM_THREADS`). With a single
thread everything runs serially. Output is byte-for-byte identical regardless of
the thread count. Measured ~2.7× wall-clock at `--threads=8` on a 1000-map atlas
(more on larger atlases); the ceiling is bounded by the sequential read/write of
one compressed stream.

To exercise true parallelism in tests, run with threads: `julia --threads=4
test/runtests.jl`.

## Dependencies

`AtlasIO.jl`, `Hungarian.jl`, `JSON3.jl`, and `ProgressMeter.jl`, all added via
the Julia package manager. Threading uses `Base.Threads` (no extra dependency).

## Assumptions

- `d` (number of districts) is fixed across A1 and read from
  `atlas.atlasParam["districts"]`.
- All maps share the same districting node-key set.
- Every district `1…d` is non-empty in each map (true for valid districtings).

## Multiscale / hierarchical atlases (dual-graph hierarchy)

Some atlases (e.g. Metropolized Multiscale Forest ReCom runs) store each map at
the **coarsest resolution** where every unit is undivided: a whole county appears
as a single node `("GASTON",)` when it is not split, but as individual precincts
`("GASTON","01")…` when it is. Consequently **the node-key set varies from map to
map**, and the district-wise Hamming distance — which compares maps node-by-node
over a shared key set — is not directly defined.

Passing the **dual-graph JSON** as the third argument resolves this. The graph is
a NetworkX node-link file (e.g. `pct21_20cen_wMCD.json`) whose nodes carry the
hierarchy level attributes named in the atlas param `"levels in graph"`
(e.g. `["county","prec_id"]`). Each graph node is a finest-resolution unit keyed
by the tuple of its level values — the same tuple form as the districting keys.

`reOrder` then:

1. builds the list of finest units from the graph;
2. **resolves each map to the finest resolution** — a finest unit's label is the
   label of the longest prefix of its key present in the map (so a coarse node
   `("GASTON",)` covers every `("GASTON", prec)`);
3. computes the confusion matrix and assignment on these common-resolution label
   vectors.

`σ` is still applied to the map's **original** (possibly coarse) encoding, so A2
preserves the multiscale representation; only labels change. Without the JSON,
`reOrder` requires a fixed node set and raises a clear error if maps differ.

Verified on real 14-district NC congressional ReCom data (500 maps, 2650 finest
units): the anchor is written verbatim, every output map is a pure relabeling of
its source, and consecutive finest-unit label disagreement drops ~51% (chained
mode).
