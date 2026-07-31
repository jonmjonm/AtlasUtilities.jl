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
# The header entry holding the run's TOML config file's raw contents (see
# CycleWalk's `Writer(...; config_file)`). Omitted from the printed output and,
# like the script, written out by --extract-script when present.
const CONFIG_KEY = "toml_config"
# The header entry naming that TOML config file (used as the --extract-script
# output file), when the atlas-producing script recorded one.
const CONFIG_NAME_KEY = "toml_config_file"
# The header entry holding the sources of every file the generating script
# `include`s, as a name => source dict (CycleWalk >= 0.2.2 writes it alongside
# "script"). Like the script itself it is bulky -- tens of kilobytes of Julia --
# so it is omitted from the printed output and written out by --extract-script.
# Its companions "script_includes_unresolved"/"script_includes_skipped" are short
# lists of names and stay in the printed parameters.
const SCRIPT_INCLUDES_KEY = "script_includes"

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
    atlasInfo(atlasPathOrAtlas) -> Dict{String,Any}

Structured atlas metadata, for programmatic (library) use. Returns a dict with:
- `"header"`: description, date, map param type, weight type
- `"parameters"`: `atlas.atlasParam` verbatim (including the bulky `script` entry)
- `"map_data"`: the sorted field names found in the atlas's first map

Accepts either an already-open atlas (as returned by `AtlasIO.openAtlas`) or a
path/URL, which is opened via `smartOpen`/`openAtlas` and closed before
returning. `run_info` builds on this for display, stripping `script` and
formatting the rest.
"""
function atlasInfo(atlasPath::AbstractString)
    io = smartOpen(String(atlasPath), "r")
    atlas = openAtlas(io)
    info = atlasInfo(atlas)
    close(atlas)
    return info
end

function atlasInfo(atlas)
    fieldNames = something(firstMapFieldNames(atlas), String[])
    return Dict{String,Any}(
        "header" => Dict{String,Any}(
            "description"    => atlas.description,
            "date"           => atlas.date,
            "map param type" => string(atlas.mapParamType),
            "weight type"    => string(atlas.weightType),
        ),
        "parameters" => atlas.atlasParam,
        "map_data"   => fieldNames,
    )
end

"""
    atlasHeaderInfo(atlas, fieldNames = String[]) -> String

The atlas's header rendered as text: the "Atlas Header" block (description, date,
map/weight types, and -- when present -- a note that a run script and/or TOML
config are embedded and extractable), the "Atlas Parameters" block, and a
"Map Data Fields" block listing `fieldNames` (the field names found in the first
map, e.g. `log_spanning_trees`; see [`firstMapFieldNames`](@ref)), with the bulky
embedded generating `script`/`toml_config` entries omitted. This is exactly what
`atlas info` prints (minus the script/config bodies) and is reused verbatim in the
`about.md` that `atlas extract-map-data` writes alongside the CSVs.
"""
function atlasHeaderInfo(atlas, fieldNames::AbstractVector{<:AbstractString} = String[])
    param = atlas.atlasParam
    hdrPairs = Pair[
        "description"    => atlas.description,
        "date"           => atlas.date,
        "map param type" => string(atlas.mapParamType),
        "weight type"    => string(atlas.weightType),
    ]
    haskey(param, SCRIPT_KEY) &&
        push!(hdrPairs, "run script" => "embedded (extract with --extract-script)")
    if haskey(param, SCRIPT_INCLUDES_KEY)
        n = length(includedSources(param))
        push!(hdrPairs,
              "script includes" => "$n file(s) embedded (extract with --extract-script)")
    end
    haskey(param, CONFIG_KEY) &&
        push!(hdrPairs, "toml config" => "embedded (extract with --extract-script)")
    hdr = blockString("Atlas Header", hdrPairs)
    keysToShow = filter(k -> k != SCRIPT_KEY && k != CONFIG_KEY &&
                             k != SCRIPT_INCLUDES_KEY, collect(keys(param)))
    params = blockString("Atlas Parameters", Pair[k => param[k] for k in keysToShow])
    fields = nameListBlock("Map Data Fields", fieldNames)
    return hdr * params * fields
end

"""
    includedSources(param) -> Vector{Pair{String,String}}

