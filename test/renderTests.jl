# Tests for the `atlas render` subcommand (src/render.jl), using the real CT
# example atlas and shapefile (Data/shapefile_CT.zip, examples/cycleWalk_ct_slice.jsonl.gz)
# since a shapefile is not practical to synthesize inline.

using Test
using Makie: Figure
using CairoMakie, Shapefile, LibGEOS     # loading these loads AtlasUtilities' render extension
using AtlasUtilities
const RenderExt = Base.get_extension(AtlasUtilities, :AtlasUtilitiesRenderExt)
using .RenderExt: resolveShapefilePath, loadShapefileGeometries, matchMapToRows, loadGeoSource,
                  isPointGraphPath, dissolvedCountyBoundarySegments
# render_map, run_render and districtColors: AtlasUtilities' exported wrappers, which call the extension.
using AtlasUtilities: render_map, run_render, districtColors

@testset "render extension" begin
    @test RenderExt isa Module
    @test isempty(AtlasUtilities.missingRenderPackages())
    @test AtlasUtilities.renderExtension() === RenderExt
    @test districtColors(3) == RenderExt.districtColors(3)
    io = IOBuffer()
    AtlasUtilities.run_install_render(; io = io)        # already installed: nothing to do
    @test occursin("already installed", String(take!(io)))
end

const CT_ATLAS = joinpath(@__DIR__, "..", "examples", "cycleWalk_ct_slice.jsonl.gz")
const CT_SHAPEFILE = joinpath(@__DIR__, "..", "Data", "shapefile_CT.zip")
const GRID_GRAPH = joinpath(@__DIR__, "..", "Data", "grid_graph_10_by_10.json")
const HEX_GRAPH = joinpath(@__DIR__, "..", "Data", "hex_graph_10_by_10.json")

"""Build a small atlas over the grid/hex example graphs' `(r,c)` node names, one map,
district 1 for `c < split` and district 2 otherwise -- matches the graphs' own
county A/B split at `c == 5`, so it also exercises `--county-column`/`--county-lines`."""
function gridAtlas(path::AbstractString; split::Integer = 5)
    io = smartOpen(path, "w")
    newAtlas(io, AtlasHeader("grid", "2026-01-02T03:04:05", Dict{String,Any}, Dict{String,Any}),
             Dict{String,Any}("districts" => 2))
    dpairs = Pair{Tuple{String}, Int}[]
    for r in 0:9, c in 0:9
        push!(dpairs, (("($r,$c)",)) => (c < split ? 1 : 2))
    end
    addMap(io, Map("m1", Districting(dpairs...), 1, Dict{String,Any}()))
    close(io)
    return path
end

