# view.jl -- the `atlas view` subcommand.
#
# Like `atlas render` (render.jl), but instead of drawing a single map to a file, loads
# every map of the atlas up front and opens an interactive GLMakie window that steps
# through them: arrow keys move forward/backward, space toggles autoplay, +/- adjust the
# autoplay delay, c/b toggle the county-line/precinct-line overlays, q/Escape closes the
# window (which is also what unblocks the call). District colors are assigned once from
# the district numbers seen across *every* loaded map, so a given district number is the
# same color on every map, including while playing through them.
#
# Loading every map up front is the simplest way to support instant, in either
# direction, frame stepping; for an atlas too large to hold in memory this way, use
# `atlas render --map k` to export a single frame instead.

"""
    loadAllMaps(atlasPath) -> Vector{<:AtlasIO.Map}

Read every map of the atlas at `atlasPath` into memory, in order. Used by `atlas view`
so map-index navigation (arrow keys, autoplay) is instant in either direction; not
suitable for an atlas too large to hold in memory (use `atlas render --map k` instead).
"""
function loadAllMaps(atlasPath::AbstractString)
    io = smartOpen(String(atlasPath), "r")
    atlas = openAtlas(io)
    maps = []
    while !eof(atlas)
        push!(maps, nextMap(atlas))
    end
    close(atlas)
    isempty(maps) && error("atlas view: $atlasPath has no maps.")
    return maps
end

