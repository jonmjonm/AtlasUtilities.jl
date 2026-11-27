# writers.jl (AtlasUtilitiesCycleWalkExt) -- evaluating CycleWalk writer functions on maps: building a
# `WriterSet`, `computeWriters`, `addMapData` (`atlas add`), and the hook `extractMapData` and `mapDataHistograms`
# use. The functions are declared, with their docstrings, in AtlasUtilities' src/writers.jl.
#
# `addMapData` reads every map in an input atlas Atlas1, reconstructs each map's LinkCutPartition on
# a supplied dual graph, evaluate one or more CycleWalk "pushable writer"
# functions on it (the very functions you would hand to `push_writer!` during a
# CycleWalk run), append their results to the map's data, and write the augmented
# maps to Atlas2.
#
# A CycleWalk atlas stores only districtings (keys like `("DAVIDSON_18",)`), not
# the graph, so the graph and the columns needed to build it must be supplied
# externally -- via a CycleWalk TOML `config`, via explicit column keywords, or a
# mix (keywords override / fill in the TOML). We then rebuild each map's partition
# exactly as CycleWalk does at startup (`MultiLevelPartition(graph, districting)`
# followed by `LinkCutPartition(partition, rng)`) and evaluate `f(partition)` for
# each requested function -- the same call CycleWalk's writer makes in `output`.
#
# The added values are graph statistics of the districting (spanning-tree counts,
# isoperimetric ratios, ...), so they are independent of the random spanning tree
# `LinkCutPartition` picks; the reconstruction is deterministic in the map.

# ---------------------------------------------------------------------------
# Resolving the writer functions
# ---------------------------------------------------------------------------

# CycleWalk writers that need a pair of vote columns: they are not nullary
# `f(partition)` writers but are parameterized by two vote columns, and CycleWalk
# provides a `build_<name>(votes1, votes2)` factory returning the actual
# `f(partition)` closure. These are driven by `WriterSet`'s `vote_cols` keyword
# (`mapatlas`'s `--vote-cols`); each requested vote pair produces its own output field
# `<name>_<votes1>_<votes2>`.
const PARTISAN_WRITERS = Set(["get_partisan_margins", "get_partisan_seats"])

"""All distinct vote column names referenced by `votePairs` (for keeping on the graph)."""
voteColumns(votePairs) = unique!(String[c for p in votePairs for c in p])

"""
    resolveFunctions(names, votePairs = Tuple{String,String}[])
        -> Vector{Tuple{String,Function}}

Map each name to the CycleWalk writer it names, returning `(desc, f)` pairs where
`desc` is the map-data field and `f(partition)` computes it. A plain writer resolves
to `CycleWalk.<name>` directly (the set of names usable with `push_writer!`). A
"partisan" writer (see `PARTISAN_WRITERS`) is expanded once per vote pair in
`votePairs`: for pair `(v1, v2)` it builds `CycleWalk.build_<name>(v1, v2)` and emits
the field `<name>_<v1>_<v2>`; requesting one with no `votePairs` is an error.
"""
function resolveFunctions(names::AbstractVector{<:AbstractString},
                          votePairs::AbstractVector = Tuple{String,String}[])
    fns = Tuple{String,Function}[]
    for name in names
        if name in PARTISAN_WRITERS
            isempty(votePairs) &&
                error("WriterSet: \"$name\" needs vote columns; pass vote_cols = <pairs of vote columns>.")
            builder = getfield(CycleWalk, Symbol("build_" * name))
            for (v1, v2) in votePairs
                push!(fns, ("$(name)_$(v1)_$(v2)", builder(String(v1), String(v2))))
            end
            continue
        end
        sym = Symbol(name)
        isdefined(CycleWalk, sym) ||
            error("WriterSet: CycleWalk has no name \"$name\"; it must be a function usable with push_writer! " *
                  "(see `listWriters()`).")
        f = getfield(CycleWalk, sym)
        f isa Function ||
            error("WriterSet: CycleWalk's \"$name\" is not a function.")
        push!(fns, (String(name), f))
    end
    return fns
end

