# render.jl -- the `atlas render` subcommand, and the geometry-loading /
# node-matching machinery behind it.
#
# Draw one map of an atlas as a filled-precinct choropleth (colored by district),
# using either a shapefile or a point-position node-link JSON graph (see
# pointgraph.jl) for geometry, and save it to an image file.
#
# A CycleWalk atlas stores only districtings (node id -> district number), not
# geometry, so a geometry source supplying each node's shape must be given as `geo`:
# a shapefile (a `.shp` path, or a `.zip` bundling `.shp`/`.shx`/`.dbf`, which is
# unzipped to a temp directory), or a `.json` point-position node-link graph (e.g.
# Data/hex_graph_10_by_10.json), whose cells are its nodes' Voronoi regions (see
# pointgraph.jl). `--key` names the attribute (shapefile column, or JSON node
# attribute) whose values match the atlas's node ids (e.g. `NAME` for the CT/OH
# shapefile examples in Data/, or `node_name` for the point-graph examples).
#
# Both shapefiles and graph-building can independently merge several underlying
# precincts into one record with a comma-joined name, and the two merges don't
# always line up (a graph built for legislative-district consistency can split a
# shapefile's own merged record across two different graph nodes). So matching is
# done at the level of comma-split "atomic" precinct names: every atomic name
# found anywhere in the geometry source is indexed to the row that contains it, and
# a queried node id is matched atomic-name by atomic-name, deduplicating by row so a
# row whose merge is fully contained in one node is drawn once. A node whose
# graph-level merge cuts across a row's merge will still draw that whole row (the
# source has no finer boundary to offer), so neighboring nodes sharing that row can
# visually overlap at that boundary -- a shapefile/graph vintage mismatch, not a bug.
#
# `--strip-suffix` optionally strips a trailing regex from each node id before
# matching -- e.g. CycleWalk graphs built for legislative-district consistency
# can suffix a node id with `__SD<n>__HD<n>` tags that have no geometry counterpart.
#
# Some graphs only keep precinct-level detail for counties split by a district
# line, and represent an entire unsplit county as a single node (e.g. NC's
# `("GASTON",)`), which can never match one precinct-level shapefile record.
# `--county-column` names the attribute (shapefile column, or JSON node attribute)
# holding each row's county (matched case-insensitively), so such a node -- one
# whose id matches no precinct token at all -- falls back to every row in that
# county, all drawn in the node's district color.
#
# `--county-column` also drives `--county-lines`: for a shapefile, every row sharing
# a `--county-column` value is dissolved (unioned) via LibGEOS into that county's true
# polygon, and its boundary is drawn on top of the precinct fill; for a point-graph,
# the graph's own adjacency already tells us which neighboring cells cross a county
# line, so that exact shared edge is used directly (see pointgraph.jl's
# `countyBoundarySegments`) -- no geometry library needed there.

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
            error("atlas render: --key \"$s\" is not a column of " *
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

"""Convert a `Shapefile.Polygon`'s flat `points`/`parts` into the ring-of-coordinate-
pairs structure LibGEOS's `Polygon`/`MultiPolygon` constructors expect: a `Vector` of
rings, each ring a `Vector` of `[x, y]` `Vector{Float64}` points."""
function shapefilePolygonToRings(g::Shapefile.Polygon)
    parts = Int.(g.parts)
    n = length(g.points)
    starts = vcat(parts, Int32(n))
    rings = Vector{Vector{Vector{Float64}}}()
    for k in eachindex(parts)
        i0 = starts[k] + 1
        i1 = starts[k + 1]
        push!(rings, [[p.x, p.y] for p in g.points[i0:i1]])
    end
    return rings
end

"""The exterior and interior ring segments of a `LibGEOS.Polygon`/`MultiPolygon`
(one polygon per element for a `MultiPolygon`, e.g. a county split across two land
masses), as `(Point2f, Point2f)` pairs -- used to draw a dissolved county's outline."""
function polygonBoundarySegments(geom)
    polys = geom isa LibGEOS.MultiPolygon ? LibGEOS.getGeometries(geom) : [geom]
    segs = Tuple{Point2f, Point2f}[]
    for poly in polys
        rings = vcat([LibGEOS.exteriorRing(poly)], LibGEOS.interiorRings(poly))
        for ring in rings
            coords = LibGEOS.GeoInterface.coordinates(ring)
            for k in 1:(length(coords) - 1)
                a, b = coords[k], coords[k + 1]
                push!(segs, (Point2f(a[1], a[2]), Point2f(b[1], b[2])))
            end
        end
    end
    return segs
end

"""
    dissolvedCountyBoundarySegments(geometries, countyIndex) -> Vector{Tuple{Point2f,Point2f}}

For each county in `countyIndex`, union (dissolve) its rows' geometries with LibGEOS
into that county's true polygon and collect its boundary as line segments (see
[`polygonBoundarySegments`](@ref)) -- the `--county-lines` overlay for a shapefile
source. A county whose rows fail to form valid geometry (self-intersecting shapefile
rings, etc.) is skipped with a warning rather than aborting the whole render.
"""
function dissolvedCountyBoundarySegments(geometries::AbstractVector,
                                         countyIndex::Dict{String, Vector{Int}})
    segs = Tuple{Point2f, Point2f}[]
    for (county, idxs) in countyIndex
        try
            ringsList = [shapefilePolygonToRings(geometries[i]) for i in idxs]
            dissolved = length(ringsList) == 1 ? LibGEOS.Polygon(ringsList[1]) :
                        LibGEOS.unaryUnion(LibGEOS.MultiPolygon(ringsList))
            append!(segs, polygonBoundarySegments(dissolved))
        catch e
            @warn "atlas render: could not dissolve county \"$county\" for " *
                  "--county-lines; skipping its outline." exception = e
        end
    end
    return segs
end

"""District colors, one per district number `1:ndists`, chosen to be mutually
distinguishable (and distinct from a white/black map background/stroke)."""
function districtColors(ndists::Integer)
    ndists >= 1 || error("atlas render: atlas map has no districts.")
    return Colors.distinguishable_colors(ndists, [Colors.RGB(1, 1, 1), Colors.RGB(0, 0, 0)];
                                         dropseed = true)
end

"""Open the file at `path` in the OS's default viewer for its type (`open` on
macOS, `xdg-open` on Linux)."""
function openInViewer(path::AbstractString)
    if Sys.isapple()
        run(`open $path`)
    elseif Sys.islinux()
        run(`xdg-open $path`)
    else
        @warn "atlas render: don't know how to open a viewer on this OS; " *
              "the image was saved to $path"
    end
    return nothing
end

const RENDER_FORMATS = ("png", "svg", "pdf")

"""`true` if `path` names a point-position node-link JSON graph (see pointgraph.jl)
rather than a shapefile -- decided purely from the extension, matching how
`atlas add`/`atlas extract-map-data` already treat a `--graph` path."""
isPointGraphPath(path::AbstractString) = lowercase(splitext(path)[2]) == ".json"

"""
    loadGeoSource(geo, key; county_column = "", county_lines = false)
        -> (tokenIndex, geometries, countyIndex, countyBoundary, tmpdir)

Dispatch on `geo`'s extension to load either a shapefile ([`loadShapefileGeometries`](@ref),
via [`resolveShapefilePath`](@ref)) or a point-graph JSON ([`loadPointGraphGeometries`](@ref)),
returning a common shape consumed by [`render_map`](@ref):
`tokenIndex`/`geometries` as those functions return; `countyIndex` (shapefile only --
empty for a point-graph, which has no precinct/county-merge ambiguity to fall back
on); `countyBoundary`, the `--county-lines` overlay segments (dissolved via LibGEOS for
a shapefile, read off the graph's own adjacency for a point-graph -- see pointgraph.jl);
and `tmpdir`, the temp directory a zipped shapefile was unzipped to (`nothing`
otherwise), which the caller must remove when done.
"""
function loadGeoSource(geo::AbstractString, key::AbstractString;
                       county_column::AbstractString = "", county_lines::Bool = false)
    county_lines && isempty(county_column) &&
        error("atlas render: --county-lines needs --county-column (the shapefile " *
              "column, or point-graph node attribute, holding each row's county).")
    if isPointGraphPath(geo)
        tokenIndex, geometries, countyBoundary =
            loadPointGraphGeometries(geo, key;
                                     county_column = county_lines ? county_column : "")
        return (tokenIndex = tokenIndex, geometries = geometries,
                countyIndex = Dict{String, Vector{Int}}(), countyBoundary = countyBoundary,
                tmpdir = nothing)
    end
    shpPath, tmpdir = resolveShapefilePath(geo)
    tokenIndex, geometries, countyIndex =
        loadShapefileGeometries(shpPath, key; county_column = county_column)
    countyBoundary = county_lines ? dissolvedCountyBoundarySegments(geometries, countyIndex) :
                      Tuple{Point2f, Point2f}[]
    return (tokenIndex = tokenIndex, geometries = geometries, countyIndex = countyIndex,
            countyBoundary = countyBoundary, tmpdir = tmpdir)
end

"""
    matchMapToRows(districting, tokenIndex, countyIndex, nRows; strip_suffix = "",
                   split_commas = true)
        -> (rowDistrict, fullyMissing, partiallyMissing, countyFallbacks)

Match every node id in `districting` to geometry row(s) exactly as the `render.jl`
module docstring describes (comma-split atomic tokens against `tokenIndex`, falling
back to `countyIndex` case-insensitively when a node id matches no token at all), and
return `rowDistrict`, a `nRows`-long `Vector{Int}` giving each row's district number
(`0` for a row no node claimed). `strip_suffix`, if given, is a regex stripped from the
end of each node id before matching. `split_commas` disables the comma-splitting (a
shapefile-only concern -- a point-graph node is already 1:1 with its Voronoi cell, and
its `key` attribute, e.g. `"(3,7)"` node names, can itself contain a comma that has
nothing to do with a merged-precinct list); [`loadGeoSource`](@ref)'s callers pass
`false` for a point-graph source. Also returns the match-quality counts `render_map`
reports: how many node ids matched no row at all (`fullyMissing`), how
many matched only some of their comma-joined parts (`partiallyMissing`), and how many
resolved via the `countyIndex` whole-county fallback (`countyFallbacks`).
"""
function matchMapToRows(districting, tokenIndex::Dict{String, Int},
                        countyIndex::Dict{String, Vector{Int}}, nRows::Integer;
                        strip_suffix::AbstractString = "", split_commas::Bool = true)
    suffixRe = isempty(strip_suffix) ? nothing : Regex(strip_suffix * raw"$")
    rowDistrict = zeros(Int, nRows)
    fullyMissing = 0
    partiallyMissing = 0
    countyFallbacks = 0
    for (node, dist) in districting
        id = nodeIdString(node)
        suffixRe === nothing || (id = replace(id, suffixRe => ""))
        tokens = split_commas ? strip.(split(id, ',')) : [id]
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
            rowDistrict[i] = dist
        end
    end
    return rowDistrict, fullyMissing, partiallyMissing, countyFallbacks
end

"""Print (unless `quiet`) the `matchMapToRows` match-quality summary, and either error
or continue past it per `skip_missing`, exactly as `render_map` describes for
`--skip-missing`."""
function reportMatchQuality(fullyMissing::Integer, partiallyMissing::Integer,
                            countyFallbacks::Integer, key::AbstractString,
                            strip_suffix::AbstractString, county_column::AbstractString,
                            skip_missing::Bool, quiet::Bool; label::AbstractString = "atlas render")
    if fullyMissing > 0 || partiallyMissing > 0
        msg = "$label: $fullyMissing node(s) had no matching geometry record at all, " *
              "and $partiallyMissing more matched only some of their (comma-joined) " *
              "parts, under --key \"$key\"" *
              (isempty(strip_suffix) ? "" : " and --strip-suffix \"$strip_suffix\"") * "."
        if skip_missing
            quiet || println(msg, " Continuing (--skip-missing); those areas are left blank.")
        else
            error(msg * " Pass --skip-missing to render anyway, leaving those areas " *
                  "blank, or check --key/--strip-suffix/--county-column.")
        end
    end
    quiet || countyFallbacks == 0 ||
        println("$label: ", countyFallbacks, " node(s) drawn as a full county ",
                "(--county-column \"$county_column\" fallback).")
    return nothing
end

"""
    render_map(atlas, geo; key, map = 1, strip_suffix = "", county_column = "",
               county_lines = false, precinct_lines = true, skip_missing = false,
               quiet = false)
        -> Makie.Figure

Build (but do not save or display) a `Makie.Figure` drawing the `map`-th map of
`atlas` (1-based) as a choropleth colored by district, using `geo` (a shapefile or
point-graph JSON, see the module docstring) for geometry matched to node ids via
`--key`. `--strip-suffix` (a regex) is removed from the end of each node id before
matching. `--county-column` names the geometry source's county attribute, so a node id
matching no precinct token at all but matching a county name instead (case-
insensitively) falls back to every precinct in that county; `--county-lines` additionally
draws each county's outline (dissolved via LibGEOS for a shapefile, or read off the
graph's adjacency for a point-graph). `--precinct-lines` (default on) toggles the
per-row stroke. By default a node id with no matching geometry record is an error;
`--skip-missing` instead leaves it undrawn and prints a summary. What happens to the
returned figure is up to the caller and whichever Makie backend is active --
[`run_render`](@ref) activates CairoMakie and saves it to a file.
"""
function render_map(atlasPath::AbstractString, geo::AbstractString;
                    key::AbstractString = "", map::Integer = 1,
                    strip_suffix::AbstractString = "", county_column::AbstractString = "",
                    county_lines::Bool = false, precinct_lines::Bool = true,
                    skip_missing::Bool = false, quiet::Bool = false)
    map >= 1 || error("atlas render: --map must be >= 1 (got $map).")
    isempty(key) &&
        error("atlas render: --key is required (the shapefile attribute column, or " *
              "point-graph node attribute, matching the atlas's node ids).")

    src = loadGeoSource(geo, key; county_column = county_column, county_lines = county_lines)
    try
        io = smartOpen(String(atlasPath), "r")
        atlas = openAtlas(io)
        map > 1 && skipMap(atlas; numSkip = map - 1)
        eof(atlas) &&
            error("atlas render: $atlasPath does not have a map $map.")
        m = nextMap(atlas)
        close(atlas)

        nRows = length(src.geometries)
        rowDistrict, fullyMissing, partiallyMissing, countyFallbacks =
            matchMapToRows(m.districting, src.tokenIndex, src.countyIndex, nRows;
                           strip_suffix = strip_suffix, split_commas = !isPointGraphPath(geo))
        reportMatchQuality(fullyMissing, partiallyMissing, countyFallbacks, key,
                          strip_suffix, county_column, skip_missing, quiet)

        matchedRows = findall(!=(0), rowDistrict)
        isempty(matchedRows) &&
            error("atlas render: no node id matched any geometry record; nothing to draw.")

        colors = districtColors(maximum(rowDistrict[matchedRows]))
        pointColors = [d == 0 ? Colors.RGBA(0, 0, 0, 0) : colors[d] for d in rowDistrict]

        fig = Makie.Figure()
        ax = Makie.Axis(fig[1, 1]; aspect = Makie.DataAspect())
        Makie.poly!(ax, src.geometries; color = pointColors,
                   strokewidth = precinct_lines ? 0.3 : 0.0, strokecolor = (:black, 0.4))
        if county_lines && !isempty(src.countyBoundary)
            pts = Point2f[]
            for (a, b) in src.countyBoundary
                push!(pts, a); push!(pts, b)
            end
            Makie.linesegments!(ax, pts; color = :black, linewidth = 1.5)
        end
        Makie.hidedecorations!(ax)
        Makie.hidespines!(ax)
        return fig
    finally
        src.tmpdir === nothing || rm(src.tmpdir; recursive = true, force = true)
    end
end

"""
    run_render(atlas, geo; key, map = 1, format = "png", out = "", strip_suffix = "",
               county_column = "", county_lines = false, precinct_lines = true,
               skip_missing = false, show = false, quiet = false)

Build the map via [`render_map`](@ref) and save it to `out` (default
`<atlas basename>-map<k>.<format>` next to the atlas), using CairoMakie.
`--show` opens the saved file in the OS's default viewer after writing it.
"""
function run_render(atlasPath::AbstractString, geo::AbstractString;
                    key::AbstractString = "", map::Integer = 1,
                    format::AbstractString = "png", out::AbstractString = "",
                    strip_suffix::AbstractString = "", county_column::AbstractString = "",
                    county_lines::Bool = false, precinct_lines::Bool = true,
                    skip_missing::Bool = false, show::Bool = false, quiet::Bool = false)
    format in RENDER_FORMATS ||
        error("atlas render: --format must be one of $(join(RENDER_FORMATS, ", ")), " *
              "got \"$format\".")

    CairoMakie.activate!()
    fig = render_map(atlasPath, geo; key = key, map = map,
                     strip_suffix = strip_suffix, county_column = county_column,
                     county_lines = county_lines, precinct_lines = precinct_lines,
                     skip_missing = skip_missing, quiet = quiet)

    outpath = isempty(out) ? stripAtlasExt(String(atlasPath)) * "-map$(map).$(format)" :
                              String(out)
    CairoMakie.save(outpath, fig)
    quiet || println("Wrote map $map to ", outpath)
    show && openInViewer(outpath)
    return nothing
end
