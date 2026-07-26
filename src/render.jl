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
# Both shapefiles and graph-building can independently merge several underlying
# precincts into one record with a comma-joined name, and the two merges don't
# always line up (a graph built for legislative-district consistency can split a
# shapefile's own merged record across two different graph nodes). So matching is
# done at the level of comma-split "atomic" precinct names: every atomic name
# found anywhere in the shapefile is indexed to the shapefile row that contains
# it, and a queried node id is matched atomic-name by atomic-name, deduplicating
# by row so a shapefile row whose merge is fully contained in one node is drawn
# once. A node whose graph-level merge cuts across a shapefile row's merge will
# still draw that whole row (the shapefile has no finer boundary to offer), so
# neighboring nodes sharing that row can visually overlap at that boundary --
# a shapefile/graph vintage mismatch, not a bug.
#
# `--strip-suffix` optionally strips a trailing regex from each node id before
# matching -- e.g. CycleWalk graphs built for legislative-district consistency
# can suffix a node id with `__SD<n>__HD<n>` tags that have no shapefile
# counterpart.
#
# Some graphs only keep precinct-level detail for counties split by a district
# line, and represent an entire unsplit county as a single node (e.g. NC's
# `("GASTON",)`), which can never match one precinct-level shapefile record.
# `--county-column` names the shapefile column holding each precinct's county
# (matched case-insensitively), so such a node -- one whose id matches no
# precinct token at all -- falls back to every precinct row in that county,
# all drawn in the node's district color (a plain fill of every precinct
# rather than a true dissolved county polygon, but visually identical for a
# choropleth and needs no polygon-union dependency).

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
    loadShapefileGeometries(shpPath, key; county_column = "")
        -> (tokenIndex, geometries, countyIndex)

