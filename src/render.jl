# `atlas render` is implemented in the package extension AtlasUtilitiesRenderExt (ext/), so that the plotting
# packages it needs -- CairoMakie (with Makie and Colors) for drawing, Shapefile and LibGEOS for geometry --
# are not installed or loaded for the other subcommands. Together they are about 170 of the ~280 packages
# AtlasUtilities would otherwise depend on, and most of its load time.
#
# The exported `run_render`, `render_map` and `districtColors` below load the extension on first use (or say how
# to install the plotting packages), then call its implementation. From Julia you can also load it yourself:
# `using AtlasUtilities, CairoMakie, Shapefile, LibGEOS`.

"The plotting packages `atlas render` needs (Makie and Colors come with CairoMakie)."
const RENDER_PACKAGES = [
    Base.PkgId(Base.UUID("13f3f980-e62b-5c42-98c6-ff1f3baf88f0"), "CairoMakie"),
    Base.PkgId(Base.UUID("8e980c4a-a4fe-5da2-b3a7-4b4b0353a2f4"), "Shapefile"),
    Base.PkgId(Base.UUID("a90b1aa1-3769-5649-ba7e-abc5a9d163eb"), "LibGEOS"),
]

"The names of the plotting packages that cannot be found in the active environment(s)."
missingRenderPackages() = [p.name for p in RENDER_PACKAGES if Base.locate_package(p) === nothing]

"""
    renderExtension() -> Module

The AtlasUtilitiesRenderExt extension module, loading the plotting packages first if they are installed but
not yet loaded. Errors, saying how to install them, if they are not installed.
"""
function renderExtension()
    ext = Base.get_extension(@__MODULE__, :AtlasUtilitiesRenderExt)
    ext === nothing || return ext
    missing = missingRenderPackages()
    isempty(missing) || error("""
        atlas render needs the plotting packages $(join(missing, ", ")), which are not installed.
        Install them once with:
            atlas install-render
        (from Julia: `import Pkg; Pkg.add(["CairoMakie", "Shapefile", "LibGEOS"])` in the environment you use
        AtlasUtilities from).""")
    foreach(Base.require, RENDER_PACKAGES)
    ext = Base.get_extension(@__MODULE__, :AtlasUtilitiesRenderExt)
    ext === nothing && error("atlas render: the plotting packages loaded, but the AtlasUtilitiesRenderExt " *
                             "extension did not. Check that their versions satisfy AtlasUtilities' [compat].")
    return ext
end

# The extension's methods are defined after these callers were compiled, hence `invokelatest`.
"""
    run_render(atlas, geo; key, map=1, format="png", out="", ...)

Draw one map of `atlas` as a filled-precinct choropleth and save it; see `atlas render --help`. Needs the
plotting packages (see `renderExtension`).
"""
run_render(args...; kw...) = Base.invokelatest(renderExtension().run_render, args...; kw...)

"""
    render_map(...)

Build the Makie figure of one districting (the drawing behind `run_render`). Needs the plotting packages.
"""
render_map(args...; kw...) = Base.invokelatest(renderExtension().render_map, args...; kw...)

"""
    districtColors(ndists) -> Vector

Distinct colors, one per district number `1:ndists`. Needs the plotting packages.
"""
districtColors(args...; kw...) = Base.invokelatest(renderExtension().districtColors, args...; kw...)

"""
    run_install_render(; io=stdout)

Add the plotting packages `atlas render` needs to the active Julia environment (for the installed `atlas`
command, its own environment) and precompile them.
"""
function run_install_render(; io::IO = stdout)
    missing = missingRenderPackages()
    if isempty(missing)
        println(io, "The plotting packages for `atlas render` are already installed.")
        return nothing
    end
    println(io, "Installing $(join(missing, ", ")) into $(Base.active_project()) (this takes a few minutes)...")
    Pkg = Base.require(Base.PkgId(Base.UUID("44cfe95a-1eb2-52ea-b672-e2afdf69b78f"), "Pkg"))
    Base.invokelatest(Pkg.add, missing)
    println(io, "Done: `atlas render` is ready.")
    return nothing
end
