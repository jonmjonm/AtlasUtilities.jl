# reorder.jl -- the `atlas relabel` subcommand.
#
# Walk every map in an input atlas Atlas1, relabel district numbers so consecutive
# maps are as similar as possible, and write the relabeled maps to a new atlas Atlas2.
#
# Parsing the maps dominates runtime (~80%) and is per-map independent, so it is
# threaded across however many threads Julia was started with (`julia --threads=N`,
# or the JULIA_NUM_THREADS env var); with a single thread it runs serially. The
# reorder chain is serial but cheap. Maps are processed in batches:
# read (serial) -> parse (parallel) -> reorder (serial) -> serialize (parallel) ->
# write (serial, in order).
#
# See relabel.md for the full specification.

# ---------------------------------------------------------------------------
# Dual-graph hierarchy (for multiscale atlases)
# ---------------------------------------------------------------------------

"""
    Hierarchy(levels, finest)

`levels` are the hierarchy attribute names, finest last (e.g. `["county","prec_id"]`,
read from the atlas param `"levels in graph"`). `finest` is the list of every
finest-resolution unit as a tuple of its level values, in a fixed order — the
common resolution to which all maps are resolved.
"""
struct Hierarchy
    levels::Vector{String}
    finest::Vector{Tuple{Vararg{String}}}
end

"""
    loadHierarchy(jsonPath, levels) -> Hierarchy

Load the dual-graph JSON (NetworkX node-link format) and build the finest-unit
list. Each graph node carries the level attributes (e.g. `county`, `prec_id`);
its finest-unit key is the tuple of those attribute values, matching the
districting key tuples in the atlas.
"""
function loadHierarchy(jsonPath::AbstractString, levels)
    levs = String.(levels)
    io = smartOpen(String(jsonPath), "r")
    graph = JSON3.read(read(io, String))
    close(io)
    finest = Tuple{Vararg{String}}[
        Tuple(string(node[Symbol(l)]) for l in levs) for node in graph.nodes
    ]
    return Hierarchy(levs, finest)
end

"""
    coverLabel(districting, t) -> Int

District label of the finest unit `t` in a (possibly coarse) map: the label of
the longest prefix of `t` that appears as a node in `districting`. A coarse node
like `("GASTON",)` covers every finest unit `("GASTON", prec)`.
"""
function coverLabel(districting::Districting, t::Tuple)
    for L in length(t):-1:1
        key = t[1:L]
        haskey(districting, key) && return districting[key]
    end
    error("dual graph: finest unit $t is not covered by any node in the map; " *
          "atlas node keys must be prefixes of the graph levels.")
end

"""Resolve a map's districting to a label vector over the hierarchy's finest units."""
expandLabels(h::Hierarchy, districting::Districting) =
    Int[coverLabel(districting, t) for t in h.finest]

# ---------------------------------------------------------------------------
# Reordering
# ---------------------------------------------------------------------------

"""
    permutationFromConfusion(O, d) -> Vector{Int}

Given confusion matrix `O[i,j] = overlap(ref district i, cur district j)`, return
the permutation `σ` (`σ[j] = i`) that maximizes total matched overlap — i.e.
minimizes the district-wise Hamming distance — via linear assignment.
"""
function permutationFromConfusion(O::Matrix{Int}, d::Int)
    cost = maximum(O) .- O                  # maximize overlap == minimize this cost
    assignment, _ = hungarian(cost)         # assignment[i] = cur label j matched to ref label i
    σ = Vector{Int}(undef, d)
    for i in 1:d
        σ[assignment[i]] = i                # cur label j should become ref label i
    end
    return σ
end

"""
    reOrder(ref::Map, cur::Map, d::Int) -> Vector{Int}

Permutation `σ` of `1:d` minimizing the district-wise Hamming distance between
`ref` and the relabeled `cur` (a node whose label was `j` becomes `σ[j]`).
Requires both maps to share the same node-key set (fixed-resolution atlas).
"""
function reOrder(ref::Map, cur::Map, d::Int)
    if keys(ref.districting) != keys(cur.districting)
        error("reOrder: maps \"$(ref.name)\" and \"$(cur.name)\" are expressed over " *
              "different node-key sets ($(length(ref.districting)) vs " *
              "$(length(cur.districting)) nodes). This atlas appears to use a " *
              "multiscale/hierarchical encoding; pass the dual-graph JSON so maps " *
              "can be resolved to a common (finest) resolution.")
    end
    O = zeros(Int, d, d)                    # O[i,j] = |{node : ref=i and cur=j}|
    for (node, j) in cur.districting
        O[ref.districting[node], j] += 1
    end
    return permutationFromConfusion(O, d)
end

