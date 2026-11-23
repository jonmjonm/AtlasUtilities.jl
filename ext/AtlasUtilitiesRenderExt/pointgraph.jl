# pointgraph.jl -- point-position node-link JSON graphs (e.g. hex_graph_10_by_10.json,
# grid_graph_10_by_10.json in Data/) as a geometry source for `atlas render`,
# alongside the shapefile source in render.jl.
#
# These files are NetworkX node-link JSON (nodes + adjacency), not real GeoJSON: each
# node carries a position (`x_location`/`y_location`) rather than a polygon. A cell is
# built for each node by intersecting half-planes across the perpendicular bisector to
# every one of its already-known adjacency neighbors (Sutherland-Hodgman clipping of a
# padded bounding box) -- this is exactly that node's Voronoi cell, computed from the
# graph's own adjacency instead of running a separate Delaunay/Voronoi package (which,
# for what it's worth, would have pulled in a dependency conflicting with this project's
# Colors version). Because it uses the graph's real adjacency rather than a blind
# nearest-neighbor tessellation, it reproduces true hexagons for the hex lattice and true
# squares for the grid lattice, and stays correct for any other adjacency a graph
# encodes. Clipping a cell against neighbor j also tags the resulting edge with j, so a
# `county`-differing neighbor pair's exact shared border can be recovered for the
# county-line overlay at no extra geometric cost (see [`countyBoundarySegments`](@ref)).

"""A single node read from a point-position node-link JSON graph: its id-column value
(pre-lookup), position, and (optional) county attribute value."""
struct PointGraphNode
    key::String
    pos::Point2f
    county::String
end

"""
    parsePointGraph(jsonPath; key = "node_name", county_column = "")
        -> (nodes::Vector{PointGraphNode}, neighbors::Vector{Vector{Int}})

Read the node-link JSON at `jsonPath` (see module docstring). `key` is the node
attribute (or comma-separated list of attributes, joined with `:` in the given order --
matching [`nodeIdString`](@ref)'s own join) used to match atlas node ids, e.g.
`"node_name"`. `county_column`, if given, is the node attribute holding its county (used
only for the county-line overlay). `neighbors[i]` lists the (1-based) indices, into
`nodes`, of node `i`'s adjacency neighbors. Errors if `key` or `county_column` names an
attribute missing from a node, or if a node's JSON `id` is not a valid 0-based index into
the `nodes` array (i.e. `adjacency` cannot be matched positionally to `nodes`).
"""
function parsePointGraph(jsonPath::AbstractString; key::AbstractString = "node_name",
                         county_column::AbstractString = "")
    doc = readJSONFile(jsonPath)
    haskey(doc, "nodes") && haskey(doc, "adjacency") ||
        error("atlas render/view: \"$jsonPath\" is not a node-link graph JSON " *
              "(expected top-level \"nodes\" and \"adjacency\" arrays).")
    rawNodes = doc["nodes"]
    keyAttrs = String.(strip.(split(key, ',')))
    countyAttr = isempty(county_column) ? nothing : String(county_column)

    idToRow = Dict{Int, Int}()
    nodes = Vector{PointGraphNode}(undef, length(rawNodes))
    for (i, n) in enumerate(rawNodes)
        for a in keyAttrs
            haskey(n, a) ||
                error("atlas render/view: node $i of \"$jsonPath\" has no attribute " *
                      "\"$a\" (--key); available attributes: " *
                      join(sort(collect(keys(n))), ", "))
        end
        haskey(n, "x_location") && haskey(n, "y_location") ||
            error("atlas render/view: node $i of \"$jsonPath\" has no " *
                  "\"x_location\"/\"y_location\" position.")
        countyVal = ""
        if countyAttr !== nothing
            haskey(n, countyAttr) ||
                error("atlas render/view: node $i of \"$jsonPath\" has no attribute " *
                      "\"$countyAttr\" (--county-column).")
            countyVal = uppercase(strip(jsonKeyString(n[countyAttr])))
        end
        k = join((jsonKeyString(n[a]) for a in keyAttrs), ":")
        nodes[i] = PointGraphNode(k, Point2f(Float64(n["x_location"]), Float64(n["y_location"])),
                                  countyVal)
        haskey(n, "id") || error("atlas render/view: node $i of \"$jsonPath\" has no \"id\".")
        idToRow[Int(n["id"])] = i
    end

    neighbors = [Int[] for _ in nodes]
    rawAdj = doc["adjacency"]
    length(rawAdj) == length(nodes) ||
        error("atlas render/view: \"$jsonPath\"'s \"adjacency\" has $(length(rawAdj)) " *
              "entries but \"nodes\" has $(length(nodes)).")
    for (i, edges) in enumerate(rawAdj)
        for e in edges
            haskey(idToRow, Int(e["id"])) ||
                error("atlas render/view: \"$jsonPath\" adjacency references node id " *
                      "$(e["id"]), which is not any node's \"id\".")
            push!(neighbors[i], idToRow[Int(e["id"])])
        end
    end
    return nodes, neighbors