The header's embedded include sources as `name => source` pairs, in header order,
or empty when the atlas records none. Tolerates a non-dict entry (an atlas written
by something other than CycleWalk) by returning nothing for it.
"""
function includedSources(param::AbstractDict)
    incs = get(param, SCRIPT_INCLUDES_KEY, nothing)
    incs isa AbstractDict || return Pair{String,String}[]
    return Pair{String,String}[string(k) => string(v) for (k, v) in incs]
end

"""
    extractName(name, fallback) -> String

The file name `--extract-script` writes an embedded entry recorded as `name` to:
its basename, so a recorded path -- CycleWalk records the TOML config under the
path it was invoked with, and an include under a path relative to its script,
which may climb out with `..` -- can only ever be written inside the current
directory, never back over the file it came from. Falls back to `fallback` for a
name with no usable basename.
"""
function extractName(name::AbstractString, fallback::AbstractString)
    base = basename(rstrip(String(name), ['/']))
    return (isempty(base) || all(==('.'), base)) ? fallback : base
end

"""
    writeExtracted(outName, body, what; force = false) -> Bool

Write an embedded header entry `body` to `outName` in the current directory,
reporting what happened, and return whether it was written. An existing file is
left alone unless `force` is set: extraction names its output after whatever the
run recorded, which can easily collide with a file already sitting there.
`what` names the entry in the messages (e.g. `"script"`).
"""
function writeExtracted(outName::AbstractString, body, what::AbstractString;
                        force::Bool = false)
    if isfile(outName) && !force
        msg = "--extract-script: $outName already exists; the $what entry was not " *
              "written (pass --force to overwrite)."
        println(msg)          # stdout, so it shows in the normal output too
        println(stderr, msg)  # stderr, for pipelines that only watch that stream
        return false
    end
    open(outName, "w") do f
        write(f, body)
    end
    println("Wrote $what entry to: ", outName)
    return true
end

"""
    run_info(atlasPath; extract_script = false, force = false)

Print the header of the atlas at `atlasPath`, plus the names of the data fields
found in its first map. With `extract_script = true`, also write out the embedded
sources the header carries, each into the current directory (never to the path the
run recorded it under, which would write back over the original file): the "script"
entry under its "script_name" (falling back to "extracted_script.jl"), the
"toml_config" entry under its "toml_config_file" (falling back to
"extracted_config.toml"), and every "script_includes" entry under its own name.
Warns if there is no script entry; the TOML config and the includes are optional
and extracted, silently, only when present. An existing file of the same name is
kept, and its entry skipped with a message, unless `force` is set.
"""
function run_info(atlasPath::AbstractString; extract_script::Bool = false,
                  force::Bool = false)
    io = smartOpen(String(atlasPath), "r")
    atlas = openAtlas(io)

    info = atlasInfo(atlas)
    param = info["parameters"]
    fieldNames = info["map_data"]

    # Header metadata (line 2) + atlas parameters (line 3), minus the script/config
    # sources, plus the first map's data field names.
    print(atlasHeaderInfo(atlas, fieldNames))

    if extract_script
        if haskey(param, SCRIPT_KEY)
            outName = extractName(string(get(param, SCRIPT_NAME_KEY, "")),
                                  "extracted_script.jl")
            writeExtracted(outName, param[SCRIPT_KEY], "script"; force = force)
        else
            msg = "--extract-script: this atlas has no \"$SCRIPT_KEY\" entry."
            println(msg)          # stdout, so it shows in the normal output too
            println(stderr, msg)  # stderr, for pipelines that only watch that stream
        end

        if haskey(param, CONFIG_KEY)
            outName = extractName(string(get(param, CONFIG_NAME_KEY, "")),
                                  "extracted_config.toml")
            writeExtracted(outName, param[CONFIG_KEY], "toml_config"; force = force)
        end

        # The script's includes, each under its own name. Two includes from
        # different directories can share a basename, so a name already taken by
        # one of them is disambiguated rather than silently overwritten.
        written = Set{String}()
        for (name, body) in includedSources(param)
            outName = extractName(name, "extracted_include.jl")
            if outName in written
                outName = replace(replace(String(name), ".." => "_"), '/' => '_')
            end
            writeExtracted(outName, body, "script_includes[$name]"; force = force) &&
                push!(written, outName)
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