"""
    smokeTestPartition() -> LinkCutPartition

A tiny (4-node, 2-district) synthetic `LinkCutPartition`, built the same way
`evalWritersLCP` builds a real one (`Graph` -> `MultiLevelPartition` ->
`LinkCutPartition`), for probing whether a writer function actually runs (see
[`writerWorks`](@ref)) rather than merely having a matching method signature. Built
fresh (not cached) since it's only used for the rare `--list-writers` path; the
underlying `Graph`/`MultiLevelGraph` construction is the same cost `atlas add`
already pays once per real invocation.
"""
function smokeTestPartition()
    mktempdir() do dir
        gpath = joinpath(dir, "smoke_test_graph.json")
        # Two 2-node district trees (edges n0-n1, n2-n3) joined by one cross-district
        # edge (n1-n2) -- enough structure to exercise tree/degree/center/perimeter
        # writers without needing any real map data.
        write(gpath, """
            {"directed": false, "multigraph": false, "graph": [], "nodes": [
                {"id": 0, "NAME": "n0", "POP": 10, "area": 1.0, "border_length": 1.0},
                {"id": 1, "NAME": "n1", "POP": 10, "area": 1.0, "border_length": 1.0},
                {"id": 2, "NAME": "n2", "POP": 10, "area": 1.0, "border_length": 1.0},
                {"id": 3, "NAME": "n3", "POP": 10, "area": 1.0, "border_length": 1.0}
            ], "adjacency": [
                [{"id": 1, "length": 1.0}],
                [{"id": 0, "length": 1.0}, {"id": 2, "length": 1.0}],
                [{"id": 1, "length": 1.0}, {"id": 3, "length": 1.0}],
                [{"id": 2, "length": 1.0}]
            ]}
            """)
        g = buildGraph(GraphSpec(gpath, "POP", ["NAME"], "area", "border_length",
                                 "length", Set{String}()))
        districting = Districting(("n0",) => 1, ("n1",) => 1, ("n2",) => 2, ("n3",) => 2)
        return LinkCutPartition(MultiLevelPartition(g, districting))
    end
end

"""True if calling CycleWalk writer `f` on `partition` completes without throwing
(a runtime check, unlike `hasmethod` -- catches e.g. a writer whose body references
an undefined name, which type-checks fine but always errors when called)."""
function writerWorks(f, partition)
    try
        f(partition)
        return true
    catch
        return false
    end
end

"""
    cycleWalkWriterNames() -> Vector{String}

The names of plain CycleWalk writer functions usable with `atlas add` / `--add`:
every `get_*` function CycleWalk defines with a method accepting a single
`LinkCutPartition` (the object [`evalWritersLCP`](@ref) reconstructs and calls
`f(partition)` on) that actually runs without erroring on a real partition (see
[`writerWorks`](@ref)), sorted alphabetically. This is exactly the set of names
`atlas add`/`resolveFunctions` would accept AND successfully compute for a
non-partisan name -- computed by inspecting methods and smoke-testing rather than a
hard-coded list, so it stays correct as CycleWalk adds writers, fixes bugs, or
introduces new ones. Excludes writers that only accept some other representation
(e.g. `MultiLevelPartition`, a raw edge vector), since `atlas add` can't call those,
and excludes the partisan writers (see `PARTISAN_WRITERS`), which take vote columns
rather than a bare partition.
"""
function cycleWalkWriterNames()
    partition = smokeTestPartition()
    writerNames = String[]
    for n in names(CycleWalk; all = true)
        s = string(n)
        (startswith(s, "get_") && !(s in PARTISAN_WRITERS)) || continue
        isdefined(CycleWalk, n) || continue
        f = getfield(CycleWalk, n)
        f isa Function || continue
        hasmethod(f, Tuple{LinkCutPartition}) || continue
        writerWorks(f, partition) && push!(writerNames, s)
    end
    return sort!(writerNames)
end

listWriters() = sort!(vcat(cycleWalkWriterNames(), collect(PARTISAN_WRITERS)))

