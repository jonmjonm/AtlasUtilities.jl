# render.jl -- the `atlas render` subcommand.
#
# Draw one map of an atlas as a filled-precinct choropleth (colored by district)
# using a shapefile for the precinct geometry, and save it to an image file.
#
# A CycleWalk atlas stores only districtings (node id -> district number), not
# geometry, so a shapefile supplying the precinct polygons must be given via
# `shapefile` (a `.shp` path, or a `.zip` bundling `.shp`/`.shx`/`.dbf`, which is
# unzipped to a temp directory). `--shapefile-key` names the shapefile's attribute
# column whose values match the atlas's node ids (e.g. `NAME` for the CT/OH
# examples in Data/, whose node-column values are literally the matching shapefile
# attribute).
#
# Some shapefiles pre-merge adjacent precincts into a single record with a
# comma-joined name (e.g. `"Bethel 002-00_FAIRFIELD COUNTY,Bethel 005-00_FAIRFIELD
# COUNTY"`) and a multi-part `Shapefile.Polygon` geometry; the node id in the
# atlas matches that whole joined name as a single string, so the match below is
# always a direct (not split) lookup -- `Shapefile.Polygon`/`poly!` already handle
# multi-part geometry as one shape.

"""Unzip `path` (a shapefile bundle) to a fresh temp directory and return the
path to the `.shp` file found inside. If `path` already ends in `.shp`, return it
unchanged (second return value says whether a temp directory was created, so the
caller knows whether to clean it up)."""
function resolveShapefilePath(path::AbstractString)
    endswith(lowercase(path), ".shp") && return (String(path), nothing)

    endswith(lowercase(path), ".zip") ||
        error("atlas render: shapefile \"$path\" must be a .shp file or a .zip " *
              "bundle containing one.")
    isfile(path) || error("atlas render: shapefile \"$path\" does not exist.")

    tmpdir = mktempdir()
    run(`unzip -o -q $path -d $tmpdir`)

    shp = nothing
    for (root, _, files) in walkdir(tmpdir)
        for f in files
            if lowercase(splitext(f)[2]) == ".shp"
                shp = joinpath(root, f)
                break
            end
        end
        shp === nothing || break
    end
    shp === nothing &&
        error("atlas render: no .shp file found inside \"$path\".")
    return (shp, tmpdir)
end

"""
    loadShapefileGeometries(shpPath, key) -> Dict{String, Vector}

Read the shapefile at `shpPath` and index its geometries by a string key built
from attribute column(s) `key` (a single column name, e.g. `"NAME"`, or a
comma-separated list, e.g. `"county,prec_id"`, for atlases whose node id has
several components -- the columns are joined with `:`, matching
[`nodeIdString`](@ref)'s own join, in the order given). Errors if any named
column is not one of the shapefile's attribute columns. A key value repeated
across rows keeps every matching geometry (all are drawn, e.g. disjoint parts of
one named unit).
"""
function loadShapefileGeometries(shpPath::AbstractString, key::AbstractString)
    tbl = Shapefile.Table(shpPath)
    cols = propertynames(tbl)
    keySyms = Symbol.(strip.(split(key, ',')))
    for s in keySyms
        s in cols ||
            error("atlas render: --shapefile-key \"$s\" is not a column of " *
                  "\"$shpPath\"; available columns: " *
                  join(sort(String.(filter(!=(:geometry), cols))), ", "))
    end

    geoms = Dict{String, Vector{Any}}()
    for row in tbl
        k = join((string(getproperty(row, s)) for s in keySyms), ":")
        push!(get!(geoms, k, Any[]), row.geometry)
    end
    return geoms
end

"""District colors, one per district number `1:ndists`, chosen to be mutually
distinguishable (and distinct from a white/black map background/stroke)."""
function districtColors(ndists::Integer)
    ndists >= 1 || error("atlas render: atlas map has no districts.")
    return Colors.distinguishable_colors(ndists, [Colors.RGB(1, 1, 1), Colors.RGB(0, 0, 0)];
                                         dropseed = true)
end

const RENDER_FORMATS = ("png", "svg", "pdf")

"""
    run_render(atlas, shapefile; shapefile_key, map = 1, format = "png",
               out = "", quiet = false)

Draw the `map`-th map of `atlas` (1-based) as a choropleth colored by district,
using `shapefile` for precinct geometry matched to node ids via
`--shapefile-key`, and save it to `out` (default `<atlas basename>-map<k>.<format>`
next to the atlas).
"""
function run_render(atlasPath::AbstractString, shapefile::AbstractString;
                    shapefile_key::AbstractString = "", map::Integer = 1,
                    format::AbstractString = "png", out::AbstractString = "",
                    quiet::Bool = false)
    map >= 1 || error("atlas render: --map must be >= 1 (got $map).")
    isempty(shapefile_key) &&
        error("atlas render: --shapefile-key is required (the shapefile attribute " *
              "column matching the atlas's node ids).")
    format in RENDER_FORMATS ||
        error("atlas render: --format must be one of $(join(RENDER_FORMATS, ", ")), " *
              "got \"$format\".")

    shpPath, tmpdir = resolveShapefilePath(shapefile)
    try
        geoms = loadShapefileGeometries(shpPath, shapefile_key)

        io = smartOpen(String(atlasPath), "r")
        atlas = openAtlas(io)
        map > 1 && skipMap(atlas; numSkip = map - 1)
        eof(atlas) &&
            error("atlas render: $atlasPath does not have a map $map.")
        m = nextMap(atlas)
        close(atlas)

        allGeoms = Any[]
        allDists = Int[]
        missingIds = String[]
        for (node, dist) in m.districting
            id = nodeIdString(node)
            if haskey(geoms, id)
                for g in geoms[id]
                    push!(allGeoms, g)
                    push!(allDists, dist)
                end
            else
                push!(missingIds, id)
            end
        end

        if !isempty(missingIds)
            examples = join(first(sort(missingIds), 5), "\", \"")
            error("atlas render: $(length(missingIds)) node id(s) had no " *
                  "matching shapefile record under --shapefile-key \"$shapefile_key\" " *
                  "(e.g. \"$examples\"); check --shapefile-key names the right column.")
        end

        colors = districtColors(maximum(allDists))
        pointColors = [colors[d] for d in allDists]

        fig = CairoMakie.Figure()
        ax = CairoMakie.Axis(fig[1, 1]; aspect = CairoMakie.DataAspect())
        CairoMakie.poly!(ax, allGeoms; color = pointColors,
                         strokewidth = 0.3, strokecolor = (:black, 0.4))
        CairoMakie.hidedecorations!(ax)
        CairoMakie.hidespines!(ax)

        outpath = isempty(out) ? stripAtlasExt(String(atlasPath)) * "-map$(map).$(format)" :
                                  String(out)
        CairoMakie.save(outpath, fig)
        quiet || println("Wrote map $map (", length(unique(allDists)),
                          " districts) to ", outpath)
        return nothing
    finally
        tmpdir === nothing || rm(tmpdir; recursive = true, force = true)
    end
end
