# writers.jl -- the part of the writer API that needs no CycleWalk: the `WriterSet` type, `writerFields`, its
# `show`, and the command-line string parsers. Everything that builds or evaluates a `WriterSet` (the CycleWalk
# graph, the writer functions, `addMapData`, `computeWriters`, ...) is in add.jl.

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
# Command-line parsing (the library takes vectors)
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
    isempty(names) && error("no writer function names were given.")
    return names
end

"""
    parseVotePairs(s) -> Vector{Tuple{String,String}}

Parse the `--vote-cols` argument into `(votes1, votes2)` column pairs. Elections are
separated by `;`, the two columns of a pair by `,` -- e.g.
`"G20_PR_D,G20_PR_R;G16_PR_D,G16_PR_R"` gives two pairs. Empty input gives no pairs.
"""
function parseVotePairs(s::AbstractString)
    pairs = Tuple{String,String}[]
    for part in split(strip(s), ';')
        isempty(strip(part)) && continue
        cols = strip.(split(part, ','))
        length(cols) == 2 && all(!isempty, cols) ||
            error("vote-column pair \"$part\" (--vote-cols / vote_cols) must be exactly two " *
                  "comma-separated columns (votes1,votes2).")
        push!(pairs, (String(cols[1]), String(cols[2])))
    end
    return pairs
end

"""
    parseNodeData(s) -> Vector{String}

Parse the `--node-data` argument, a comma-separated list of node attributes; empty input gives none.
"""
parseNodeData(s::AbstractString) = isempty(s) ? String[] : String.(strip.(split(s, ',')))

# ---------------------------------------------------------------------------
# Optional string keywords
# ---------------------------------------------------------------------------

"A keyword that names a file or a column, or is not given (`nothing`; an empty string counts as not given too)."
const OptString = Union{Nothing,AbstractString}

"Whether an [`OptString`](@ref) keyword was given."
isgiven(x) = x !== nothing && !isempty(x)
