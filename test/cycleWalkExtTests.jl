# The CycleWalk extension (AtlasUtilitiesCycleWalkExt): `using AtlasUtilities` alone loads no CycleWalk, its
# functions then say how to get it, and `using CycleWalk` switches the extension on. Included before any test file that imports CycleWalk.
using Test
using AtlasUtilities

@testset "CycleWalk extension" begin
    @testset "using AtlasUtilities alone loads no CycleWalk (fresh process)" begin
        code = """
            using AtlasUtilities
            cw = Base.PkgId(Base.UUID("ac9cec89-1413-42d8-a7d6-c246d938c565"), "CycleWalk")
            println("ext: ", Base.get_extension(AtlasUtilities, :AtlasUtilitiesCycleWalkExt) === nothing)
            println("cyclewalk: ", haskey(Base.loaded_modules, cw))
            hint(f) = try f(); "" catch e; sprint(showerror, e) end
            println("addMapData: ", occursin("addMapData needs CycleWalk", hint(() -> addMapData("a", "b", ["x"]))))
            println("WriterSet: ", occursin("WriterSet needs CycleWalk", hint(() -> WriterSet(["x"]; graph = "g"))))
            println("listWriters: ", occursin("listWriters needs CycleWalk", hint(listWriters)))
            println("computeWriters: ", occursin("computeWriters needs CycleWalk", hint(() -> computeWriters(1, 2))))
            using CycleWalk
            println("ext after using CycleWalk: ", Base.get_extension(AtlasUtilities, :AtlasUtilitiesCycleWalkExt) !== nothing)
            println("hint gone: ", !occursin("needs CycleWalk", hint(() -> addMapData(1))))
            """
        out = read(`$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project()) -e $code`, String)
        lines = Dict(split(l, ": "; limit = 2) for l in split(strip(out), '\n'))
        @test lines["ext"] == "true"                 # the extension is not loaded ...
        @test lines["cyclewalk"] == "false"          # ... and neither is CycleWalk
        @test lines["addMapData"] == "true"          # calling a CycleWalk function says to load it
        @test lines["WriterSet"] == "true"
        @test lines["listWriters"] == "true"
        @test lines["computeWriters"] == "true"
        @test lines["ext after using CycleWalk"] == "true"
        @test lines["hint gone"] == "true"           # with CycleWalk loaded, a wrong call is just a MethodError
    end

    # The point of the package split: the library stays light. A dependency that starts pulling in one of these, or
    # many more packages, fails here.
    @testset "using AtlasUtilities stays light (fresh process)" begin
        code = """
            before = Set(keys(Base.loaded_modules))
            using AtlasUtilities
            new = [k for k in keys(Base.loaded_modules) if !(k in before)]
            stdlib(k) = startswith(something(Base.locate_package(k), Sys.STDLIB), Sys.STDLIB)
            println("all: ", join(sort([k.name for k in new]), ","))
            println("packages: ", join(sort([k.name for k in new if !stdlib(k)]), ","))
            """
        out = read(`$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project()) -e $code`, String)
        lines = Dict(split(l, ": "; limit = 2) for l in split(strip(out), '\n'))
        loaded = split(lines["all"], ',')
        heavy = ["CycleWalk", "MetropolizedForestRecom", "Comonicon", "PackageCompiler", "Pkg", "Plots", "Makie",
                 "CairoMakie", "GLMakie", "WGLMakie", "Shapefile", "LibGEOS", "GeometryBasics"]
        @test isempty(intersect(heavy, loaded))
        packages = split(lines["packages"], ',')
        @test "AtlasUtilities" in packages
        length(packages) <= 35 || @info "using AtlasUtilities loads $(length(packages)) packages: " * lines["packages"]
        @test length(packages) <= 35                 # 31 on Julia 1.11 and 1.13 (2026-11), AtlasUtilities included
    end
end