listWriterDetails() =
    (plain = [(n, hasFastMethod(getfield(CycleWalk, Symbol(n)))) for n in cycleWalkWriterNames()],
     partisan = sort(collect(PARTISAN_WRITERS)))

# ---------------------------------------------------------------------------
# Resolving the graph specification
# ---------------------------------------------------------------------------

"""
    GraphSpec

Everything needed to rebuild the dual graph the atlas was sampled on: the graph
JSON `path`, the population column `pop_col`, the hierarchy `levels` (the node id
column(s); the finest is what districting keys are keyed by), the optional
geometry columns, and the set of node attributes to keep.
"""
struct GraphSpec
    path::String
    pop_col::String
    levels::Vector{String}
    area_col::Union{String,Nothing}
    node_border_col::Union{String,Nothing}
    edge_perimeter_col::Union{String,Nothing}
    node_data::Set{String}
end

"""
    resolveGraphSpec(caller; config, graph, pop_col, node_col, area_col, border_col,
                     edge_perimeter_col, node_data) -> GraphSpec

Build the `GraphSpec` from an optional CycleWalk TOML `config` (its `[plans]`
table: `map_directory`/`map_file`, `pop_col`, `geo_units`, `area_col`,
`node_border_col`, `edge_perimeter_col`, `node_data`), then apply the keyword
overrides -- any one given (not `nothing` or empty) replaces the corresponding TOML value, so the
keywords can also stand alone with no TOML at all. `caller` names the function in the error messages.
"""
function resolveGraphSpec(caller::AbstractString = "loadGraph";
                          config::OptString = nothing, graph::OptString = nothing,
                          pop_col::OptString = nothing, node_col::OptString = nothing,
                          area_col::OptString = nothing, border_col::OptString = nothing,
                          edge_perimeter_col::OptString = nothing,
                          node_data::AbstractVector{<:AbstractString} = String[])
    path = ""
    pc = ""
    levels = String[]
    ac = nothing
    bc = nothing
    ec = nothing
    nd = Set{String}()

    if isgiven(config)
        params = TOML.parsefile(String(config))
        plans = get(params, "plans", Dict{String,Any}())
        if haskey(plans, "map_file")
            dir = String.(get(plans, "map_directory", String[]))
            path = joinpath(dir..., String(plans["map_file"]))
        end
        haskey(plans, "pop_col")            && (pc = String(plans["pop_col"]))
        haskey(plans, "geo_units")          && (levels = String.(plans["geo_units"]))
        haskey(plans, "area_col")           && (ac = String(plans["area_col"]))
        haskey(plans, "node_border_col")    && (bc = String(plans["node_border_col"]))
        haskey(plans, "edge_perimeter_col") && (ec = String(plans["edge_perimeter_col"]))
        haskey(plans, "node_data")          && (nd = Set(String.(plans["node_data"])))
    end

    # Keyword overrides (a given keyword wins over / fills in the TOML).
    isgiven(graph)              && (path = String(graph))
    isgiven(pop_col)            && (pc = String(pop_col))
    isgiven(node_col)           && (levels = [String(node_col)])
    isgiven(area_col)           && (ac = String(area_col))
    isgiven(border_col)         && (bc = String(border_col))
    isgiven(edge_perimeter_col) && (ec = String(edge_perimeter_col))
    isempty(node_data)          || (nd = Set(String.(node_data)))

    isempty(path) && error("$caller: no graph given; pass graph = <graph.json>, or config = <param.toml> " *
                           "whose [plans] has map_file.")
    isempty(pc)   && error("$caller: no population column; pass pop_col = <column>, or [plans].pop_col in " *
                           "the config.")
    isempty(levels) && error("$caller: no node column; pass node_col = <column>, or [plans].geo_units in " *
                             "the config.")

    # Make sure the graph keeps the columns the reconstruction and functions need.
    union!(nd, Set(levels))
    push!(nd, pc)
    ac !== nothing && push!(nd, ac)
    bc !== nothing && push!(nd, bc)

    return GraphSpec(path, pc, levels, ac, bc, ec, nd)
end

