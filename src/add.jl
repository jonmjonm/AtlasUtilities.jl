# add.jl -- the `atlas add` subcommand.
#
# Read every map in an input atlas A1, reconstruct each map's LinkCutPartition on
# a supplied dual graph, evaluate one or more CycleWalk "pushable writer"
# functions on it (the very functions you would hand to `push_writer!` during a
# CycleWalk run), append their results to the map's data, and write the augmented
# maps to A2.
#
# A CycleWalk atlas stores only districtings (keys like `("DAVIDSON_18",)`), not
# the graph, so the graph and the columns needed to build it must be supplied
# externally -- via a CycleWalk TOML `--config`, via explicit column flags, or a
# mix (flags override / fill in the TOML). We then rebuild each map's partition
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

"""
    parseFunctionNames(s) -> Vector{String}

Parse the `functions` argument. Accepts a single name (`"get_log_spanning_trees"`),
a comma-separated list (`"a,b,c"`), or a bracketed list (`["a", "b"]`) -- so the
same argument covers the "single string" and "list of strings" forms. Surrounding
brackets, quotes and whitespace are stripped from each name.
"""
function parseFunctionNames(s::AbstractString)
    body = strip(s)
    body = strip(body, ['[', ']'])
    names = String[]
    for part in split(body, ',')
        name = strip(strip(part), ['"', '\'', ' '])
        isempty(name) || push!(names, String(name))
    end
    isempty(names) && error("atlas add: no writer function names were given.")
    return names
end

"""
    resolveFunctions(names) -> Vector{Tuple{String,Function}}

Map each name to the CycleWalk function it names (the function is looked up by
name in the `CycleWalk` module, exactly the set of names usable with
`push_writer!`). Each returned pair is `(desc, f)` where `desc` is the name used
as the map-data field, matching CycleWalk's own `push_writer!` default.
"""
function resolveFunctions(names::Vector{String})
    fns = Tuple{String,Function}[]
    for name in names
        sym = Symbol(name)
        isdefined(CycleWalk, sym) ||
            error("atlas add: CycleWalk has no name \"$name\"; it must be a " *
                  "function usable with push_writer!.")
        f = getfield(CycleWalk, sym)
        f isa Function ||
            error("atlas add: CycleWalk's \"$name\" is not a function.")
        push!(fns, (name, f))
    end
    return fns
end

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
    resolveGraphSpec(; config, graph, pop_col, node_col, area_col, border_col,
                       edge_perimeter_col, node_data) -> GraphSpec

Build the `GraphSpec` from an optional CycleWalk TOML `config` (its `[plans]`
table: `map_directory`/`map_file`, `pop_col`, `geo_units`, `area_col`,
`node_border_col`, `edge_perimeter_col`, `node_data`), then apply the CLI
overrides -- any non-empty flag replaces the corresponding TOML value, so the
flags can also stand alone with no TOML at all.
"""
function resolveGraphSpec(; config::AbstractString, graph::AbstractString,
                          pop_col::AbstractString, node_col::AbstractString,
                          area_col::AbstractString, border_col::AbstractString,
                          edge_perimeter_col::AbstractString,
                          node_data::AbstractString)
    path = ""
    pc = ""
    levels = String[]
    ac = nothing
    bc = nothing
    ec = nothing
    nd = Set{String}()

    if !isempty(config)
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

    # CLI overrides (a non-empty flag wins over / fills in the TOML).
    isempty(graph)              || (path = String(graph))
    isempty(pop_col)            || (pc = String(pop_col))
    isempty(node_col)           || (levels = [String(node_col)])
    isempty(area_col)           || (ac = String(area_col))
    isempty(border_col)         || (bc = String(border_col))
    isempty(edge_perimeter_col) || (ec = String(edge_perimeter_col))
    isempty(node_data)          || (nd = Set(String.(strip.(split(node_data, ',')))))

    isempty(path) && error("atlas add: no graph given; pass --graph or a --config " *
                           "whose [plans] has map_file.")
    isempty(pc)   && error("atlas add: no population column; pass --pop-col or " *
                           "[plans].pop_col in --config.")
    isempty(levels) && error("atlas add: no node column; pass --node-col or " *
                             "[plans].geo_units in --config.")

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

# ---------------------------------------------------------------------------
# Header provenance
# ---------------------------------------------------------------------------

"""
    writeHeaderWithProvenance(A1, A2, names, spec)