@testset "render" begin

    @testset "districtColors: one color per district, mutually distinct" begin
        colors = districtColors(5)
        @test length(colors) == 5
        @test length(unique(colors)) == 5
        @test_throws ErrorException districtColors(0)
    end

    @testset "resolveShapefilePath: passes through a .shp path unchanged" begin
        path, tmpdir = resolveShapefilePath("/some/dir/foo.shp")
        @test path == "/some/dir/foo.shp"
        @test tmpdir === nothing
    end

    @testset "resolveShapefilePath: unzips a .zip bundle and finds the .shp inside" begin
        shp, tmpdir = resolveShapefilePath(CT_SHAPEFILE)
        try
            @test isfile(shp)
            @test endswith(lowercase(shp), ".shp")
            @test tmpdir !== nothing
            @test isdir(tmpdir)
        finally
            tmpdir === nothing || rm(tmpdir; recursive = true, force = true)
        end
    end

    @testset "resolveShapefilePath: errors on a non-.shp, non-.zip path" begin
        @test_throws ErrorException resolveShapefilePath("/some/dir/foo.txt")
    end

    @testset "loadShapefileGeometries: single-column key matches CT NAME values" begin
        shp, tmpdir = resolveShapefilePath(CT_SHAPEFILE)
        try
            tokenIndex, geometries, _ = loadShapefileGeometries(shp, "NAME")
            @test length(geometries) == 695
            @test haskey(tokenIndex, "Bethel 001-00_FAIRFIELD COUNTY")
        finally
            tmpdir === nothing || rm(tmpdir; recursive = true, force = true)
        end
    end

    @testset "loadShapefileGeometries: errors on an unknown column" begin
        shp, tmpdir = resolveShapefilePath(CT_SHAPEFILE)
        try
            @test_throws ErrorException loadShapefileGeometries(shp, "NOT_A_COLUMN")
        finally
            tmpdir === nothing || rm(tmpdir; recursive = true, force = true)
        end
    end

    @testset "loadShapefileGeometries: comma-separated composite key joins with ':'" begin
        shp, tmpdir = resolveShapefilePath(CT_SHAPEFILE)
        try
            tokenIndex, _, _ = loadShapefileGeometries(shp, "COUNTY,NAME")
            @test haskey(tokenIndex, "FAIRFIELD COUNTY:Bethel 001-00_FAIRFIELD COUNTY")
        finally
            tmpdir === nothing || rm(tmpdir; recursive = true, force = true)
        end
    end

    @testset "loadShapefileGeometries: a comma-merged row's atomic parts each index to it" begin
        shp, tmpdir = resolveShapefilePath(CT_SHAPEFILE)
        try
            tokenIndex, _, _ = loadShapefileGeometries(shp, "NAME")
            # "Bethel 002-00_FAIRFIELD COUNTY,Bethel 005-00_FAIRFIELD COUNTY" is one
            # merged shapefile row; both atomic halves should resolve to the same row.
            @test tokenIndex["Bethel 002-00_FAIRFIELD COUNTY"] ==
                  tokenIndex["Bethel 005-00_FAIRFIELD COUNTY"]
        finally
            tmpdir === nothing || rm(tmpdir; recursive = true, force = true)
        end
    end

    @testset "loadShapefileGeometries: --county-column builds a per-county row index" begin
        shp, tmpdir = resolveShapefilePath(CT_SHAPEFILE)
        try
            _, geometries, countyIndex = loadShapefileGeometries(shp, "NAME";
                                                                 county_column = "COUNTY")
            @test haskey(countyIndex, "FAIRFIELD COUNTY")
            @test length(countyIndex["FAIRFIELD COUNTY"]) > 1
            @test all(i -> 1 <= i <= length(geometries), countyIndex["FAIRFIELD COUNTY"])
        finally
            tmpdir === nothing || rm(tmpdir; recursive = true, force = true)
        end
    end

    @testset "loadShapefileGeometries: errors on an unknown --county-column" begin
        shp, tmpdir = resolveShapefilePath(CT_SHAPEFILE)
        try
            @test_throws ErrorException loadShapefileGeometries(shp, "NAME";
                                                                county_column = "NOT_A_COLUMN")
        finally
            tmpdir === nothing || rm(tmpdir; recursive = true, force = true)
        end
    end

    @testset "run_render: --county-column falls back a whole-county node id" begin
        # A node id that is exactly a county name (no precinct token) matches
        # nothing via --shapefile-key alone, but resolves via --county-column.
        dir = mktempdir()
        atlasPath = joinpath(dir, "countyfallback.jsonl")
        io = smartOpen(atlasPath, "w")
        newAtlas(io, AtlasHeader("desc", "2026-01-02T03:04:05", Dict{String,Any}, Dict{String,Any}),
                 Dict{String,Any}("districts" => 1))
        addMap(io, Map("m1", Districting(("FAIRFIELD COUNTY",) => 1), 1, Dict{String,Any}()))
        close(io)

        out = joinpath(dir, "county.png")
        run_render(atlasPath, CT_SHAPEFILE; key = "NAME",
                  county_column = "COUNTY", out = out, quiet = true)
        @test isfile(out)
        @test filesize(out) > 0

        # Without --county-column the same atlas has no matching record at all.
        @test_throws ErrorException run_render(atlasPath, CT_SHAPEFILE;
                                               key = "NAME", quiet = true)
    end

    @testset "render_map: builds a Figure without saving or displaying anything" begin
        fig = render_map(CT_ATLAS, CT_SHAPEFILE; key = "NAME", quiet = true)
        @test fig isa Figure
    end

    @testset "render_map: errors when no node id matches any shapefile record" begin
        # run_render forwards straight to render_map, so this also covers the
        # shared error path exercised by the "run_render: errors ..." tests below.
        @test_throws ErrorException render_map(CT_ATLAS, CT_SHAPEFILE; key = "COUNTY")
    end

    @testset "run_render: writes an image for the CT example atlas" begin
        dir = mktempdir()
        out = joinpath(dir, "ct_map.png")
        run_render(CT_ATLAS, CT_SHAPEFILE; key = "NAME", out = out, quiet = true)
        @test isfile(out)
        @test filesize(out) > 0
    end

    @testset "run_render: default output path is derived from the atlas name" begin
        dir = mktempdir()
        atlasCopy = joinpath(dir, "myatlas.jsonl.gz")
        cp(CT_ATLAS, atlasCopy)
        cd(dir) do
            run_render(atlasCopy, CT_SHAPEFILE; key = "NAME", quiet = true)
        end
        @test isfile(joinpath(dir, "myatlas-map1.png"))
    end

    @testset "run_render: --format chooses the extension when --out is not given" begin
        dir = mktempdir()
        atlasCopy = joinpath(dir, "myatlas.jsonl.gz")
        cp(CT_ATLAS, atlasCopy)
        cd(dir) do
            run_render(atlasCopy, CT_SHAPEFILE; key = "NAME", format = "svg", quiet = true)
        end
        @test isfile(joinpath(dir, "myatlas-map1.svg"))
    end

    @testset "run_render: requires --shapefile-key" begin
        @test_throws ErrorException run_render(CT_ATLAS, CT_SHAPEFILE; quiet = true)
    end

    @testset "run_render: --map must be >= 1" begin
        @test_throws ErrorException run_render(CT_ATLAS, CT_SHAPEFILE;
                                               key = "NAME", map = 0, quiet = true)
    end

    @testset "run_render: rejects an unknown --format" begin
        @test_throws ErrorException run_render(CT_ATLAS, CT_SHAPEFILE;
                                               key = "NAME", format = "gif", quiet = true)
    end

    @testset "run_render: errors when node ids don't match any shapefile record" begin
        @test_throws ErrorException run_render(CT_ATLAS, CT_SHAPEFILE;
                                               key = "COUNTY", quiet = true)
    end

    @testset "run_render: errors even with --skip-missing when nothing matches at all" begin
        @test_throws ErrorException run_render(CT_ATLAS, CT_SHAPEFILE;
                                               key = "COUNTY",
                                               skip_missing = true, quiet = true)
    end

    @testset "run_render: --skip-missing renders anyway when only some nodes mismatch" begin
        # Take a real map's districting and add one node id with no shapefile match.
        dir = mktempdir()
        atlasPath = joinpath(dir, "partial.jsonl")
        io = smartOpen(atlasPath, "w")
        newAtlas(io, AtlasHeader("desc", "2026-01-02T03:04:05", Dict{String,Any}, Dict{String,Any}),
                 Dict{String,Any}("districts" => 5))
        src = openAtlas(smartOpen(CT_ATLAS, "r"))
        m = nextMap(src)
        close(src)
        dist = Districting(m.districting)
        dist[("NOT_A_REAL_PRECINCT",)] = 1
        addMap(io, Map("m1", dist, 1, Dict{String,Any}()))
        close(io)

        out = joinpath(dir, "ct_partial.png")
        run_render(atlasPath, CT_SHAPEFILE; key = "NAME", out = out,
                  skip_missing = true, quiet = true)
        @test isfile(out)
        @test filesize(out) > 0

        @test_throws ErrorException run_render(atlasPath, CT_SHAPEFILE;
                                               key = "NAME", quiet = true)
    end

    @testset "run_render: --strip-suffix strips a trailing pattern before matching" begin
        dir = mktempdir()
        out = joinpath(dir, "ct_suffix.png")
        # No node id in the CT fixture actually has this suffix, so stripping it
        # is a no-op here; this just checks the flag is accepted and matching
        # still succeeds (i.e. the regex doesn't corrupt ids that don't match it).
        run_render(CT_ATLAS, CT_SHAPEFILE; key = "NAME", out = out,
                  strip_suffix = raw"__SD\d+__HD\d+", quiet = true)
        @test isfile(out)
        @test filesize(out) > 0
    end

    @testset "run_render: --county-lines dissolves a shapefile county via LibGEOS" begin
        dir = mktempdir()
        out = joinpath(dir, "ct_countylines.png")
        run_render(CT_ATLAS, CT_SHAPEFILE; key = "NAME", county_column = "COUNTY",
                  county_lines = true, out = out, quiet = true)
        @test isfile(out)
        @test filesize(out) > 0
    end

    @testset "run_render: --county-lines requires --county-column" begin
        @test_throws ErrorException run_render(CT_ATLAS, CT_SHAPEFILE; key = "NAME",
                                               county_lines = true, quiet = true)
    end

    @testset "isPointGraphPath: dispatches on extension" begin
        @test isPointGraphPath("Data/grid_graph_10_by_10.json")
        @test !isPointGraphPath("Data/shapefile_CT.zip")
        @test !isPointGraphPath("/some/dir/foo.shp")
    end

    @testset "matchMapToRows: split_commas=false matches a comma-containing id whole" begin
        # A point-graph node name like "(3,7)" must not be comma-split -- it isn't a
        # merged-precinct list, the comma is part of the coordinate notation.
        tokenIndex = Dict("(3,7)" => 5)
        rowDistrict, fullyMissing, partiallyMissing, _ =
            matchMapToRows(Dict(("(3,7)",) => 2), tokenIndex, Dict{String,Vector{Int}}(), 10;
                          split_commas = false)
        @test rowDistrict[5] == 2
        @test fullyMissing == 0 && partiallyMissing == 0

        # With splitting on (the shapefile default), the same id is mangled into two
        # bogus tokens and fails to match at all.
        rowDistrict2, fullyMissing2, _, _ =
            matchMapToRows(Dict(("(3,7)",) => 2), tokenIndex, Dict{String,Vector{Int}}(), 10;
                          split_commas = true)
        @test all(==(0), rowDistrict2)
        @test fullyMissing2 == 1
    end

    @testset "loadGeoSource: dispatches a .json path to the point-graph loader" begin
        src = loadGeoSource(GRID_GRAPH, "node_name")
        @test length(src.geometries) == 100
        @test haskey(src.tokenIndex, "(0,0)")
        @test isempty(src.countyIndex)          # point-graphs have no county fallback concept
        @test isempty(src.countyBoundary)       # county_lines not requested
        @test src.tmpdir === nothing
    end

    @testset "loadGeoSource: --county-lines on a point-graph reads the graph's own adjacency" begin
        src = loadGeoSource(GRID_GRAPH, "node_name"; county_column = "county", county_lines = true)
        @test length(src.countyBoundary) == 10   # one crossing per row, straight A/B split at c==5
    end

    @testset "loadGeoSource: --county-lines needs --county-column" begin
        @test_throws ErrorException loadGeoSource(GRID_GRAPH, "node_name"; county_lines = true)
    end

    @testset "render_map/run_render: point-graph (grid) geometry source" begin
        dir = mktempdir()
        atlasPath = gridAtlas(joinpath(dir, "grid.jsonl"))

        fig = render_map(atlasPath, GRID_GRAPH; key = "node_name", quiet = true)
        @test fig isa Figure

        out = joinpath(dir, "grid.png")
        run_render(atlasPath, GRID_GRAPH; key = "node_name", out = out, quiet = true)
        @test isfile(out)
        @test filesize(out) > 0
    end

    @testset "render_map: point-graph (hex) geometry source" begin
        dir = mktempdir()
        atlasPath = gridAtlas(joinpath(dir, "hex.jsonl"))
        fig = render_map(atlasPath, HEX_GRAPH; key = "node_name", quiet = true)
        @test fig isa Figure
    end

    @testset "render_map: point-graph --county-lines draws the adjacency-derived overlay" begin
        dir = mktempdir()
        atlasPath = gridAtlas(joinpath(dir, "grid.jsonl"))
        fig = render_map(atlasPath, GRID_GRAPH; key = "node_name",
                         county_column = "county", county_lines = true, quiet = true)
        @test fig isa Figure
    end

    @testset "render_map: --no-precinct-lines (precinct_lines=false) still builds a Figure" begin
        dir = mktempdir()
        atlasPath = gridAtlas(joinpath(dir, "grid.jsonl"))
        fig = render_map(atlasPath, GRID_GRAPH; key = "node_name",
                         precinct_lines = false, quiet = true)
        @test fig isa Figure
    end

    @testset "dissolvedCountyBoundarySegments: skips a county that fails to dissolve, with a warning" begin
        # A single degenerate (zero-area) "polygon" can't build valid LibGEOS geometry;
        # the county should be skipped (empty segments), not crash the whole render.
        bad = Shapefile.Polygon(Shapefile.Rect(0, 0, 0, 0), Int32[0],
                                [Shapefile.Point(0, 0), Shapefile.Point(0, 0)])
        segs = @test_logs (:warn,) match_mode=:any dissolvedCountyBoundarySegments(
            Any[bad], Dict("X" => [1]))
        @test isempty(segs)
    end

end