"""Build the CycleWalk dual graph described by `spec`."""
function buildGraph(spec::GraphSpec)
    return Graph(spec.path, spec.pop_col, spec.levels;
                 inc_node_data = spec.node_data,
                 area_col = spec.area_col,
                 node_border_col = spec.node_border_col,
                 edge_perimeter_col = spec.edge_perimeter_col)
end

loadGraph(; kw...) = buildGraph(resolveGraphSpec("loadGraph"; kw...))

# ---------------------------------------------------------------------------
# Header provenance
# ---------------------------------------------------------------------------

"""
    provenanceHeaderBytes(Atlas1, names, graphPath) -> Vector{UInt8}

Atlas1's header (its three lines) with an `"added map data"` provenance entry appended
to line 3 (the atlas params) -- recording which fields were added, from which graph,
and when -- returned as raw bytes ready to emit through an `AtlasOutput`. Lines 1-2
are copied verbatim. The entry is purely additive to the params dict, so older
readers ignore it while `atlas info` surfaces it; the declared `mapParamType`
(`Dict{String,Any}`) is unchanged, since adding keys to each map's data does not
change its type.
"""
function provenanceHeaderBytes(Atlas1::AbstractString, names::Vector{String}, graphPath::AbstractString)
    src = smartOpen(String(Atlas1), "r")
    line1 = readline(src)   # fixed description line
    line2 = readline(src)   # AtlasHeader
    line3 = readline(src)   # atlasParam
    close(src)

    # Parse with JSON.jl's order-preserving JSON.Object so the existing params are
    # written back unchanged: same key order, and exact numbers. (JSON3 into a Dict
    # scrambled the key order, read 0.0 back as 0, and corrupted integers beyond 2^53.)
    atlasParam = JSON.parse(line3)
    # "by" stays "atlas add" (what earlier versions wrote), whether from the command or `addMapData`.
    entry = (by = "atlas add", fields = names, graph = String(graphPath), date = string(Dates.now()))
    prior = get(atlasParam, "added map data", nothing)
    log = prior === nothing ? Any[] : collect(Any, prior)
    push!(log, entry)
    atlasParam["added map data"] = log

    buf = IOBuffer()
    write(buf, line1, "\n")
    write(buf, line2, "\n")
    JSON.json(buf, atlasParam)
    write(buf, "\n")
    return take!(buf)
end

"""
    writeHeaderWithProvenance(Atlas1, Atlas2, names, graphPath)

Write Atlas2's header from Atlas1's with the `atlas add` provenance stamp (see
[`provenanceHeaderBytes`](@ref)), through a plain/compressed stream chosen by Atlas2's
extension. Used on its own (e.g. in tests); `addMapData` instead feeds the same header
bytes to an `AtlasOutput`.
"""
function writeHeaderWithProvenance(Atlas1::AbstractString, Atlas2::AbstractString,
                                   names::Vector{String}, graphPath::AbstractString)
    out = smartOpen(String(Atlas2), "w")
    write(out, provenanceHeaderBytes(String(Atlas1), names, graphPath))
    close(out)
    return nothing
end

# ---------------------------------------------------------------------------
# District-label alignment
# ---------------------------------------------------------------------------

"""
    labelPermutation(partition, m) -> Vector{Int}

The permutation `σ` for which reconstructed-district `j` is the same set of nodes
as the map's own districting label `σ[j]`. `LinkCutPartition` numbers districts by
its internal root-discovery order, which need not match the labels stored in the
map's districting, so this recovers the correspondence. Node naming here mirrors
CycleWalk's own `get_node_map` (`partition.graph.node_attributes[ni][node_col]`),
so the keys line up with the districting keys the atlas was written with.
"""
function labelPermutation(partition, m)
    d = partition.num_dists
    graph = partition.graph
    col = partition.node_col
    σ = zeros(Int, d)
    for ni in 1:graph.num_nodes
        key = (string(graph.node_attributes[ni][col]),)
        σ[partition.node_to_dist[ni]] = m.districting[key]
    end
    any(iszero, σ) && error("could not align reconstructed districts " *
                            "with map \"$(m.name)\"'s districting labels.")
    return σ
