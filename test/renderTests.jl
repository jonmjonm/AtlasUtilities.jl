# Tests for the `atlas render` subcommand (src/render.jl), using the real CT
# example atlas and shapefile (Data/shapefile_CT.zip, examples/cycleWalk_ct_slice.jsonl.gz)
# since a shapefile is not practical to synthesize inline.

using Test
using Makie: Figure
using AtlasUtilities: render_map, run_render, resolveShapefilePath, loadShapefileGeometries,
                      districtColors

const CT_ATLAS = joinpath(@__DIR__, "..", "examples", "cycleWalk_ct_slice.jsonl.gz")
const CT_SHAPEFILE = joinpath(@__DIR__, "..", "Data", "shapefile_CT.zip")

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
        run_render(atlasPath, CT_SHAPEFILE; shapefile_key = "NAME",
                  county_column = "COUNTY", out = out, quiet = true)
        @test isfile(out)
        @test filesize(out) > 0

        # Without --county-column the same atlas has no matching record at all.
        @test_throws ErrorException run_render(atlasPath, CT_SHAPEFILE;
                                               shapefile_key = "NAME", quiet = true)
    end

    @testset "render_map: builds a Figure without saving or displaying anything" begin
        fig = render_map(CT_ATLAS, CT_SHAPEFILE; shapefile_key = "NAME", quiet = true)
        @test fig isa Figure
    end

    @testset "render_map: errors when no node id matches any shapefile record" begin
        # run_render forwards straight to render_map, so this also covers the
        # shared error path exercised by the "run_render: errors ..." tests below.
        @test_throws ErrorException render_map(CT_ATLAS, CT_SHAPEFILE; shapefile_key = "COUNTY")
    end

    @testset "run_render: writes an image for the CT example atlas" begin
        dir = mktempdir()
        out = joinpath(dir, "ct_map.png")
        run_render(CT_ATLAS, CT_SHAPEFILE; shapefile_key = "NAME", out = out, quiet = true)
        @test isfile(out)
        @test filesize(out) > 0
    end

    @testset "run_render: default output path is derived from the atlas name" begin
        dir = mktempdir()
        atlasCopy = joinpath(dir, "myatlas.jsonl.gz")
        cp(CT_ATLAS, atlasCopy)
        cd(dir) do
            run_render(atlasCopy, CT_SHAPEFILE; shapefile_key = "NAME", quiet = true)
        end
        @test isfile(joinpath(dir, "myatlas-map1.png"))
    end

    @testset "run_render: --format chooses the extension when --out is not given" begin
        dir = mktempdir()
        atlasCopy = joinpath(dir, "myatlas.jsonl.gz")
        cp(CT_ATLAS, atlasCopy)
        cd(dir) do
            run_render(atlasCopy, CT_SHAPEFILE; shapefile_key = "NAME", format = "svg", quiet = true)
        end
        @test isfile(joinpath(dir, "myatlas-map1.svg"))
    end

    @testset "run_render: requires --shapefile-key" begin
        @test_throws ErrorException run_render(CT_ATLAS, CT_SHAPEFILE; quiet = true)
    end

    @testset "run_render: --map must be >= 1" begin
        @test_throws ErrorException run_render(CT_ATLAS, CT_SHAPEFILE;
                                               shapefile_key = "NAME", map = 0, quiet = true)
    end

    @testset "run_render: rejects an unknown --format" begin
        @test_throws ErrorException run_render(CT_ATLAS, CT_SHAPEFILE;
                                               shapefile_key = "NAME", format = "gif", quiet = true)
    end

    @testset "run_render: errors when node ids don't match any shapefile record" begin
        @test_throws ErrorException run_render(CT_ATLAS, CT_SHAPEFILE;
                                               shapefile_key = "COUNTY", quiet = true)
    end

    @testset "run_render: errors even with --skip-missing when nothing matches at all" begin
        @test_throws ErrorException run_render(CT_ATLAS, CT_SHAPEFILE;
                                               shapefile_key = "COUNTY",
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
        run_render(atlasPath, CT_SHAPEFILE; shapefile_key = "NAME", out = out,
                  skip_missing = true, quiet = true)
        @test isfile(out)
        @test filesize(out) > 0

        @test_throws ErrorException run_render(atlasPath, CT_SHAPEFILE;
                                               shapefile_key = "NAME", quiet = true)
    end

    @testset "run_render: --strip-suffix strips a trailing pattern before matching" begin
        dir = mktempdir()
        out = joinpath(dir, "ct_suffix.png")
        # No node id in the CT fixture actually has this suffix, so stripping it
        # is a no-op here; this just checks the flag is accepted and matching
        # still succeeds (i.e. the regex doesn't corrupt ids that don't match it).
        run_render(CT_ATLAS, CT_SHAPEFILE; shapefile_key = "NAME", out = out,
                  strip_suffix = raw"__SD\d+__HD\d+", quiet = true)
        @test isfile(out)
        @test filesize(out) > 0
    end

end
