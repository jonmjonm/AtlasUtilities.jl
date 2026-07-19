# nodes.jl -- the `atlas list-nodes` subcommand.
#
# Read an Atlas file with AtlasIO.jl and print the node ids found in the
# districting of its k-th map (k=1 by default), as a JSON array of strings on
# stdout. A node id is a Tuple{Vararg{String}} (multiple components for
# multiscale/hierarchical atlases); components are joined with ":" into a
# single string per array element.

"""
    nodeIdString(node) -> String

Render a node id (a `Tuple{Vararg{String}}`, e.g. `("41063",)` for a flat atlas
or `("county","tract")` for a multiscale one) as a single string, joining
components with `:`.
"""
nodeIdString(node::Tuple{Vararg{String}}) = join(node, ":")

"""
    run_list_nodes(atlasPath; map = 1)

Print the node ids in the `map`-th map's districting of the atlas at
`atlasPath`, as a JSON array of strings (sorted), to stdout. Errors if the
atlas has fewer than `map` maps.
"""
function run_list_nodes(atlasPath::AbstractString; map::Integer = 1)
    map >= 1 || error("atlas list-nodes: --map must be >= 1 (got $map).")
    io = smartOpen(String(atlasPath), "r")
    atlas = openAtlas(io)

    map > 1 && skipMap(atlas; numSkip = map - 1)
    eof(atlas) &&
        error("atlas list-nodes: $atlasPath does not have a map $map.")
    m = nextMap(atlas)
    close(atlas)

    nodeStrings = sort!([nodeIdString(node) for node in keys(m.districting)])
    JSON3.write(stdout, nodeStrings)
    println()
    return nothing
end
