# nodes.jl -- the node ids of one map (`atlas list-nodes`).
#
# A node id is a Tuple{Vararg{String}} (multiple components for multiscale/hierarchical atlases); `nodeIdString`
# joins its components with ":" into a single string.

"""
    nodeIdString(node) -> String

Render a node id (a `Tuple{Vararg{String}}`, e.g. `("41063",)` for a flat atlas
or `("county","tract")` for a multiscale one) as a single string, joining
components with `:`.
"""
nodeIdString(node::Tuple{Vararg{String}}) = join(node, ":")

"""
    listNodes(atlasPath; map = 1) -> Vector{String}

The node ids of the `map`-th map (1-based) of the atlas at `atlasPath`, each rendered with
[`nodeIdString`](@ref), sorted. Errors if the atlas has fewer than `map` maps.
"""
function listNodes(atlasPath::AbstractString; map::Integer = 1)
    map >= 1 || error("listNodes: map = $map must be >= 1.")
    atlas = openAtlas(smartOpen(String(atlasPath), "r"))
    try
        map > 1 && skipMap(atlas; numSkip = map - 1)
        eof(atlas) && error("listNodes: $atlasPath does not have a map $map.")
        m = nextMap(atlas)
        return sort!([nodeIdString(node) for node in keys(m.districting)])
    finally
        close(atlas)
    end
end
