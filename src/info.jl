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

"""Render a titled block as a string, `key: value` per entry, keys sorted
alphabetically and right-padded to align."""
function blockString(title::String, pairs::Vector{<:Pair})
    io = IOBuffer()
    println(io, title)
    println(io, "="^length(title))
    if isempty(pairs)
        println(io, "  (none)")
        println(io)
        return String(take!(io))
    end
    sort!(pairs; by = p -> string(first(p)))
    width = maximum(length(string(first(p))) for p in pairs)
    for (k, v) in pairs
        println(io, "  ", rpad(string(k), width), " : ", formatValue(v))
    end
    println(io)
    return String(take!(io))
end

"""Print a titled block (see [`blockString`](@ref))."""
printBlock(title::String, pairs::Vector{<:Pair}) = print(blockString(title, pairs))

"""
    atlasHeaderInfo(atlas) -> String

The atlas's header rendered as text: the "Atlas Header" block (description, date,
map/weight types) followed by the "Atlas Parameters" block, with the bulky embedded
generating `script` entry omitted. This is exactly what `atlas info` prints (minus
the script) and is reused verbatim in the `about.md` that `atlas extract-map-data`
writes alongside the CSVs.
"""
function atlasHeaderInfo(atlas)
    hdr = blockString("Atlas Header", Pair[
        "description"    => atlas.description,
        "date"           => atlas.date,
        "map param type" => string(atlas.mapParamType),
        "weight type"    => string(atlas.weightType),
    ])
    param = atlas.atlasParam
    keysToShow = filter(!isequal(SCRIPT_KEY), collect(keys(param)))
    params = blockString("Atlas Parameters", Pair[k => param[k] for k in keysToShow])
    return hdr * params
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

    # Header metadata (line 2) + atlas parameters (line 3), minus the script source.
    print(atlasHeaderInfo(atlas))

    param = atlas.atlasParam
    if extract_script
        if haskey(param, SCRIPT_KEY)
            outName = get(param, SCRIPT_NAME_KEY, "extracted_script.jl")
            open(outName, "w") do f
                write(f, param[SCRIPT_KEY])
            end
            println("Wrote script entry to: ", outName)
        else
            msg = "--extract-script: this atlas has no \"$SCRIPT_KEY\" entry."
            println(msg)          # stdout, so it shows in the normal output too
            println(stderr, msg)  # stderr, for pipelines that only watch that stream
        end
    end

    close(atlas)
    return nothing
end
