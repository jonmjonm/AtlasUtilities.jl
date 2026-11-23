"""
    AtlasUtilitiesRenderExt

The `atlas render` implementation: draw a map's districting as a filled-precinct choropleth, using a shapefile
or a point-position node-link JSON graph for geometry. A package extension, loaded only when its plotting
packages are, so the rest of AtlasUtilities never installs or loads them. AtlasUtilities' exported
`run_render`, `render_map` and `districtColors` call into this module (see AtlasUtilities' src/render.jl).
"""
module AtlasUtilitiesRenderExt

# Only `import` AtlasUtilities: this module defines its own `run_render`, `render_map` and `districtColors`,
# which AtlasUtilities' exported functions of the same names call.
import AtlasUtilities
using AtlasUtilities: column, nodeIdString, stripAtlasExt, JSON, JSON3
using AtlasUtilities.AtlasIO: smartOpen, openAtlas, nextMap, skipMap
using CairoMakie
using Colors
using LibGEOS
using Makie
using Shapefile

include("pointgraph.jl")
include("render.jl")

end
