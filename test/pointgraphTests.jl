# Tests for src/pointgraph.jl: point-position node-link JSON graphs as a geometry
# source (see render.jl's module docstring for how this fits alongside shapefiles).
# Uses the real example graphs in Data/ (a synthetic graph would just reimplement
# them) and checks the geometry this module derives from their adjacency, not the
# fixture data itself.

using Test
using Makie
using CairoMakie, Shapefile, LibGEOS     # loading these loads AtlasUtilities' render extension
using AtlasUtilities
const RenderExt = Base.get_extension(AtlasUtilities, :AtlasUtilitiesRenderExt)
using .RenderExt: loadPointGraphGeometries, parsePointGraph, voronoiCells, typicalSpacing, countyBoundarySegments

const GRID_GRAPH = joinpath(@__DIR__, "..", "Data", "grid_graph_10_by_10.json")
const HEX_GRAPH = joinpath(@__DIR__, "..", "Data", "hex_graph_10_by_10.json")

"""The (positive) area of a Makie polygon via the shoelace formula, used to check a
Voronoi cell's size rather than depending on `GeometryBasics.area`'s exact triangulation-
based method (which has no direct method for a bare `Polygon`)."""
function shoelaceArea(poly)
    ring = Makie.coordinates(poly)
    n = length(ring)
    s = 0.0
    for i in 1:n
        a, b = ring[i], ring[mod1(i + 1, n)]
        s += a[1] * b[2] - b[1] * a[2]
    end
    return abs(s) / 2
end

@testset "pointgraph" begin

    @testset "parsePointGraph: reads node positions/keys and adjacency for the grid graph" begin
        nodes, neighbors = parsePointGraph(GRID_GRAPH; key = "node_name")
        @test length(nodes) == 100
        @test nodes[1].key == "(0,0)"
        # node (0,0) (row 0) has two grid neighbors: (0,1) and (1,0).
        @test length(neighbors[1]) == 2
    end

    @testset "parsePointGraph: --county-column reads each node's county" begin
        nodes, _ = parsePointGraph(GRID_GRAPH; key = "node_name", county_column = "county")
        @test nodes[1].county == "A"
        @test nodes[end].county == "B"
    end

    @testset "parsePointGraph: comma-separated key joins with ':'" begin
        nodes, _ = parsePointGraph(GRID_GRAPH; key = "node_name,id")
        @test nodes[1].key == "(0,0):0"
    end

    @testset "parsePointGraph: errors on an unknown key attribute" begin
        @test_throws ErrorException parsePointGraph(GRID_GRAPH; key = "not_a_field")
    end

    @testset "typicalSpacing: matches the unit lattice spacing of the example graphs" begin
        nodes, neighbors = parsePointGraph(GRID_GRAPH; key = "node_name")
        @test typicalSpacing(nodes, neighbors) == 1.0
    end

    @testset "voronoiCells: interior, edge, and corner cells are all unit area (grid)" begin
        nodes, neighbors = parsePointGraph(GRID_GRAPH; key = "node_name")
        cells, _ = voronoiCells(nodes, neighbors)
        tokenIndex = Dict(n.key => i for (i, n) in enumerate(nodes))
        for id in ("(5,5)", "(0,5)", "(0,0)")
            @test shoelaceArea(cells[tokenIndex[id]]) ≈ 1.0
        end
        # Every cell tiles the 10x10 lattice exactly once each: total area 100.
        @test sum(shoelaceArea(c) for c in cells) ≈ 100.0
    end

    @testset "voronoiCells: interior, edge, and corner cells are all unit area (hex)" begin
        nodes, neighbors = parsePointGraph(HEX_GRAPH; key = "node_name")
        cells, _ = voronoiCells(nodes, neighbors)
        tokenIndex = Dict(n.key => i for (i, n) in enumerate(nodes))
        for id in ("(5,5)", "(0,5)", "(0,0)")
            @test shoelaceArea(cells[tokenIndex[id]]) ≈ 1.0
        end
    end

    @testset "countyBoundarySegments: grid's straight A/B split gives one crossing per row" begin
        nodes, neighbors = parsePointGraph(GRID_GRAPH; key = "node_name", county_column = "county")
        cells, edgeOwners = voronoiCells(nodes, neighbors)
        segs = countyBoundarySegments(nodes, cells, edgeOwners)
        @test length(segs) == 10
    end

    @testset "countyBoundarySegments: empty without a county attribute" begin
        nodes, neighbors = parsePointGraph(GRID_GRAPH; key = "node_name")  # no county_column
        cells, edgeOwners = voronoiCells(nodes, neighbors)
        @test isempty(countyBoundarySegments(nodes, cells, edgeOwners))
    end

    @testset "loadPointGraphGeometries: ties tokenIndex/geometries/countyBoundary together" begin
        tokenIndex, geometries, boundary = loadPointGraphGeometries(GRID_GRAPH, "node_name";
                                                                    county_column = "county")
        @test length(geometries) == 100
        @test shoelaceArea(geometries[tokenIndex["(0,0)"]]) ≈ 1.0
        @test length(boundary) == 10
    end

    @testset "loadPointGraphGeometries: no boundary segments without --county-column" begin
        _, _, boundary = loadPointGraphGeometries(GRID_GRAPH, "node_name")
        @test isempty(boundary)
    end

end
