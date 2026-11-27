# output.jl -- writing an output file so that a failed run never leaves a partial file under its real name, and
# errors that say where in an atlas a damaged map is.

"""
    besidePath(path, tag) -> String

The name `path` with `.<tag>` before its extensions, so the name still says whether the file is compressed:
`besidePath("out.jsonl.gz", "tmp") == "out.tmp.jsonl.gz"`, likewise `out.csv.bz2` -> `out.tmp.csv.bz2`,
`out.csv` -> `out.tmp.csv` and `out` -> `out.tmp`.
"""
function besidePath(path::AbstractString, tag::AbstractString)
    m = match(r"(\.[A-Za-z0-9]+)?(\.gz|\.bz2)?$", path)
    return path[1:(end - length(m.match))] * "." * tag * m.match
end

"The temporary name `path` is written under (`out.tmp.jsonl.gz`); see [`writeReplacing`](@ref)."
tempPath(path::AbstractString) = besidePath(path, "tmp")

"Where `keep_partial = true` keeps what a failed run wrote to `path` (`out.incomplete.jsonl.gz`)."
incompletePath(path::AbstractString) = besidePath(path, "incomplete")

"""
    keepOrRemove(tmps, paths, keep_partial)

After a failed run: remove the temporary files `tmps`, or with `keep_partial` move each to the
[`incompletePath`](@ref) of its `paths` entry, with a warning naming them.
"""
function keepOrRemove(tmps, paths, keep_partial::Bool)
    kept = String[]
    for (tmp, path) in zip(tmps, paths)
        isfile(tmp) || continue
        if keep_partial
            mv(tmp, incompletePath(path); force = true)
            push!(kept, incompletePath(path))
        else
            rm(tmp; force = true)
        end
    end
    isempty(kept) || @warn "The run failed; what it wrote is kept (keep_partial = true): " * join(kept, ", ")
    return nothing
end

"""
    writeReplacing(f, path; keep_partial = false)

Write the file `path` through `f(tmp)`, which writes it (and closes it) under the temporary name `tmp` (see
[`tempPath`](@ref)). When `f` returns, `tmp` is moved onto `path`, replacing any file there, and `f`'s result is
returned. When `f` throws, `tmp` is removed and `path` is left as it was: a run that fails never leaves a partial
file under the real name, which a later run would take for finished output, and the input may be the output
(`relabelAtlas(a, a)`), as it is read whole before being replaced. With `keep_partial`, what was written is kept
under the [`incompletePath`](@ref) of `path` instead, for debugging.
"""
function writeReplacing(f, path::AbstractString; keep_partial::Bool = false)
    tmp = tempPath(path)
    try
        result = f(tmp)
        mv(tmp, path; force = true)
        return result
    catch
        keepOrRemove([tmp], [path], keep_partial)
        rethrow()
    end
end

# The lines before the first map of an atlas (its header): map `k` is on line `k + HEADER_LINES`.
const HEADER_LINES = 3

"""
    locateMapError(e, path, k) -> exception

The error `e`, raised reading map `k` (counted from 1 in the file) of the atlas at `path`, as the user should see
it. An `AtlasFormatError` (a map line that does not parse) says where: `"<path>, line <k + 3> (map <k>): ..."`, so
the line can be looked at (`gzip -dc <path> | sed -n <line>p`). Any other error is returned as it is.
"""
function locateMapError(e, path::AbstractString, k::Integer)
    e isa AtlasFormatError || return e
    startswith(e.msg, "$path, line ") && return e          # already located
    return AtlasFormatError("$path, line $(k + HEADER_LINES) (map $k): " * e.msg)
end

"""
    locatingErrors(f, path, k)

`f()`, with an `AtlasFormatError` it raises located (see [`locateMapError`](@ref)) at map `k()` of `path`: `k` is
called when the error is caught, so it can count the maps read so far. Other errors are rethrown unchanged, with
their backtrace. For a loop over AtlasIO's `eachMap`, which raises a map's error after giving the maps before it,
`k = () -> <maps consumed> + 1`.
"""
function locatingErrors(f, path::AbstractString, k)
    try
        return f()
    catch e
        e isa AtlasFormatError || rethrow()
        throw(locateMapError(e, path, k()))
    end
end
