# relabel.jl -- relabeling an atlas's districts (`relabelAtlas`, `mapatlas relabel`).
#
# Walk every map in an input atlas Atlas1, relabel district numbers so consecutive
# maps are as similar as possible, and write the relabeled maps to a new atlas Atlas2.
#
# Parsing the maps dominates runtime (~80%) and is per-map independent, so it is
# threaded across however many threads Julia was started with (`julia --threads=N`,
# or the JULIA_NUM_THREADS env var); with a single thread it runs serially. The
# relabel chain is serial but cheap. Maps are processed in batches:
# read (serial) -> parse (parallel) -> relabel (serial) -> serialize (parallel) ->
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
    finest = Tuple{Vararg{String}}[keyOf(node, levs) for node in readNodeLinkJSON(jsonPath)]
    return Hierarchy(levs, finest)
end

"""Read a NetworkX node-link JSON file and return its `nodes` array."""
function readNodeLinkJSON(jsonPath::AbstractString)
    graph = readJSONFile(jsonPath)
    haskey(graph, "nodes") || error("\"$jsonPath\" is not a node-link graph JSON (no top-level \"nodes\").")
    return graph["nodes"]
end

"""The finest-unit key tuple of a node-link JSON node, per the given level names."""
keyOf(node, levs) = Tuple(jsonKeyString(node[l]) for l in levs)

"""
    loadPopulation(jsonPath, levels, attr) -> Dict{Tuple{Vararg{String}}, Int}

Load a NetworkX node-link JSON (typically the same dual-graph file used for
`loadHierarchy`) and return a map from finest-unit key tuple (per `levels`) to
that node's population, read from the JSON attribute named `attr`
(e.g. `"pop2020cen"`).
"""
function loadPopulation(jsonPath::AbstractString, levels, attr::AbstractString)
    levs = String.(levels)
    return Dict{Tuple{Vararg{String}},Int}(
        keyOf(node, levs) => Int(node[attr]) for node in readNodeLinkJSON(jsonPath)
    )
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
# Relabeling
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
    confusionMatrix(ref::Map, cur::Map, d::Int; pop = nothing) -> Matrix{Int}

`O[i,j] = |{node : ref=i and cur=j}|` (or, if `pop` is given, `Σ pop[node]` over
those nodes). Requires both maps to share the same node-key set
(fixed-resolution atlas).

`pop`, if given, is a `Dict` from node key to population; each node then
contributes its population instead of 1, so distances/alignments computed from
`O` are population-weighted rather than node-count Hamming.
"""
function confusionMatrix(ref::Map, cur::Map, d::Int; pop::Union{AbstractDict,Nothing} = nothing)
    if keys(ref.districting) != keys(cur.districting)
        error("maps \"$(ref.name)\" and \"$(cur.name)\" are expressed over " *
              "different node-key sets ($(length(ref.districting)) vs " *
              "$(length(cur.districting)) nodes). This atlas appears to use a " *
              "multiscale/hierarchical encoding; pass the dual-graph JSON so maps " *
              "can be resolved to a common (finest) resolution.")
    end
    O = zeros(Int, d, d)
    for (node, j) in cur.districting
        O[ref.districting[node], j] += pop === nothing ? 1 : pop[node]
    end
    return O
end

"""
    confusionMatrix(ref::Map, cur::Map, d::Int, h::Hierarchy; pop = nothing) -> Matrix{Int}

Multiscale variant: resolve both maps to the hierarchy's finest units, then
build the confusion matrix at finest resolution. Node sets may differ between
the two maps.

`pop`, if given, is a `Dict` from finest-unit key tuple (`h.finest` entries) to
population; each finest unit then contributes its population instead of 1,
regardless of whether either map represents it as part of a coarser node.
"""
function confusionMatrix(ref::Map, cur::Map, d::Int, h::Hierarchy; pop::Union{AbstractDict,Nothing} = nothing)
    refL = expandLabels(h, ref.districting)
    curL = expandLabels(h, cur.districting)
    O = zeros(Int, d, d)
    for k in eachindex(refL, curL)
        O[refL[k], curL[k]] += pop === nothing ? 1 : pop[h.finest[k]]
    end
    return O
end

"""
    findRelabeling(ref::Map, cur::Map, d::Int; pop = nothing) -> Vector{Int}
    findRelabeling(ref::Map, cur::Map, d::Int, h::Hierarchy; pop = nothing) -> Vector{Int}