"""
    run_view(atlas, geo; key, map = 1, strip_suffix = "", county_column = "",
             county_lines = false, precinct_lines = true, skip_missing = false,
             play = false, delay = 400, quiet = false)

Load every map of `atlas` and open it in an interactive GLMakie window, colored by
district, using `geo` (a shapefile or point-graph JSON, see `render.jl`'s module
docstring) for geometry matched to node ids via `--key`. District colors are assigned
once across every loaded map (so a district number is the same color everywhere), unlike
`atlas render` which only ever sees one map. Blocks until the window is closed.

# Keys

- `←`/`→`: step to the previous/next map (wrapping around at either end).
- `space`: toggle autoplay.
- `+`/`-`: decrease/increase the autoplay delay (`kp_add`/`equal` and
  `kp_subtract`/`minus`).
- `c`: toggle the county-line overlay (only visible when `--county-column` is given).
- `b`: toggle the precinct-line (per-row stroke) overlay.
- `q`/`Escape`: close the window.

`--strip-suffix`, `--county-column`, `--county-lines`, `--precinct-lines`, and
`--skip-missing` all work exactly as in `atlas render`; see its help for details.
`--play`/`--delay` set the initial autoplay state instead of always starting paused on
`--map`.
"""
function run_view(atlasPath::AbstractString, geo::AbstractString;
                  key::AbstractString = "", map::Integer = 1,
                  strip_suffix::AbstractString = "", county_column::AbstractString = "",
                  county_lines::Bool = false, precinct_lines::Bool = true,
                  skip_missing::Bool = false, play::Bool = false, delay::Integer = 400,
                  quiet::Bool = false)
    map >= 1 || error("atlas view: --map must be >= 1 (got $map).")
    delay >= 10 || error("atlas view: --delay must be >= 10 (ms), got $delay.")
    isempty(key) &&
        error("atlas view: --key is required (the shapefile attribute column, or " *
              "point-graph node attribute, matching the atlas's node ids).")

    src = loadGeoSource(geo, key; county_column = county_column, county_lines = county_lines)
    try
        maps = loadAllMaps(atlasPath)
        nMaps = length(maps)
        map <= nMaps ||
            error("atlas view: $atlasPath only has $nMaps map(s); --map $map is out of range.")
        nRows = length(src.geometries)

        splitCommas = !isPointGraphPath(geo)
        rowDistricts = Vector{Vector{Int}}(undef, nMaps)
        totalFullyMissing = totalPartiallyMissing = totalCountyFallbacks = 0
        for (i, m) in enumerate(maps)
            rd, fullyMissing, partiallyMissing, countyFallbacks =
                matchMapToRows(m.districting, src.tokenIndex, src.countyIndex, nRows;
                               strip_suffix = strip_suffix, split_commas = splitCommas)
            rowDistricts[i] = rd
            totalFullyMissing += fullyMissing
            totalPartiallyMissing += partiallyMissing
            totalCountyFallbacks += countyFallbacks
        end
        reportMatchQuality(totalFullyMissing, totalPartiallyMissing, totalCountyFallbacks,
                          key, strip_suffix, county_column, skip_missing, quiet;
                          label = "atlas view")
        any(rd -> any(!=(0), rd), rowDistricts) ||
            error("atlas view: no node id matched any geometry record; nothing to draw.")

        globalMax = maximum(maximum(rd) for rd in rowDistricts)
        colors = districtColors(globalMax)
        transparent = Colors.RGBA(0, 0, 0, 0)
        colorsForMap = [[d == 0 ? transparent : colors[d] for d in rd] for rd in rowDistricts]

        GLMakie.activate!()
        fig = Makie.Figure()
        ax = Makie.Axis(fig[1, 1]; aspect = Makie.DataAspect())
        mapIndex = Makie.Observable(map)
        colorObs = Makie.Observable(colorsForMap[map])
        strokeObs = Makie.Observable(precinct_lines ? 0.3 : 0.0)
        titleObs = Makie.Observable("")
        playObs = Makie.Observable(play)
        delayObs = Makie.Observable(Float64(delay))
        countyVisibleObs = Makie.Observable(county_lines && !isempty(src.countyBoundary))

        function updateTitle!()
            titleObs[] = "map $(mapIndex[])/$nMaps: $(maps[mapIndex[]].name)" *
                         (playObs[] ? "  [playing, $(round(Int, delayObs[]))ms]" : "  [paused]")
            return nothing
        end
        function setMap!(i::Integer)
            mapIndex[] = i
            colorObs[] = colorsForMap[i]
            updateTitle!()
            return nothing
        end
        updateTitle!()

        Makie.poly!(ax, src.geometries; color = colorObs, strokewidth = strokeObs,
                   strokecolor = (:black, 0.4))
        if !isempty(src.countyBoundary)
            pts = Point2f[]
            for (a, b) in src.countyBoundary
                push!(pts, a); push!(pts, b)
            end
            Makie.linesegments!(ax, pts; color = :black, linewidth = 1.5,
                               visible = countyVisibleObs)
        end
        Makie.hidedecorations!(ax)
        Makie.hidespines!(ax)
        Makie.Label(fig[0, 1], titleObs; fontsize = 16)

        screen = display(fig)
        windowOpen = Makie.events(fig.scene).window_open

        Makie.on(Makie.events(fig.scene).keyboardbutton) do ev
            (ev.action == Makie.Keyboard.press || ev.action == Makie.Keyboard.repeat) || return
            if ev.key == Makie.Keyboard.right
                setMap!(mapIndex[] == nMaps ? 1 : mapIndex[] + 1)
            elseif ev.key == Makie.Keyboard.left
                setMap!(mapIndex[] == 1 ? nMaps : mapIndex[] - 1)
            elseif ev.key == Makie.Keyboard.space
                playObs[] = !playObs[]
                updateTitle!()
            elseif ev.key in (Makie.Keyboard.equal, Makie.Keyboard.kp_add)
                delayObs[] = max(10.0, delayObs[] - 50)
                updateTitle!()
            elseif ev.key in (Makie.Keyboard.minus, Makie.Keyboard.kp_subtract)
                delayObs[] = delayObs[] + 50
                updateTitle!()
            elseif ev.key == Makie.Keyboard.c
                isempty(src.countyBoundary) || (countyVisibleObs[] = !countyVisibleObs[])
            elseif ev.key == Makie.Keyboard.b
                strokeObs[] = strokeObs[] > 0 ? 0.0 : 0.3
            elseif ev.key in (Makie.Keyboard.q, Makie.Keyboard.escape)
                GLMakie.destroy!(screen)
            end
            return
        end

        @async begin
            while windowOpen[]
                if playObs[]
                    sleep(delayObs[] / 1000)
                    (playObs[] && windowOpen[]) &&
                        setMap!(mapIndex[] == nMaps ? 1 : mapIndex[] + 1)
                else
                    sleep(0.05)
                end
            end
        end

        quiet ||
            println("atlas view: arrows step, space plays, +/- adjust delay, c/b toggle " *
                    "county/precinct lines, q/Esc closes the window.")
        wait(screen)
        return nothing
    finally
        src.tmpdir === nothing || rm(src.tmpdir; recursive = true, force = true)
    end
end