end

"""
    alignResult(val, σ) -> val'

Reorder a per-district result from reconstructed labels onto the map's districting
labels: a length-`d` vector `v` becomes `v′` with `v′[σ[j]] = v[j]`. Anything that
is not a length-`d` vector (e.g. a scalar, which is label-invariant) is returned
unchanged.
"""
function alignResult(val, σ::Vector{Int})
    (val isa AbstractVector && length(val) == length(σ)) || return val
    aligned = similar(val)
    @inbounds for j in eachindex(σ)
        aligned[σ[j]] = val[j]
    end
    return aligned
end

# ---------------------------------------------------------------------------
# Treeless fast path
# ---------------------------------------------------------------------------
#
# Most writer statistics are deterministic functions of the districting (which
# nodes lie in which district) and the graph -- they do NOT depend on the random
# spanning tree `LinkCutPartition` draws. For those we can skip BOTH reconstruction
# steps that dominate a rebuild: the `LinkCutPartition` (drawing a random spanning
# tree per district and loading it into a link-cut / splay-tree structure, ~56% of
# per-map cost) AND the `MultiLevelPartition` (building per-district subgraphs,
# vmaps, populations and cross-district edges, ~32%). Instead we resolve each finest
# node straight to its districting label with `coverLabel` (from relabel.jl) and call
# the writer on that `node_to_dist` plus the finest `BaseGraph`. This reproduces the
# `LinkCutPartition` path (to machine precision) while building no partition at all.
#
# Dispatch is by CONVENTION, not a hard-coded name list: a CycleWalk writer offers a
# fast path iff it defines a method with the uniform signature
# `f(node_to_dist::Vector{Int}, ::BaseGraph, num_dists::Int)` -- the partition-free
# form that returns per-district values in `node_to_dist`'s own numbering. We simply
# ask each requested function whether it has that method (`hasFastMethod`). A request
# whose writers ALL have it takes the fast path; anything else (a writer with only the
# `LinkCutPartition` method, or an unrecognized one) falls back to the always-correct
# `evalWritersLCP`. Any writer CycleWalk later gives a partition-free method to is then
# picked up automatically, with no change here.

# The uniform partition-free signature a writer must provide to be fast.
const _FAST_SIG = Tuple{Vector{Int}, CycleWalk.BaseGraph, Int}

"""True if CycleWalk writer `f` provides the partition-free `(node_to_dist, ::BaseGraph,
num_dists)` method (checked once via `hasmethod`, no call made)."""
hasFastMethod(f) = hasmethod(f, _FAST_SIG)

"""True if every writer in `fns` (a vector of `(desc, f)` pairs) has the partition-free
fast method, so the whole request can take `evalWritersTreeless`."""
allTreeless(fns) = all(hasFastMethod(f) for (_, f) in fns)

"""
    nodeToDist(g, m) -> (base_graph, node_to_dist, num_dists)

Resolve map `m`'s districting to an integer node-to-district vector on graph `g`
WITHOUT building a `MultiLevelPartition` or `LinkCutPartition`. Each finest
`BaseGraph` node is mapped to its district straight from `m.districting` via
`coverLabel`, which matches the node's level-value tuple (over `g.levels`) against
the districting keys -- so a coarse districting key (e.g. a whole county) covers all
of its finest units, exactly as `relabel.jl` resolves multiscale maps. `coverLabel`
returns the districting's own label, so `node_to_dist` is already in the map's
district numbering and needs no realignment.

Returns the finest `BaseGraph`, the `node_to_dist` vector (indexed by base-graph node
order, matching the graph's vertices), and the district count (the largest label; a
districting partitions all nodes into contiguously-numbered, nonempty districts, so
this is the number of districts).
"""
function nodeToDist(g, m)
    base   = g.graphs_by_level[end]          # finest BaseGraph
    levels = g.levels
    n2d    = Vector{Int}(undef, base.num_nodes)
    for ni in 1:base.num_nodes
        key = Tuple(string(base.node_attributes[ni][lev]) for lev in levels)
        n2d[ni] = coverLabel(m.districting, key)
    end
    return (base, n2d, maximum(n2d))