Permutation `σ` of `1:d` minimizing the district-wise Hamming distance between
`ref` and the relabeled `cur` (a node whose label was `j` becomes `σ[j]`). The
3-arg form requires both maps to share the same node-key set (fixed-resolution
atlas); the `Hierarchy` form resolves both to finest units first, so node sets
may differ (multiscale atlas). See [`confusionMatrix`](@ref) for `pop`.
"""
findRelabeling(ref::Map, cur::Map, d::Int; pop::Union{AbstractDict,Nothing} = nothing) =
    permutationFromConfusion(confusionMatrix(ref, cur, d; pop), d)

findRelabeling(ref::Map, cur::Map, d::Int, h::Hierarchy; pop::Union{AbstractDict,Nothing} = nothing) =
    permutationFromConfusion(confusionMatrix(ref, cur, d, h; pop), d)

"""
    hammingDistance(ref::Map, cur::Map, d::Int; pop = nothing) -> Int
    hammingDistance(ref::Map, cur::Map, d::Int, h::Hierarchy; pop = nothing) -> Int

The district-wise Hamming distance between `ref` and `cur` **as currently
labeled** (no realignment): `Σᵢ |Dᵢ Δ D̂ᵢ|`, or its population-weighted analogue
if `pop` is given. Built from the same confusion matrix `findRelabeling` uses, so
calling both on the same pair (e.g. to report the distance achieved after
`relabelMap`) does not repeat the node scan — pass a precomputed `O` via the
`confusionMatrix` methods directly to share it explicitly.

Since `Σᵢ|Dᵢ| = Σⱼ|D̂ⱼ| = N` (total node count, or total population), the
symmetric-difference sum simplifies to `2(N - Σᵢ O[i,i])`.
"""
hammingDistance(ref::Map, cur::Map, d::Int; pop::Union{AbstractDict,Nothing} = nothing) =
    hammingDistanceFromConfusion(confusionMatrix(ref, cur, d; pop))

hammingDistance(ref::Map, cur::Map, d::Int, h::Hierarchy; pop::Union{AbstractDict,Nothing} = nothing) =
    hammingDistanceFromConfusion(confusionMatrix(ref, cur, d, h; pop))

hammingDistanceFromConfusion(O::Matrix{Int}) = 2 * (sum(O) - sum(O[i, i] for i in axes(O, 1)))

"""
    achievedHammingDistance(O::Matrix{Int}, σ::Vector{Int}) -> Int