Write A2's header from A1's, re-emitting line 3 (the atlas params) with an
`"added map data"` provenance entry appended -- recording which fields were
added, from which graph, and when. Lines 1-2 are copied verbatim. The entry is
purely additive to the params dict, so older readers ignore it while `atlas info`
surfaces it; the declared `mapParamType` (`Dict{String,Any}`) is unchanged, since
adding keys to each map's data does not change its type.
"""
function writeHeaderWithProvenance(A1::AbstractString, A2::AbstractString,
                                   names::Vector{String}, spec::GraphSpec)
    src = smartOpen(String(A1), "r")
    line1 = readline(src)   # fixed description line
    line2 = readline(src)   # AtlasHeader
    line3 = readline(src)   # atlasParam
    close(src)

    atlasParam = JSON3.read(line3, Dict{String,Any})
    entry = Dict{String,Any}(
        "by"     => "atlas add",
        "fields" => names,
        "graph"  => spec.path,
        "date"   => string(Dates.now()),
    )
    prior = get(atlasParam, "added map data", nothing)
    log = prior === nothing ? Any[] : collect(Any, prior)
    push!(log, entry)
    atlasParam["added map data"] = log

    out = smartOpen(String(A2), "w")
    write(out, line1, "\n")
    write(out, line2, "\n")
    JSON3.write(out, atlasParam)
    write(out, "\n")
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
    any(iszero, σ) && error("atlas add: could not align reconstructed districts " *
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
# spanning tree `LinkCutPartition` draws. For those we can skip the
# `LinkCutPartition` build, which profiling shows is ~half of a reconstruction
# (drawing a random spanning tree per district and loading it into a link-cut /
# splay-tree structure), and evaluate the statistic directly from the
# `MultiLevelPartition`'s node-to-district map plus the finest `BaseGraph`'s
# `simple_graph`. On a real NC atlas this roughly halves `atlas add`'s per-map cost
# and reproduces the `LinkCutPartition` path bit-for-bit.
#
# A writer is "treeless" if it appears in `TREELESS_WRITERS`, mapping its name to
# `(node_to_dist, simple_graph, num_dists) -> value` in `MultiLevelPartition`
# district numbering (a length-`d` vector or a scalar), computed without any
# partition object. A request whose writers are ALL treeless takes the fast path;
# any non-treeless (or otherwise unrecognized) name falls back to the always-correct
# `LinkCutPartition` path (`evalWritersLCP`).

# CycleWalk exposes a low-level `get_log_spanning_trees(node_to_dist, simple_graph,
# di)` that scores one district straight from the assignment + graph -- no partition.
const _logSpanningTrees = getfield(CycleWalk, :get_log_spanning_trees)

const TREELESS_WRITERS = Dict{String,Function}(
    # per-district log spanning-tree counts (length-d vector)
    "get_log_spanning_trees" =>
        (n2d, sg, d) -> Float64[_logSpanningTrees(n2d, sg, di) for di in 1:d],
    # log spanning-FOREST count = sum over districts (a label-invariant scalar)
    "get_log_spanning_forests" =>
        (n2d, sg, d) -> sum(_logSpanningTrees(n2d, sg, di) for di in 1:d),
)

"""True if every `(desc, _)` writer in `fns` has a treeless variant."""
allTreeless(fns) = all(haskey(TREELESS_WRITERS, desc) for (desc, _) in fns)

"""
    fastPartitionData(g, m) -> (mlp, simple_graph, node_to_dist, σ)

Build only the `MultiLevelPartition` of map `m` on graph `g` (skipping the
`LinkCutPartition`) and derive the integer `node_to_dist` vector -- indexed by the
finest `BaseGraph`'s node order, the same ordering `simple_graph` uses -- together
with the alignment permutation `σ` from `MultiLevelPartition` district numbering
onto `m`'s districting labels. Node naming mirrors `labelPermutation`, so keys line
up with the districting keys the atlas was written with.
"""
function fastPartitionData(g, m)
    mlp  = MultiLevelPartition(g, m.districting)
    base = g.graphs_by_level[end]           # finest BaseGraph
    col  = g.levels[1]                       # node id column (as LinkCutPartition uses)
    d    = mlp.num_dists
    n2d  = Vector{Int}(undef, base.num_nodes)
    σ    = zeros(Int, d)
    for ni in 1:base.num_nodes
        key = (string(base.node_attributes[ni][col]),)
        di  = mlp.node_to_district[key]
        n2d[ni] = di
        σ[di]   = m.districting[key]         # mlp-district di -> map's districting label
    end
    any(iszero, σ) && error("atlas add: could not align reconstructed districts " *
                            "with map \"$(m.name)\"'s districting labels.")
    return (mlp, base.simple_graph, n2d, σ)
end

"""
    evalWritersTreeless(g, m, fns) -> Dict{String,Any}