end

"""
    evalWritersTreeless(g, m, fns) -> Dict{String,Any}

Fast path of [`evalWriters`](@ref): every writer in `fns` must provide the
partition-free method (see `hasFastMethod`). Resolves the districting to
`node_to_dist` with `nodeToDist` (no partition object built) and calls each writer as
`f(node_to_dist, base_graph, num_dists)`. The result is already in the map's district
numbering, so no realignment is needed. Returns `desc => value`.
"""
function evalWritersTreeless(g, m, fns)
    base, n2d, d = nodeToDist(g, m)
    out = Dict{String,Any}()
    for (desc, f) in fns
        out[desc] = f(n2d, base, d)
    end
    return out
end

"""
    evalWritersLCP(g, m, fns) -> Dict{String,Any}

General (always-correct) path of [`evalWriters`](@ref): reconstruct `m`'s partition
on graph `g` exactly as CycleWalk does at startup (`MultiLevelPartition(g,
districting)` -> `LinkCutPartition`) and evaluate `f(partition)` the way CycleWalk's
`output` does, realigning per-district results onto the map's districting labels.
The partition is rebuilt once and all functions share it; the statistics depend only
on the districting, not on the random spanning tree, so the default RNG is fine.
"""
function evalWritersLCP(g, m, fns)
    partition = LinkCutPartition(MultiLevelPartition(g, m.districting))
    σ = labelPermutation(partition, m)
    out = Dict{String,Any}()
    for (desc, f) in fns
        out[desc] = alignResult(f(partition), σ)
    end
    return out
end

"""
    evalWriters(g, m, fns; treeless = allTreeless(fns)) -> Dict{String,Any}

Evaluate each CycleWalk writer function in `fns` (a vector of `(desc, f)` pairs) on
map `m`, returning `desc => value` with entry `i` describing district `i` of the
districting.

When every writer offers the partition-free method (`treeless`, the default,
determined by [`allTreeless`](@ref)) it takes the faster [`evalWritersTreeless`](@ref)
path that builds no partition object at all; otherwise it falls back to the
always-correct [`evalWritersLCP`](@ref) (which realigns per-district results via
`labelPermutation`/`alignResult`). Both paths agree to machine precision. The `treeless`
decision depends only on `fns`, so the drivers resolve it once per run and pass it in;
callers may omit it. Shared by `addMapData`, `computeWriters`, `extractMapData` and `mapDataHistograms`.
"""
evalWriters(g, m, fns; treeless::Bool = allTreeless(fns)) =
    treeless ? evalWritersTreeless(g, m, fns) : evalWritersLCP(g, m, fns)

# ---------------------------------------------------------------------------
# WriterSet and computeWriters
# ---------------------------------------------------------------------------

function WriterSet(functions::AbstractVector{<:AbstractString};
                   config::OptString = nothing, graph::OptString = nothing, pop_col::OptString = nothing,
                   node_col::OptString = nothing, area_col::OptString = nothing, border_col::OptString = nothing,
                   edge_perimeter_col::OptString = nothing,
                   node_data::AbstractVector{<:AbstractString} = String[],
                   vote_cols::AbstractVector = Tuple{String,String}[])
    isempty(functions) && error("WriterSet: no writer function names were given.")
    for p in vote_cols
        (p isa Tuple{AbstractString,AbstractString}) ||
            error("WriterSet: vote_cols = must be a vector of (votes1, votes2) column pairs, got $(repr(p)).")
    end
    writers = resolveFunctions(functions, vote_cols)
    spec = resolveGraphSpec("WriterSet"; config, graph, pop_col, node_col, area_col, border_col,
                            edge_perimeter_col, node_data)
    union!(spec.node_data, Set(voteColumns(vote_cols)))      # the partisan writers read the vote columns
    return WriterSet(buildGraph(spec), writers, allTreeless(writers), spec.path)
end

computeWriters(ws::WriterSet, m::Map) = evalWriters(ws.graph, m, ws.writers; treeless = ws.treeless)

