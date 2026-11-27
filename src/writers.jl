# writers.jl -- the writer API. The part that needs no CycleWalk is here: the `WriterSet` type, `writerFields`,
# its `show`, and the command-line string parsers. Everything that builds or evaluates a `WriterSet` (the
# CycleWalk graph, the writer functions, `addMapData`, `computeWriters`, ...) is in the AtlasUtilitiesCycleWalkExt
# extension (ext/), loaded with CycleWalk; the functions are declared and documented below.

"""
    WriterSet(functions; config = nothing, graph = nothing, pop_col = nothing, node_col = nothing,
              area_col = nothing, border_col = nothing, edge_perimeter_col = nothing, node_data = String[],
              vote_cols = Tuple{String,String}[])

CycleWalk writer functions ready to evaluate on maps with `computeWriters`, `addMapData`, `extractMapData` and
`mapDataHistograms`, together with the dual graph they need, built once. `functions` is a vector of writer names
(or a single name); `listWriters()` gives the names. The graph is described by a CycleWalk TOML `config` (its
`[plans]` table) and/or the keywords, which override it: `graph` the dual-graph JSON, `pop_col`, `node_col` the
column the districting keys use, the geometry columns some writers need (`area_col`, `border_col`,
`edge_perimeter_col`), and `node_data`, the node attributes to keep. The partisan writers (`get_partisan_margins`,
`get_partisan_seats`) need `vote_cols`, a vector of `(votes1, votes2)` column pairs, e.g.
`[("G20_PR_D", "G20_PR_R")]`; each pair gives a field `<writer>_<votes1>_<votes2>` (see `writerFields`).

Building one needs CycleWalk (`using CycleWalk`), which provides it through the AtlasUtilitiesCycleWalkExt
extension.
"""
struct WriterSet
    graph::Any                                  # the CycleWalk MultiLevelGraph
    writers::Vector{Tuple{String,Function}}     # (field, f(partition))
    treeless::Bool                              # every writer has the partition-free fast method
    graphPath::String
end

WriterSet(name::AbstractString; kw...) = WriterSet([name]; kw...)

"""
    writerFields(ws::WriterSet) -> Vector{String}

The fields `computeWriters` returns, in order: each writer's name, with a partisan writer expanded to one field
per vote pair (`get_partisan_margins_<votes1>_<votes2>`).
"""
writerFields(ws::WriterSet) = [field for (field, _) in ws.writers]

function Base.show(io::IO, ws::WriterSet)
    print(io, "WriterSet(", join(writerFields(ws), ", "), "; graph = ", repr(basename(ws.graphPath)), ")")
end

# ---------------------------------------------------------------------------
# Declared here, defined in the CycleWalk extension
# ---------------------------------------------------------------------------

"""
    addMapData(src, dst, ws::WriterSet; overwrite = false, cores = Threads.nthreads(), progress = false) -> Int
    addMapData(src, dst, functions; config, graph, pop_col, node_col, area_col, border_col, edge_perimeter_col,
               node_data, vote_cols, overwrite = false, cores = Threads.nthreads(), progress = false) -> Int

Add the values of the writers in `ws` (see [`WriterSet`](@ref)) to the data of every map in atlas `src`, writing
the augmented atlas to `dst`, and return the number of maps written. The second form builds the `WriterSet` from
the writer names `functions` and the graph keywords first. `dst`'s header is `src`'s, in the same format version,
with an `"added map data"` entry recording `"by": "addMapData"`, the AtlasUtilities version, the fields, the
graph and the date. By default it is an error for a
requested field to already exist on a map; pass `overwrite = true` to recompute it instead. `progress` shows a
progress bar.

The per-map work (parse -> reconstruct partition -> evaluate writers -> serialize)
is independent across maps and is threaded across `cores` tasks; maps are written
to `dst` serially in order. `cores` defaults to the threads Julia was started with,
so a single thread runs serially.

Needs CycleWalk (`using CycleWalk`), which provides it through the AtlasUtilitiesCycleWalkExt extension.
"""
function addMapData end