Fast path of [`evalWriters`](@ref): every writer in `fns` must be treeless (see
`TREELESS_WRITERS`). Builds only the `MultiLevelPartition`, evaluates each writer
from `(node_to_dist, simple_graph, num_dists)`, and realigns per-district results
onto the map's districting labels. Returns `desc => value`.
"""
function evalWritersTreeless(g, m, fns)
    _, sg, n2d, σ = fastPartitionData(g, m)
    d = length(σ)
    out = Dict{String,Any}()
    for (desc, _) in fns
        out[desc] = alignResult(TREELESS_WRITERS[desc](n2d, sg, d), σ)
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
    evalWriters(g, m, fns) -> Dict{String,Any}

Evaluate each CycleWalk writer function in `fns` (a vector of `(desc, f)` pairs) on
map `m`, returning `desc => value` with every per-district result realigned onto the
map's districting labels (see `labelPermutation`/`alignResult`), so entry `i`
describes district `i` of the districting.

Dispatches on the requested writers: when they are all "treeless" (their statistic
does not need the random spanning tree, e.g. `get_log_spanning_trees`) it takes the
faster [`evalWritersTreeless`](@ref) path that skips the `LinkCutPartition` build;
otherwise it falls back to the always-correct [`evalWritersLCP`](@ref). Both paths
produce identical values. Shared by `atlas add` and `atlas extract-map-data`.
"""
evalWriters(g, m, fns) =
    allTreeless(fns) ? evalWritersTreeless(g, m, fns) : evalWritersLCP(g, m, fns)

# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------

"""
    run_add(functions, A1, A2; config, graph, pop_col, node_col, area_col,
            border_col, edge_perimeter_col, node_data, overwrite, quiet,
            cores = Threads.nthreads())

Add the CycleWalk writer function(s) named by `functions` to every map in atlas
`A1`, writing the augmented atlas to `A2`. The graph is described by `config`
and/or the column keyword arguments (see `resolveGraphSpec`). By default it is an
error for a requested field to already exist on a map; pass `overwrite = true` to
recompute it instead. `quiet` suppresses the progress bar.

The per-map work (parse -> reconstruct partition -> evaluate writers -> serialize)
is independent across maps and is threaded across `cores` tasks; maps are written
to `A2` serially in order. `cores` defaults to the threads Julia was started with,
so a single thread runs serially.
"""
function run_add(functions::AbstractString, A1::AbstractString, A2::AbstractString;
                 config::AbstractString = "", graph::AbstractString = "",
                 pop_col::AbstractString = "", node_col::AbstractString = "",
                 area_col::AbstractString = "", border_col::AbstractString = "",
                 edge_perimeter_col::AbstractString = "",
                 node_data::AbstractString = "",
                 overwrite::Bool = false, quiet::Bool = false,
                 cores::Int = Threads.nthreads())
    names = parseFunctionNames(functions)
    fns = resolveFunctions(names)
    spec = resolveGraphSpec(; config = config, graph = graph, pop_col = pop_col,
                            node_col = node_col, area_col = area_col,
                            border_col = border_col,
                            edge_perimeter_col = edge_perimeter_col,
                            node_data = node_data)
    g = buildGraph(spec)

    # Start A2 with A1's header plus a provenance stamp, then append maps to it.
    writeHeaderWithProvenance(String(A1), String(A2), names, spec)
    outIO = smartOpen(String(A2), "a")

    inIO = smartOpen(String(A1), "r")
    atlas = openAtlas(inIO)
    mpt, wt = atlas.mapParamType, atlas.weightType

    progress = quiet ? nothing :
               ProgressUnknown(desc = "Adding map data:", spinner = true)
    written = 0

    # Process maps in batches: read serially, then parse + reconstruct + evaluate +
    # serialize each map in parallel (into preallocated per-index slots), then write
    # the serialized bytes to A2 serially in map order.
    with_serial_blas() do
        while !eof(atlas)
            lines = String[]
            while length(lines) < BATCH && !eof(atlas)
                push!(lines, readline(atlas.io))
            end
            n = length(lines)
            n == 0 && break

            bytes = Vector{Vector{UInt8}}(undef, n)
            conflict = Vector{Union{Nothing,Tuple{String,String}}}(nothing, n)
            parallelDo!(n, cores) do i
                m = JSON3.read(lines[i], Map{mpt,wt})
                if !overwrite
                    for (desc, _) in fns
                        if haskey(m.data, desc)
                            conflict[i] = (m.name, desc)
                            return
                        end
                    end
                end
                for (desc, val) in evalWriters(g, m, fns)
                    m.data[desc] = val
                end
                buf = IOBuffer()
                addMap(buf, m)
                bytes[i] = take!(buf)
            end

            # Report the first field collision in reading order (if any).
            c = findfirst(!isnothing, conflict)
            if c !== nothing
                name, desc = conflict[c]
                error("atlas add: map \"$name\" already has field \"$desc\"; " *
                      "pass --overwrite to recompute it.")
            end

            for i in 1:n
                write(outIO, bytes[i])
            end
            written += n
            progress === nothing ||
                next!(progress; showvalues = [("maps written", written)])
        end
    end
    progress === nothing ||
        finish!(progress; showvalues = [("maps written", written)])

    close(atlas)
    close(outIO)
    return nothing
end
