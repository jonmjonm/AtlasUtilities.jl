# info.jl -- reading an atlas header (`mapatlas info`, `mapatlas list-map-data`).
#
# `atlasInfo` returns the header (the metadata on line 2 and the atlas parameters on line 3) as data, and
# `atlasHeaderInfo` renders it as text. The bulky "script" entry -- the entire source of the script that generated
# the atlas -- is never rendered; `extractScripts` writes it out to its own file instead (named by the header's
# "script_name" entry), with the TOML config and the script's includes.

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
- `"header"`: description, date, map param type, weight type, format version (`"1"` or `"2"`)
- `"parameters"`: `atlas.atlasParam` verbatim (including the bulky `script` entry)
- `"map_data"`: the sorted field names found in the atlas's first map

Accepts either an already-open atlas (as returned by `AtlasIO.openAtlas`) or a
path/URL, which is opened via `smartOpen`/`openAtlas` and closed before
returning. [`atlasHeaderInfo`](@ref) renders the same information as text.
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
            "format version" => atlas.formatVersion,
        ),
        "parameters" => atlas.atlasParam,
        "map_data"   => fieldNames,
    )
end

"""
    atlasHeaderInfo(atlasPath) -> String
    atlasHeaderInfo(atlas, fieldNames = String[]) -> String

The atlas's header rendered as text: the "Atlas Header" block (description, date,
map/weight types, format version, and -- when present -- a note that a run script and/or TOML
config are embedded and extractable), the "Atlas Parameters" block, and a
"Map Data Fields" block listing `fieldNames` (the field names found in the first
map, e.g. `log_spanning_trees`; see [`firstMapFieldNames`](@ref)), with the bulky
embedded generating `script`/`toml_config` entries omitted. This is exactly what
`mapatlas info` prints (minus the script/config bodies) and is reused verbatim in the
`about.md` that `mapatlas extract-map-data` writes alongside the CSVs. Given a path, it opens the atlas and
lists its first map's fields.
"""
function atlasHeaderInfo(atlasPath::AbstractString)
    atlas = openAtlas(smartOpen(String(atlasPath), "r"))
    try
        return atlasHeaderInfo(atlas, something(firstMapFieldNames(atlas), String[]))
    finally
        close(atlas)
    end
end

function atlasHeaderInfo(atlas, fieldNames::AbstractVector{<:AbstractString} = String[])
    param = atlas.atlasParam
    hdrPairs = Pair[
        "description"    => atlas.description,
        "date"           => atlas.date,
        "map param type" => string(atlas.mapParamType),
        "weight type"    => string(atlas.weightType),
        "format version" => atlas.formatVersion,
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
    extractScripts(atlasPath, dir = pwd(); force = false)
        -> (written = Vector{String}, skipped = Vector{String}, entries = Vector{Pair{String,String}})

Write out the embedded sources the header of the atlas at `atlasPath` carries, each into `dir` (never to the path
the run recorded it under, which would write back over the original file): the "script" entry under its
"script_name" (falling back to "extracted_script.jl"), the "toml_config" entry under its "toml_config_file"
(falling back to "extracted_config.toml"), and every "script_includes" entry under its own name. Every entry gets a
file of its own: when two share a basename (two includes from different directories, or an include named like
the script), the later one is renamed, an include to its recorded path with `/` and `..` turned into `_`, otherwise
with a numeric suffix (`run_2.jl`). An existing file is kept, and its entry skipped, unless `force` is set.

Returns the paths `written` and `skipped`, and `entries`, every entry in the order handled as `entry => path`, with
`entry` one of `"script"`, `"toml_config"` or `"script_includes[<name>]"`. An atlas with no "script" entry has no
`"script"` in `entries`; the TOML config and the includes are optional.
"""
function extractScripts(atlasPath::AbstractString, dir::AbstractString = pwd(); force::Bool = false)
    param = atlasInfo(atlasPath)["parameters"]
    written, skipped = String[], String[]
    entries = Pair{String,String}[]
    function extract!(name, body, entry)
        path = joinpath(dir, name)
        push!(entries, entry => path)
        if isfile(path) && !force
            push!(skipped, path)
            return false
        end
        open(f -> write(f, body), path, "w")
        push!(written, path)
        return true
    end

    # Every entry gets a file name of its own: two entries can share a basename (two includes from different
    # directories, or an include named like the script), so a name already taken by an earlier entry is
    # disambiguated -- an include by its recorded path, flattened, then any entry by a numeric suffix -- rather
    # than overwritten or reported as skipped. The names depend only on the header, not on the files in `dir`.
    taken = Set{String}()
    function claim(name, alt = name)
        out = name in taken ? alt : name
        if out in taken
            stem, ext = splitext(out)
            k = 2
            while "$(stem)_$k$ext" in taken
                k += 1
            end
            out = "$(stem)_$k$ext"
        end
        push!(taken, out)
        return out
    end

    haskey(param, SCRIPT_KEY) &&
        extract!(claim(extractName(string(get(param, SCRIPT_NAME_KEY, "")), "extracted_script.jl")),
                 param[SCRIPT_KEY], "script")
    haskey(param, CONFIG_KEY) &&
        extract!(claim(extractName(string(get(param, CONFIG_NAME_KEY, "")), "extracted_config.toml")),
                 param[CONFIG_KEY], "toml_config")
    for (name, body) in includedSources(param)
        outName = claim(extractName(name, "extracted_include.jl"),
                        replace(replace(String(name), ".." => "_"), '/' => '_'))
        extract!(outName, body, "script_includes[$name]")
    end
    return (written = written, skipped = skipped, entries = entries)
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