The Hamming distance (or population-weighted analogue) `ref` and `cur` will
have *after* relabeling `cur` by `σ`, computed from the confusion matrix `O`
and `σ` that `findRelabeling` already produced — no extra pass over nodes. `σ[j] = i`
pairs cur-label `j` with ref-label `i`, so the matched overlap is
`Σⱼ O[σ[j], j]`.
"""
achievedHammingDistance(O::Matrix{Int}, σ::Vector{Int}) =
    2 * (sum(O) - sum(O[σ[j], j] for j in eachindex(σ)))

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
    relabelAtlas(src, dst; graph = nothing, first_map = false, population_file = nothing,
                 population_attr = nothing, cores = Threads.nthreads(), progress = false, keep_partial = false)
        -> Int

Relabel the district numbers of every map of atlas `src` so consecutive maps are as similar as possible, writing
the relabeled atlas to `dst`, and return the number of maps written. `graph` is an optional dual-graph JSON,
required for multiscale/hierarchical atlases whose per-map node sets vary. `first_map` aligns every map to map 1
(the anchor) instead of to its predecessor. `cores` is the parse/serialize worker count; it defaults to the
threads Julia was started with, so a single thread runs serially. `dst` is written in `src`'s format version.

`population_file`/`population_attr`, if given, weight the alignment by population instead of raw node counts:
`population_file` is a node-link JSON (often the same file as `graph`) whose nodes carry a population attribute
named `population_attr` (e.g. `"pop2020cen"`), keyed by the atlas's `"levels in graph"` param.

`progress` shows a progress bar with the running mean achieved Hamming distance -- the distance between each map
and the reference it was just aligned to, after relabeling -- as a diagnostic on alignment quality. It is
computed from the same confusion matrix used to find `σ`, so it adds no extra pass over map nodes.

`dst` is written under a temporary name and moved into place when complete, so a run that fails (a damaged map
in `src`, whose error gives its line) leaves an existing `dst` as it was; `dst` may be `src`. With
`keep_partial`, what a failed run wrote is kept as `<dst>.incomplete...` (e.g. `out.incomplete.jsonl.gz`).
"""
function relabelAtlas(src::AbstractString, dst::AbstractString;
                      graph::Union{AbstractString,Nothing} = nothing, first_map::Bool = false,
                      population_file::Union{AbstractString,Nothing} = nothing,
                      population_attr::Union{AbstractString,Nothing} = nothing,
                      cores::Int = Threads.nthreads(), progress::Bool = false, keep_partial::Bool = false)
    # dst is written under a temporary name and moved into place only once every map is written (see
    # `writeReplacing`), so a failed run leaves no partial atlas; and dst may be src.
    return writeReplacing(String(dst); keep_partial, input = String(src), caller = "relabelAtlas") do tmp
        inIO = smartOpen(String(src), "r")
        atlas = try
            openAtlas(inIO)
        catch
            close(inIO)
            rethrow()
        end
        outIO = nothing
        try
            # Start by cloning src's header (lines 1-3), then append maps to it. For .gz output, `AtlasOutput`
            # compresses the map body as byte-targeted gzip members in parallel (the serial write is only raw
            # I/O); plain/.bz2 stream as before.
            outIO = openAtlasOutput(tmp, atlasHeaderBytes(String(src)), cores)
            mpt = atlas.mapParamType
            wt = atlas.weightType
            fv = atlas.formatVersion    # dst copies src's header, so its maps must be in the same version
            d = Int(atlas.atlasParam["districts"])

            # Build the hierarchy only when a dual-graph JSON was supplied.
            h = nothing
            if graph !== nothing
                levels = get(atlas.atlasParam, "levels in graph", nothing)
                levels === nothing && error("relabelAtlas: a dual-graph JSON was given but the atlas has no " *
                                            "\"levels in graph\" param to interpret it.")
                h = loadHierarchy(graph, levels)
            end

            # Load population weights only when requested.
            pop = nothing
            if population_file !== nothing
                population_attr === nothing &&
                    error("relabelAtlas: population_file = needs population_attr = <name>, the population attribute.")
                levels = get(atlas.atlasParam, "levels in graph", nothing)
                levels === nothing && error("relabelAtlas: population_file = was given but the atlas has no " *
                                            "\"levels in graph\" param to interpret its node keys.")
                pop = loadPopulation(population_file, levels, population_attr)
            end

            # The atlas has no map count in its header, so the total is unknown; show a
            # live count of maps written and the running mean chained-alignment Hamming
            # distance (with `progress`).
            bar = progress ? ProgressUnknown(desc = "Relabeling maps:", spinner = true) : nothing
            written = 0
            totalDistance = 0
            aligned = 0     # maps that went through findRelabeling (excludes the anchor)
            function tick()
                bar === nothing && return
                meanDistance = aligned == 0 ? 0.0 : totalDistance / aligned
                next!(bar; showvalues = [("maps written", written),
                                          ("mean Hamming distance", round(meanDistance; digits = 2))])
            end

            # Map 1 is the anchor: written verbatim and used as the initial reference.
            ref = locatingErrors(() -> nextMap(atlas), String(src), () -> 1)
            let buf = IOBuffer()
                addMap(buf, ref; formatVersion = fv)
                writeMaps!(outIO, [take!(buf)])
            end
            written += 1
            tick()

            # Process the remaining maps in batches: parse and serialize in parallel,
            # relabel serially (the chain `ref` carries across batches), write in order.
            while !eof(atlas)
                lines = String[]
                while length(lines) < BATCH && !eof(atlas)
                    push!(lines, readline(atlas.io))
                end
                n = length(lines)
                n == 0 && break

                maps = Vector{Map{mpt,wt}}(undef, n)                     # parse (parallel)
                bad = Vector{Any}(nothing, n)                            # a line that does not parse
                parallelDo!(n, cores) do i
                    try
                        maps[i] = parseMap(lines[i], mpt, wt)
                    catch e
                        bad[i] = e
                    end
                end
                # The first such line is reported, after the maps before it are written (so a kept incomplete
                # output, `keep_partial`, holds every map before the damaged one).
                j = findfirst(!isnothing, bad)
                failed = j === nothing ? nothing : locateMapError(bad[j], String(src), written + j)
                n = j === nothing ? n : j - 1

                relabeled = Vector{Map{mpt,wt}}(undef, n)                # relabel (serial chain)
                for i in 1:n
                    O = h === nothing ? confusionMatrix(ref, maps[i], d; pop) : confusionMatrix(ref, maps[i], d, h; pop)
                    σ = permutationFromConfusion(O, d)
                    totalDistance += achievedHammingDistance(O, σ)
                    aligned += 1
                    relabeled[i] = relabelMap(maps[i], σ)
                    first_map || (ref = relabeled[i])
                end

                bytes = Vector{Vector{UInt8}}(undef, n)                 # serialize (parallel)
                parallelDo!(n, cores) do i
                    buf = IOBuffer()
                    addMap(buf, relabeled[i]; formatVersion = fv)
                    bytes[i] = take!(buf)
                end

                writeMaps!(outIO, bytes)                                # write (parallel gzip / serial raw)
                written += n
                tick()
                failed === nothing || throw(failed)
            end

            if bar !== nothing
                meanDistance = aligned == 0 ? 0.0 : totalDistance / aligned
                finish!(bar; showvalues = [("maps written", written),
                                            ("mean Hamming distance", round(meanDistance; digits = 2))])
            end
            written
        finally
            close(atlas)
            outIO === nothing || close(outIO)
        end
    end
end