end

"""Sutherland-Hodgman-clip `(poly, owner)` (a closed polygon as `Vector{Point2f}`,
parallel `Vector{Int}` naming the neighbor row (or 0) whose clip produced the edge
*leaving* that vertex) against the half-plane, centered on the perpendicular bisector of
`point`/`npt`, containing `point`; new edges introduced by this clip are tagged
`neighborRow`. Returns the clipped `(poly, owner)`, possibly empty."""
function clipHalfPlane(poly::Vector{Point2f}, owner::Vector{Int},
                       point::Point2f, npt::Point2f, neighborRow::Int)
    isempty(poly) && return poly, owner
    mid = (point .+ npt) ./ 2
    dir = npt .- point
    side(v) = (v[1] - mid[1]) * dir[1] + (v[2] - mid[2]) * dir[2]
    n = length(poly)
    newPoly = Point2f[]
    newOwner = Int[]
    for i in 1:n
        curr, e = poly[i], owner[i]
        nxt = poly[mod1(i + 1, n)]
        cSide, nSide = side(curr), side(nxt)
        cIn, nIn = cSide <= 0, nSide <= 0
        if cIn
            push!(newPoly, curr); push!(newOwner, e)
            if !nIn
                t = cSide / (cSide - nSide)
                push!(newPoly, curr .+ t .* (nxt .- curr)); push!(newOwner, neighborRow)
            end
        elseif nIn
            t = cSide / (cSide - nSide)
            push!(newPoly, curr .+ t .* (nxt .- curr)); push!(newOwner, e)
        end
    end
    return newPoly, newOwner
end

"""The median distance between adjacency-neighbor pairs in `nodes` (each unordered pair
counted once), or `1.0` if there are none. Used by [`voronoiCells`](@ref) as the natural
length scale of the graph's own lattice, so a boundary node's cell is padded out by
roughly one neighbor-spacing rather than an arbitrary fraction of the whole extent."""
function typicalSpacing(nodes::Vector{PointGraphNode}, neighbors::Vector{Vector{Int}})
    dists = Float64[]
    for i in eachindex(nodes), j in neighbors[i]
        j > i || continue
        p, q = nodes[i].pos, nodes[j].pos
        push!(dists, hypot(p[1] - q[1], p[2] - q[2]))
    end
    isempty(dists) && return 1.0
    sort!(dists)
    m = length(dists)
    return isodd(m) ? dists[(m + 1) ÷ 2] : (dists[m ÷ 2] + dists[m ÷ 2 + 1]) / 2
end

