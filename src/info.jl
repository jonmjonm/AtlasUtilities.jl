# info.jl -- the `atlas info` subcommand.
#
# Read an Atlas file with AtlasIO.jl and print the information in its header
# (the header metadata on line 2 and the atlas parameters on line 3). The bulky
# "script" entry -- the entire source of the script that generated the atlas --
# is never printed; `extract_script` writes it out to its own file instead
# (named by the header's "script_name" entry).

# The header entry holding the generating script's full source. It is omitted
# from the printed output and is the entry written out by --extract-script.
const SCRIPT_KEY = "script"
# The header entry naming that script (used as the --extract-script output file).
const SCRIPT_NAME_KEY = "script_name"

"""
    formatValue(v; indent) -> String

Render a header value for display. Scalars print inline; nested dicts and arrays
are expanded one key/element per line, indented under their parent.
"""
function formatValue(v; indent::Int = 0)
    pad = "  "^(indent + 1)
    if v isa AbstractDict
        isempty(v) && return "{}"
        io = IOBuffer()
        for k in sort!(collect(keys(v)); by = string)
            print(io, "\n", pad, string(k), ": ", formatValue(v[k]; indent = indent + 1))
        end
        return String(take!(io))
    elseif v isa AbstractVector
        if any(e -> e isa AbstractDict || e isa AbstractVector, v)
            io = IOBuffer()
            for (i, e) in enumerate(v)
                print(io, "\n", pad, "[", i, "] ", formatValue(e; indent = indent + 1))
            end
            return String(take!(io))
        end
        return "[" * join((repr(e) for e in v), ", ") * "]"  # scalar array, one line
    else
        return repr(v)
    end
end

"""Print a titled block, `key: value` per entry, keys sorted alphabetically and
right-padded to align."""
function printBlock(title::String, pairs::Vector{<:Pair})
    println(title)
    println("="^length(title))
    isempty(pairs) && (println("  (none)"); println(); return)
    sort!(pairs; by = p -> string(first(p)))
    width = maximum(length(string(first(p))) for p in pairs)
    for (k, v) in pairs
        println("  ", rpad(string(k), width), " : ", formatValue(v))
    end
    println()
end

"""
    run_info(atlasPath; extract_script = false)

Print the header of the atlas at `atlasPath`. With `extract_script = true`, also
write the header's "script" entry to a file named by its "script_name" entry
(falling back to "extracted_script.jl"); warns if there is no script entry.
"""
function run_info(atlasPath::AbstractString; extract_script::Bool = false)
    io = smartOpen(String(atlasPath), "r")
    atlas = openAtlas(io)

    # Line 2: header metadata.
    printBlock("Atlas Header", Pair[
        "description"    => atlas.description,
        "date"           => atlas.date,
        "map param type" => string(atlas.mapParamType),
        "weight type"    => string(atlas.weightType),
    ])

    # Line 3: atlas parameters, minus the script source (printBlock sorts them).
    param = atlas.atlasParam
    keysToShow = filter(!isequal(SCRIPT_KEY), collect(keys(param)))
    printBlock("Atlas Parameters", Pair[k => param[k] for k in keysToShow])

    if extract_script
        if haskey(param, SCRIPT_KEY)
            outName = get(param, SCRIPT_NAME_KEY, "extracted_script.jl")
            open(outName, "w") do f
                write(f, param[SCRIPT_KEY])
            end
            println("Wrote script entry to: ", outName)
        else
            println(stderr, "--extract-script: this atlas has no \"$SCRIPT_KEY\" entry.")
        end
    end

    close(atlas)
    return nothing
end