function computeWriters(ws::WriterSet, maps::AbstractVector{<:Map}; cores::Int = Threads.nthreads())
    out = Vector{Dict{String,Any}}(undef, length(maps))
    with_serial_blas() do
        parallelDo!(length(maps), cores) do i
            out[i] = computeWriters(ws, maps[i])
        end
    end
    return out
end

computeWriters(ws::WriterSet, source::Union{AbstractString,Atlas}; cores::Int = Threads.nthreads(),
               skip::Integer = 0, max::Integer = typemax(Int)) =
    eachMap(m -> (name = m.name, weight = m.weight, values = computeWriters(ws, m)), source;
            ntasks = cores, skip = skip, max = max)

function evalWriterSet(ws::WriterSet, m, fields = nothing)
    fields === nothing && return computeWriters(ws, m)
    fns = [(n, f) for (n, f) in ws.writers if n in fields]
    isempty(fns) && return Dict{String,Any}()
    return evalWriters(ws.graph, m, fns)
end

# ---------------------------------------------------------------------------
# addMapData
# ---------------------------------------------------------------------------

function addMapData(src::AbstractString, dst::AbstractString, ws::WriterSet;
                    overwrite::Bool = false, progress::Bool = false, cores::Int = Threads.nthreads())
    fns = ws.writers
    treeless = ws.treeless      # fast-path decision depends only on fns; resolved once
    g = ws.graph

    # Start dst with src's header plus a provenance stamp (the actual field names, so
    # expanded partisan fields are recorded), then append maps to it. For .gz output,
    # `AtlasOutput` compresses the map body as byte-targeted gzip members in parallel
    # (the serial write is only raw I/O); plain/.bz2 stream as before.
    header = provenanceHeaderBytes(String(src), writerFields(ws), ws.graphPath)
    outIO = openAtlasOutput(String(dst), header, cores)

    inIO = smartOpen(String(src), "r")
    atlas = openAtlas(inIO)
    fv = atlas.formatVersion    # dst's header comes from src's, so its maps must be in the same version

    bar = progress ? ProgressUnknown(desc = "Adding map data:", spinner = true) : nothing
    written = 0

    # Per map, parse + reconstruct + evaluate + serialize in parallel (AtlasIO's
    # `eachMap(f, ...)`), then write the serialized bytes to dst in map order,
    # BATCH maps per `writeMaps!` (which gzips a batch in parallel). A field that is
    # already there (without `overwrite`) is an error meant for the user: it is
    # returned as a `CapturedError` and raised here, at the first such map.
    function addTo(m)
        if !overwrite
            for (desc, _) in fns
                haskey(m.data, desc) &&
                    return CapturedError(ErrorException("addMapData: map \"$(m.name)\" already has field " *
                                                        "\"$desc\"; pass overwrite = true to recompute it."))
            end
        end
        for (desc, val) in evalWriters(g, m, fns; treeless = treeless)
            m.data[desc] = val
        end
        buf = IOBuffer()
        addMap(buf, m; formatVersion = fv)
        return take!(buf)
    end
    bytes = Vector{UInt8}[]
    try
        with_serial_blas() do
            for b in eachMap(addTo, atlas; ntasks = cores)
                raiseCaptured(b)
                push!(bytes, b)
                if length(bytes) == BATCH
                    writeMaps!(outIO, bytes)
                    empty!(bytes)
                end
                written += 1
                bar === nothing || next!(bar; showvalues = [("maps written", written)])
            end
            isempty(bytes) || writeMaps!(outIO, bytes)
        end
        bar === nothing || finish!(bar; showvalues = [("maps written", written)])
    finally
        close(atlas)
        close(outIO)
    end
    return written
end

function addMapData(src::AbstractString, dst::AbstractString,
                    functions::Union{AbstractString,AbstractVector{<:AbstractString}};
                    overwrite::Bool = false, progress::Bool = false, cores::Int = Threads.nthreads(), kw...)
    return addMapData(src, dst, WriterSet(functions; kw...); overwrite, progress, cores)
end