"""
    computeWriters(ws::WriterSet, m::Map) -> Dict{String,Any}
    computeWriters(ws::WriterSet, maps::AbstractVector{<:Map}; cores = Threads.nthreads())
        -> Vector{Dict{String,Any}}

Evaluate the writers of `ws` on map `m`: each field (see `writerFields`) => its value, a per-district vector
indexed by the map's own district numbers (entry `i` describes district `i` of `m.districting`) or a scalar,
exactly the values `addMapData` writes into the map's data. The map's partition is rebuilt on the graph as
CycleWalk does at startup (or skipped, for writers with a partition-free method); the statistics depend only on
the districting.

The vector form evaluates the maps in parallel across `cores` threads and returns the results in order.

    computeWriters(ws::WriterSet, path::AbstractString; cores = Threads.nthreads(), skip = 0, max = typemax(Int))
    computeWriters(ws::WriterSet, atlas::Atlas; ...)

The writers on every map of an atlas file (or an open `Atlas`), streamed: an iterator giving
`(name = m.name, weight = m.weight, values = computeWriters(ws, m))` for each map, in file order, with the maps
read and evaluated in parallel across `cores` tasks (AtlasIO's `eachMap(f, ...)`), so the whole atlas is never
in memory. `skip` maps are skipped first (a burn-in) and at most `max` are read; from a `path` the file is
closed when the last map has been read. With several threads, run it with BLAS on one thread
(`BLAS.set_num_threads(1)`; the vector form does this for you), or BLAS's threads compete with the tasks.

Needs CycleWalk (`using CycleWalk`), which provides it through the AtlasUtilitiesCycleWalkExt extension.
"""
function computeWriters end

"""
    listWriters() -> Vector{String}

The writer names `WriterSet` (and `addMapData`) accept, sorted: every CycleWalk `get_*` writer that runs on a
partition (see [`cycleWalkWriterNames`](@ref)), and the partisan writers `get_partisan_margins` and
`get_partisan_seats`, which need `vote_cols`.

Needs CycleWalk (`using CycleWalk`), which provides it through the AtlasUtilitiesCycleWalkExt extension.
"""
function listWriters end

"""
    listWriterDetails() -> (plain = Vector{Tuple{String,Bool}}, partisan = Vector{String})

The writers of [`listWriters`](@ref), in two groups, each sorted: `plain`, each writer's name and whether it is
fast (it offers the partition-free method `allTreeless`/`evalWritersTreeless` use, so no partition is rebuilt),
and `partisan`, the writers that also need `vote_cols`.

Needs CycleWalk (`using CycleWalk`), which provides it through the AtlasUtilitiesCycleWalkExt extension.
"""
function listWriterDetails end

"""
    loadGraph(; config = nothing, graph = nothing, pop_col = nothing, node_col = nothing, area_col = nothing,
              border_col = nothing, edge_perimeter_col = nothing, node_data = String[])

The CycleWalk dual graph (a `MultiLevelGraph`) described as for [`WriterSet`](@ref): a CycleWalk TOML `config`
(its `[plans]` table) and/or the keywords, which override it. The graph keeps the node attributes in `node_data`
plus the columns named by the other keywords.

Needs CycleWalk (`using CycleWalk`), which provides it through the AtlasUtilitiesCycleWalkExt extension.
"""
function loadGraph end

"""
    writerSubset(ws::WriterSet, fields) -> WriterSet

The writers of `ws` that give the fields in `fields` (a collection of field names), sharing its graph, with the
fast path chosen for them alone, as `addMapData` does. `extractMapData` builds it once per run, so a field whose
output file is kept is not computed.

Its method is in the CycleWalk extension; a `WriterSet` can only have been built with it loaded.
"""
function writerSubset end

# The functions above, and `WriterSet`'s constructor, as their error hint names them.
const CYCLEWALK_FUNCTIONS = (addMapData, computeWriters, listWriters, listWriterDetails, loadGraph, WriterSet)

"""
    cycleWalkHint(io, exc::MethodError, argtypes, kwargs)

The error hint for calling a function of `CYCLEWALK_FUNCTIONS` while CycleWalk is not loaded, so its
methods (in the AtlasUtilitiesCycleWalkExt extension) are missing: says to load CycleWalk.
"""
function cycleWalkHint(io, exc, argtypes, kwargs)
    f = exc.f
    f === Core.kwcall && length(exc.args) >= 2 && (f = exc.args[2])     # a call with keywords
    any(g -> f === g, CYCLEWALK_FUNCTIONS) || return
    Base.get_extension(@__MODULE__, :AtlasUtilitiesCycleWalkExt) === nothing || return
    print(io, "\n", nameof(f), " needs CycleWalk: run `using CycleWalk` (install with `Pkg.add(\"CycleWalk\")`).")
end

# ---------------------------------------------------------------------------
# Optional string keywords
# ---------------------------------------------------------------------------

"A keyword that names a file or a column, or is not given (`nothing`; an empty string counts as not given too)."
const OptString = Union{Nothing,AbstractString}

"Whether an [`OptString`](@ref) keyword was given."
isgiven(x) = x !== nothing && !isempty(x)