"""
    reOrder(ref::Map, cur::Map, d::Int, h::Hierarchy) -> Vector{Int}

Multiscale variant: resolve both maps to the hierarchy's finest units, then
align on the finest-resolution confusion matrix. Node sets may differ between
the two maps.
"""
function reOrder(ref::Map, cur::Map, d::Int, h::Hierarchy)
    refL = expandLabels(h, ref.districting)
    curL = expandLabels(h, cur.districting)
    O = zeros(Int, d, d)
    for k in eachindex(refL, curL)
        O[refL[k], curL[k]] += 1
    end
    return permutationFromConfusion(O, d)
end

"""
    relabelMap(m::Map, σ::Vector{Int}) -> Map

`m` with districting values relabeled by `σ` (`j -> σ[j]`), preserving
name/weight/data and the map's original (possibly coarse) node-key encoding.
Mutates `m.districting`'s values in place (only the value slots change, not the
key set, so this is safe) rather than rehashing a fresh `Dict`; `m` must not be
used again after this call under its old labels.
"""
function relabelMap(m::Map, σ::Vector{Int})
    for node in keys(m.districting)
        m.districting[node] = σ[m.districting[node]]
    end
    return Map(m.name, m.districting, m.weight, m.data)
end

# The batched-parallelism helpers (`BATCH`, `chunkranges`, `parallelDo!`) live in
# threading.jl, shared with `add`/`extract-map-data`.

# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------

"""
    run_reorder(Atlas1, Atlas2, jsonPath = nothing; firstMap = false, quiet = false,
                cores = Threads.nthreads())

Reorder atlas `Atlas1` into `Atlas2`. `jsonPath` is an optional dual-graph JSON, required
for multiscale/hierarchical atlases whose per-map node sets vary. `firstMap`
aligns every map to map 1 (anchor) instead of to its predecessor; `quiet`
suppresses the progress bar. `cores` is the parse/serialize worker count; it
defaults to the threads Julia was started with, so a single thread runs serially.
"""
function run_reorder(Atlas1::AbstractString, Atlas2::AbstractString,
                     jsonPath::Union{AbstractString,Nothing} = nothing;
                     firstMap::Bool = false, quiet::Bool = false,
                     cores::Int = Threads.nthreads())
    # Start Atlas2 by cloning Atlas1's header (lines 1-3), then append maps to it. For .gz
    # output, `AtlasOutput` compresses the map body as byte-targeted gzip members in
    # parallel (the serial write is only raw I/O); plain/.bz2 stream as before.
    outIO = openAtlasOutput(String(Atlas2), atlasHeaderBytes(String(Atlas1)), cores)

    inIO = smartOpen(String(Atlas1), "r")
    atlas = openAtlas(inIO)
    mpt = atlas.mapParamType
    wt = atlas.weightType
    d = Int(atlas.atlasParam["districts"])

    # Build the hierarchy only when a dual-graph JSON was supplied.
    h = nothing
    if jsonPath !== nothing
        levels = get(atlas.atlasParam, "levels in graph", nothing)
        levels === nothing && error("a dual-graph JSON was given but the atlas has no " *
                                    "\"levels in graph\" param to interpret it.")
        h = loadHierarchy(jsonPath, levels)
    end

    # The atlas has no map count in its header, so the total is unknown; show a
    # live count of maps written (unless suppressed with --quiet).
    progress = quiet ? nothing : ProgressUnknown(desc = "Reordering maps:", spinner = true)
    written = 0
    tick() = progress === nothing || next!(progress; showvalues = [("maps written", written)])

    # Map 1 is the anchor: written verbatim and used as the initial reference.
    ref = nextMap(atlas)
    let buf = IOBuffer()
        addMap(buf, ref)
        writeMaps!(outIO, [take!(buf)])
    end
    written += 1
    tick()

    # Process the remaining maps in batches: parse and serialize in parallel,
    # reorder serially (the chain `ref` carries across batches), write in order.
    while !eof(atlas)
        lines = String[]
        while length(lines) < BATCH && !eof(atlas)
            push!(lines, readline(atlas.io))
        end
        n = length(lines)
        n == 0 && break

        maps = Vector{Map{mpt,wt}}(undef, n)                     # parse (parallel)
        parallelDo!(i -> (maps[i] = JSON3.read(lines[i], Map{mpt,wt})), n, cores)

        reordered = Vector{Map{mpt,wt}}(undef, n)                # reorder (serial chain)
        for i in 1:n
            σ = h === nothing ? reOrder(ref, maps[i], d) : reOrder(ref, maps[i], d, h)
            reordered[i] = relabelMap(maps[i], σ)
            firstMap || (ref = reordered[i])
        end

        bytes = Vector{Vector{UInt8}}(undef, n)                 # serialize (parallel)
        parallelDo!(n, cores) do i
            buf = IOBuffer()
            addMap(buf, reordered[i])
            bytes[i] = take!(buf)
        end

        writeMaps!(outIO, bytes)                                # write (parallel gzip / serial raw)
        written += n
        tick()
    end

    progress === nothing || finish!(progress; showvalues = [("maps written", written)])
    close(atlas)
    close(outIO)
    return nothing
end