"""
    voronoiCells(nodes, neighbors; pad = nothing) -> (cells, edgeOwners)

Build each node's Voronoi cell (see module docstring), one `GeometryBasics.Polygon` per
node, by clipping a padded bounding box of all node positions against the half-plane of
every adjacency neighbor. `pad` extends the bounding box by this absolute margin on
every side (so boundary nodes get a finite, visually reasonable cell instead of an
unbounded one); by default (`nothing`) it is half of [`typicalSpacing`](@ref), so a
boundary cell comes out roughly the same size as an interior one instead of ballooning
out to a fraction of the whole map. `edgeOwners[i]` parallels `cells[i]`'s ring: the
neighbor row (into `nodes`) whose clip produced each edge, or `0` for an untouched
bounding-box edge -- consumed by [`countyBoundarySegments`](@ref).
"""
function voronoiCells(nodes::Vector{PointGraphNode}, neighbors::Vector{Vector{Int}};
                      pad::Union{Real, Nothing} = nothing)
    margin = pad === nothing ? typicalSpacing(nodes, neighbors) / 2 : Float64(pad)
    xs = [p.pos[1] for p in nodes]
    ys = [p.pos[2] for p in nodes]
    xlo, xhi = extrema(xs)
    ylo, yhi = extrema(ys)
    xlo -= margin; xhi += margin; ylo -= margin; yhi += margin
    bbox = Point2f[(xlo, ylo), (xhi, ylo), (xhi, yhi), (xlo, yhi)]

    cells = Vector{Makie.Polygon}(undef, length(nodes))
    edgeOwners = Vector{Vector{Int}}(undef, length(nodes))
    for i in eachindex(nodes)
        poly = copy(bbox)
        owner = zeros(Int, length(bbox))
        for j in neighbors[i]
            poly, owner = clipHalfPlane(poly, owner, nodes[i].pos, nodes[j].pos, j)
        end
        isempty(poly) &&
            error("atlas render/view: node $i's Voronoi cell clipped to nothing " *
                  "(degenerate/duplicate node position?).")
        cells[i] = Makie.Polygon(poly)
        edgeOwners[i] = owner
    end
    return cells, edgeOwners
end

"""
    countyBoundarySegments(nodes, cells, edgeOwners) -> Vector{Tuple{Point2f,Point2f}}

The shared-border segments between adjacency-neighbor pairs whose `county` differs
(nodes with an empty county, i.e. no `--county-column` given, never produce segments).
Each unordered pair is emitted once, reading its exact clipped edge out of the
lower-indexed node's cell (`edgeOwners`) rather than recomputing anything.
"""
function countyBoundarySegments(nodes::Vector{PointGraphNode}, cells::Vector{Makie.Polygon},
                                edgeOwners::Vector{Vector{Int}})
    segs = Tuple{Point2f, Point2f}[]
    for i in eachindex(nodes)
        isempty(nodes[i].county) && continue
        ring = Makie.coordinates(cells[i])
        n = length(ring)
        for k in 1:n
            j = edgeOwners[i][k]
            j == 0 && continue
            j < i && continue  # emit each pair once, from the higher-indexed side
            isempty(nodes[j].county) && continue
            nodes[i].county == nodes[j].county && continue
            push!(segs, (ring[k], ring[mod1(k + 1, n)]))
        end
    end
    return segs
end

"""
    loadPointGraphGeometries(jsonPath, key; county_column = "")
        -> (tokenIndex, geometries, countyBoundary)

Read the point-position node-link JSON at `jsonPath` and return `(tokenIndex,
geometries, countyBoundary)`: `tokenIndex` maps each node's `key` attribute value(s)
(see [`parsePointGraph`](@ref)) to its row, `geometries[i]` is node `i`'s Voronoi cell
polygon (see [`voronoiCells`](@ref)), and `countyBoundary` is the list of shared-border
segments between differing-`county` neighbors (see [`countyBoundarySegments`](@ref)),
empty when `county_column` is not given.
"""
function loadPointGraphGeometries(jsonPath::AbstractString, key::AbstractString;
                                  county_column::AbstractString = "")
    nodes, neighbors = parsePointGraph(jsonPath; key = key, county_column = county_column)
    cells, edgeOwners = voronoiCells(nodes, neighbors)
    tokenIndex = Dict{String, Int}(n.key => i for (i, n) in enumerate(nodes))
    boundary = isempty(county_column) ? Tuple{Point2f, Point2f}[] :
               countyBoundarySegments(nodes, cells, edgeOwners)
    return tokenIndex, Any[c for c in cells], boundary
end