Read the shapefile at `shpPath` and return `(tokenIndex, geometries,
countyIndex)`: `geometries[i]` is the geometry of row `i`; `tokenIndex` maps
every comma-split "atomic" piece of row `i`'s key (built from attribute
column(s) `key` -- a single column name, e.g. `"NAME"`, or a comma-separated
list, e.g. `"county,prec_id"`, joined with `:` in the order given, matching
[`nodeIdString`](@ref)'s own join for multi-component node ids) to `i`; and, if
`county_column` is given, `countyIndex` maps each uppercased county name to the
row indices in that county (empty otherwise). Errors if `key` or
`county_column` names a column the shapefile doesn't have.
"""
function loadShapefileGeometries(shpPath::AbstractString, key::AbstractString;
                                 county_column::AbstractString = "")
    tbl = Shapefile.Table(shpPath)
    cols = propertynames(tbl)
    keySyms = Symbol.(strip.(split(key, ',')))
    for s in keySyms
        s in cols ||
            error("atlas render: --shapefile-key \"$s\" is not a column of " *
                  "\"$shpPath\"; available columns: " *
                  join(sort(String.(filter(!=(:geometry), cols))), ", "))
    end
    countySym = nothing
    if !isempty(county_column)
        countySym = Symbol(county_column)
        countySym in cols ||
            error("atlas render: --county-column \"$county_column\" is not a column of " *
                  "\"$shpPath\"; available columns: " *
                  join(sort(String.(filter(!=(:geometry), cols))), ", "))
    end

    geometries = Any[]
    tokenIndex = Dict{String, Int}()
    countyIndex = Dict{String, Vector{Int}}()
    for row in tbl
        push!(geometries, row.geometry)
        i = length(geometries)
        k = join((string(getproperty(row, s)) for s in keySyms), ":")
        for tok in split(k, ',')
            tokenIndex[strip(tok)] = i
        end
        if countySym !== nothing
            cval = uppercase(strip(string(getproperty(row, countySym))))
            push!(get!(countyIndex, cval, Int[]), i)
        end
    end
    return tokenIndex, geometries, countyIndex
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
               out = "", strip_suffix = "", county_column = "",
               skip_missing = false, quiet = false)

Draw the `map`-th map of `atlas` (1-based) as a choropleth colored by district,
using `shapefile` for precinct geometry matched to node ids via
`--shapefile-key`, and save it to `out` (default `<atlas basename>-map<k>.<format>`
next to the atlas). `--strip-suffix` (a regex) is removed from the end of each
node id before matching. `--county-column` names the shapefile's county column,
so a node id matching no precinct token at all but matching a county name
instead (case-insensitively) falls back to every precinct in that county. By
default a node id with no matching shapefile record is an error; `--skip-missing`
instead leaves it undrawn and prints a summary.
"""
function run_render(atlasPath::AbstractString, shapefile::AbstractString;
                    shapefile_key::AbstractString = "", map::Integer = 1,
                    format::AbstractString = "png", out::AbstractString = "",
                    strip_suffix::AbstractString = "", county_column::AbstractString = "",
                    skip_missing::Bool = false, quiet::Bool = false)
    map >= 1 || error("atlas render: --map must be >= 1 (got $map).")
    isempty(shapefile_key) &&
        error("atlas render: --shapefile-key is required (the shapefile attribute " *
              "column matching the atlas's node ids).")
    format in RENDER_FORMATS ||
        error("atlas render: --format must be one of $(join(RENDER_FORMATS, ", ")), " *
              "got \"$format\".")
    suffixRe = isempty(strip_suffix) ? nothing : Regex(strip_suffix * raw"$")

    shpPath, tmpdir = resolveShapefilePath(shapefile)
    try
        tokenIndex, geometries, countyIndex =
            loadShapefileGeometries(shpPath, shapefile_key; county_column = county_column)

        io = smartOpen(String(atlasPath), "r")
        atlas = openAtlas(io)
        map > 1 && skipMap(atlas; numSkip = map - 1)
        eof(atlas) &&
            error("atlas render: $atlasPath does not have a map $map.")
        m = nextMap(atlas)
        close(atlas)

        allGeoms = Any[]
        allDists = Int[]
        fullyMissing = 0
        partiallyMissing = 0
        countyFallbacks = 0
        for (node, dist) in m.districting
            id = nodeIdString(node)
            suffixRe === nothing || (id = replace(id, suffixRe => ""))
            tokens = strip.(split(id, ','))
            rowIdx = Int[]
            nMissing = 0
            for tok in tokens
                if haskey(tokenIndex, tok)
                    push!(rowIdx, tokenIndex[tok])
                else
                    nMissing += 1
                end
            end
            if nMissing == length(tokens) && !isempty(countyIndex)
                fallback = get(countyIndex, uppercase(strip(id)), nothing)
                if fallback !== nothing
                    rowIdx = fallback
                    nMissing = 0
                    countyFallbacks += 1
                end
            end
            if nMissing == length(tokens)
                fullyMissing += 1
            elseif nMissing > 0
                partiallyMissing += 1
            end
            for i in unique(rowIdx)
                push!(allGeoms, geometries[i])
                push!(allDists, dist)
            end
        end

        if fullyMissing > 0 || partiallyMissing > 0
            msg = "atlas render: $fullyMissing node(s) had no matching shapefile " *
                  "record at all, and $partiallyMissing more matched only some of " *
                  "their (comma-joined) parts, under --shapefile-key " *
                  "\"$shapefile_key\"" * (suffixRe === nothing ? "" : " and --strip-suffix \"$strip_suffix\"") * "."
            if skip_missing
                quiet || println(msg, " Continuing (--skip-missing); those areas are left blank.")
            else
                error(msg * " Pass --skip-missing to render anyway, leaving those " *
                      "areas blank, or check --shapefile-key/--strip-suffix/--county-column.")
            end
        end
        quiet || countyFallbacks == 0 ||
            println("atlas render: ", countyFallbacks, " node(s) drawn as a full county ",
                    "(--county-column \"$county_column\" fallback).")

        isempty(allDists) &&
            error("atlas render: no node id matched any shapefile record; nothing to draw.")

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
