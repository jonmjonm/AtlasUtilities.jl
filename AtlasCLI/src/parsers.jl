# parsers.jl -- the command line's string arguments (the library takes vectors).

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
