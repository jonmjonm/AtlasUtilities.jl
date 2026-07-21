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

"""Render a titled block listing bare names (no values), one per line, sorted."""
function nameListBlock(title::String, names::AbstractVector{<:AbstractString})
    io = IOBuffer()
    println(io, title)
    println(io, "="^length(title))
    if isempty(names)
        println(io, "  (none)")
    else
        for n in sort(collect(names))
            println(io, "  ", n)
        end
    end
    println(io)
    return String(take!(io))
end

"""
    firstMapFieldNames(atlas) -> Union{Vector{String},Nothing}

The sorted names of the data fields (e.g. `log_spanning_trees`) contained in
`atlas`'s first map, or `nothing` if the atlas has no maps (as opposed to a map
whose data is empty, which returns `String[]`). Reads (consumes) the first map
from `atlas`'s stream.
"""
function firstMapFieldNames(atlas)
    eof(atlas) && return nothing
    m = nextMap(atlas)
    return sort(collect(keys(m.data)))
end

"""
    atlasHeaderInfo(atlas, fieldNames = String[]) -> String

The atlas's header rendered as text: the "Atlas Header" block (description, date,
map/weight types), the "Atlas Parameters" block, and a "Map Data Fields" block
listing `fieldNames` (the field names found in the first map, e.g.
`log_spanning_trees`; see [`firstMapFieldNames`](@ref)), with the bulky embedded
generating `script` entry omitted. This is exactly what `atlas info` prints (minus
the script) and is reused verbatim in the `about.md` that `atlas extract-map-data`
writes alongside the CSVs.
"""
function atlasHeaderInfo(atlas, fieldNames::AbstractVector{<:AbstractString} = String[])
    hdr = blockString("Atlas Header", Pair[
        "description"    => atlas.description,
        "date"           => atlas.date,
        "map param type" => string(atlas.mapParamType),
        "weight type"    => string(atlas.weightType),
    ])
    param = atlas.atlasParam
    keysToShow = filter(!isequal(SCRIPT_KEY), collect(keys(param)))
    params = blockString("Atlas Parameters", Pair[k => param[k] for k in keysToShow])
    fields = nameListBlock("Map Data Fields", fieldNames)
    return hdr * params * fields
end

"""
    run_info(atlasPath; extract_script = false)

Print the header of the atlas at `atlasPath`, plus the names of the data fields
found in its first map. With `extract_script = true`, also write the header's
"script" entry to a file named by its "script_name" entry (falling back to
"extracted_script.jl"); warns if there is no script entry.
"""
function run_info(atlasPath::AbstractString; extract_script::Bool = false)
    io = smartOpen(String(atlasPath), "r")
    atlas = openAtlas(io)

    param = atlas.atlasParam
    fieldNames = something(firstMapFieldNames(atlas), String[])

    # Header metadata (line 2) + atlas parameters (line 3), minus the script source,
    # plus the first map's data field names.
    print(atlasHeaderInfo(atlas, fieldNames))

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

"""
    listMapData(atlasPath) -> Union{Vector{String},Nothing}

The sorted names of the data fields (e.g. `log_spanning_trees`) contained in
the first map of the atlas at `atlasPath`, or `nothing` if the atlas has no
maps (as opposed to a map whose data is empty, which returns `String[]`).
"""
function listMapData(atlasPath::AbstractString)
    io = smartOpen(String(atlasPath), "r")
    atlas = openAtlas(io)
    fieldNames = firstMapFieldNames(atlas)
    close(atlas)
    return fieldNames
end

"""
    run_list_map_data(atlasPath)

Print the names of the data fields (e.g. `log_spanning_trees`) contained in the
first map of the atlas at `atlasPath`, one per line, sorted.
"""
function run_list_map_data(atlasPath::AbstractString)
    fieldNames = listMapData(atlasPath)
    if fieldNames === nothing
        println("atlas list-map-data: $atlasPath has no maps; nothing to list.")
    elseif isempty(fieldNames)
        println("atlas list-map-data: $atlasPath's first map has no data fields.")
    else
        foreach(println, fieldNames)
    end
    return nothing
end
