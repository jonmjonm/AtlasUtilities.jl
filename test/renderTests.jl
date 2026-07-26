# Tests for the `atlas render` subcommand (src/render.jl), using the real CT
# example atlas and shapefile (Data/shapefile_CT.zip, examples/cycleWalk_ct_slice.jsonl.gz)
# since a shapefile is not practical to synthesize inline.

using Test
using AtlasUtilities: run_render, resolveShapefilePath, loadShapefileGeometries, districtColors

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
            geoms = loadShapefileGeometries(shp, "NAME")
            @test length(geoms) == 695
            @test haskey(geoms, "Bethel 001-00_FAIRFIELD COUNTY")
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
            geoms = loadShapefileGeometries(shp, "COUNTY,NAME")
            @test haskey(geoms, "FAIRFIELD COUNTY:Bethel 001-00_FAIRFIELD COUNTY")
        finally
            tmpdir === nothing || rm(tmpdir; recursive = true, force = true)
        end
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

end
