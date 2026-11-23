# `atlas convert`: convert an atlas between format versions 1 and 2 (AtlasIO's `convertAtlas`).

"""
    run_convert(src, dst; to = 2, quiet = false, cores = Threads.nthreads()) -> Int

Convert atlas `src` to format version `to` (1 or 2), writing `dst`, and return the number of maps. All the work
is AtlasIO's `convertAtlas`, which rewrites only the header's `formatVersion` and each map's assignment and
copies everything else byte for byte.
"""
function run_convert(src::AbstractString, dst::AbstractString; to::Integer = 2, quiet::Bool = false,
                     cores::Int = Threads.nthreads())
    to in (1, 2) || error("atlas convert: --to must be 1 or 2, got $to.")
    n = convertAtlas(String(src), String(dst); formatVersion = to, cores = cores)
    quiet || println("converted $n maps to format v$to: $dst")
    return n
end
