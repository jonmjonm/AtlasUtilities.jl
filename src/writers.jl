# writers.jl -- computing CycleWalk writer statistics on maps in memory: the library form of `atlas add`.
#
# A `WriterSet` resolves the writer names and builds the dual graph once (as `atlas add` does from its flags);
# `computeWriters` then evaluates them on a `Map`, a vector of maps, or every map of an atlas file (streamed),
# giving each field's value in the map's own district numbering, exactly as `atlas add` writes it.

"""
    WriterSet(functions; config = "", graph = "", pop_col = "", node_col = "", area_col = "", border_col = "",
              edge_perimeter_col = "", node_data = "", vote_cols = "")

CycleWalk writer functions ready to evaluate on maps with `computeWriters`, together with the dual graph they
need, built once. `functions` is a writer name, a vector of names, or a comma-separated list (as `atlas add`
takes); `listWriters()` gives the names. The graph is described as for `atlas add`: a CycleWalk TOML `config`
(its `[plans]` table) and/or the keywords, which override it (`graph` the dual-graph JSON, `pop_col`, `node_col`
the column the districting keys use, and the geometry columns some writers need). The partisan writers
(`get_partisan_margins`, `get_partisan_seats`) need `vote_cols`, `"votes1,votes2"` pairs separated by `;`; each
pair gives a field `<writer>_<votes1>_<votes2>` (see `writerFields`).
"""
struct WriterSet
    graph::Any                                  # the CycleWalk MultiLevelGraph
    writers::Vector{Tuple{String,Function}}     # (field, f(partition))
    treeless::Bool                              # every writer has the partition-free fast method
    graphPath::String
end

function WriterSet(functions::Union{AbstractString,AbstractVector{<:AbstractString}};
                   config::AbstractString = "", graph::AbstractString = "", pop_col::AbstractString = "",
                   node_col::AbstractString = "", area_col::AbstractString = "", border_col::AbstractString = "",
                   edge_perimeter_col::AbstractString = "", node_data::AbstractString = "",
                   vote_cols::AbstractString = "")
    names = functions isa AbstractString ? parseFunctionNames(functions) : String.(collect(functions))
    isempty(names) && error("no writer function names were given.")
    votePairs = parseVotePairs(vote_cols)
    writers = resolveFunctions(names, votePairs)
    spec = resolveGraphSpec(; config = config, graph = graph, pop_col = pop_col, node_col = node_col,
                            area_col = area_col, border_col = border_col, edge_perimeter_col = edge_perimeter_col,
                            node_data = node_data)
    union!(spec.node_data, Set(voteColumns(votePairs)))      # the partisan writers read the vote columns
    return WriterSet(buildGraph(spec), writers, allTreeless(writers), spec.path)
end

"""
    writerFields(ws::WriterSet) -> Vector{String}

The fields `computeWriters` returns, in order: each writer's name, with a partisan writer expanded to one field
per vote pair (`get_partisan_margins_<votes1>_<votes2>`).
"""
writerFields(ws::WriterSet) = [field for (field, _) in ws.writers]

"""
    computeWriters(ws::WriterSet, m::Map) -> Dict{String,Any}
    computeWriters(ws::WriterSet, maps::AbstractVector{<:Map}; cores = Threads.nthreads())
        -> Vector{Dict{String,Any}}

Evaluate the writers of `ws` on map `m`: each field (see `writerFields`) => its value, a per-district vector
indexed by the map's own district numbers (entry `i` describes district `i` of `m.districting`) or a scalar,
exactly the values `atlas add` writes into the map's data. The map's partition is rebuilt on the graph as
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
"""
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

function Base.show(io::IO, ws::WriterSet)
    print(io, "WriterSet(", join(writerFields(ws), ", "), "; graph = ", repr(basename(ws.graphPath)), ")")
end

"""
    listWriters() -> Vector{String}

The writer names `WriterSet` (and `atlas add`) accept, sorted: every CycleWalk `get_*` writer that runs on a
partition, and the partisan writers `get_partisan_margins` and `get_partisan_seats`, which need `vote_cols`.
"""
listWriters() = sort!(vcat(cycleWalkWriterNames(), collect(PARTISAN_WRITERS)))
