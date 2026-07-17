#!/usr/bin/env julia
#
# make_demos.jl — generate the small demo atlases shipped in examples/.
#
# Each demo is a gzip-compressed atlas whose header embeds THIS script as its
# "script" entry, so `atlas info <demo> --extract-script` writes a runnable copy
# back out. The atlases are intentionally tiny (toy grids), so the whole set is
# a few kilobytes.
#
# Run from the repo root:
#     julia --project=. examples/make_demos.jl
#
# Produces, in examples/:
#     demo_grid_4x4.jsonl.gz       4x4 grid, 4 districts, 6 label-permuted maps
#     demo_multiscale.jsonl.gz     mixed-resolution maps over a county/prec graph
#     demo_multiscale_graph.json   dual graph for the multiscale demo
#
# The grid demo is good for BOTH subcommands: `atlas info` shows the header, and
# `atlas reorder` canonicalizes the permuted district labels. The multiscale demo
# shows `atlas reorder <in> <out> demo_multiscale_graph.json`.
#
# The real North Carolina demo atlases in examples/ are NOT built here — they are
# 100-map slices of full CycleWalk runs (see the README for provenance).

using AtlasIO
using Dates

const HERE = @__DIR__
const SRC  = read(@__FILE__, String)      # embed this file as each atlas's script
const USER = get(ENV, "USER", get(ENV, "USERNAME", "unknown"))

"""Header (line-3) params for a demo, including the embedded run script."""
function header(stem; districts, extra...)
    param = Dict{String,Any}(
        "districts"   => districts,
        "created_at"  => string(now()),
        "user"        => USER,
        "notes"       => "toy demo atlas for AtlasUtilities; regenerate with examples/make_demos.jl",
        "script_name" => stem * ".jl",
        "script"      => SRC,
    )
    for (k, v) in extra
        param[String(k)] = v
    end
    return param
end

"""Write `maps` (a vector of name => districting) to examples/<stem>.jsonl.gz."""
function writeAtlas(stem, atlasParam, maps)
    path = joinpath(HERE, stem * ".jsonl.gz")
    io = smartOpen(path, "w")
    newAtlas(io, AtlasHeader(stem, Dict{String,Any}, Dict{String,Any}), atlasParam)
    for (name, dist) in maps
        addMap(io, Map(name, dist, 1, Dict{String,Any}()))
    end
    close(io)
    println("wrote ", relpath(path), " (", filesize(path), " bytes)")
    return path
end

# ---------------------------------------------------------------------------
# Grid helpers
# ---------------------------------------------------------------------------

"""Relabel a districting's values by `perm` (`old -> perm[old]`)."""
permuteLabels(dist, perm) = Districting(k => perm[v] for (k, v) in dist)

"""Base 4x4 grid split into four quadrants labeled 1..4."""
function grid4x4()
    d = Districting()
    for r in 0:3, c in 0:3
        d[("n$(r*4 + c)",)] = (r < 2 ? 0 : 2) + (c < 2 ? 1 : 2)   # -> 1,2,3,4
    end
    return d
end

# ---------------------------------------------------------------------------
# Build the demos
# ---------------------------------------------------------------------------

# 4x4 grid: same quadrant partition every map, but district labels permuted, so
# `atlas reorder` has something to canonicalize.
let base = grid4x4(),
    perms = [[1, 2, 3, 4], [2, 1, 4, 3], [3, 4, 1, 2], [4, 3, 2, 1], [2, 3, 4, 1], [1, 3, 2, 4]]
    maps = ["map$(k)" => permuteLabels(base, perms[k]) for k in eachindex(perms)]
    writeAtlas("demo_grid_4x4",
               header("demo_grid_4x4"; districts = 4,
                      energies = ["get_isoperimetric_score"], var"energy weights" = [1.0],
                      state = "GRID"),
               maps)
end

# Multiscale: 2 counties (X, Y) each with 3 precincts. Map 1 is coarse
# (county-level); maps 2-3 are at precinct resolution. Reorder needs the dual
# graph to resolve the differing node sets to a common resolution.
let
    maps = [
        "map1" => Districting(("X",) => 1, ("Y",) => 2),                      # coarse
        "map2" => Districting(("X","1") => 2, ("X","2") => 2, ("X","3") => 2, # same partition, swapped labels
                              ("Y","1") => 1, ("Y","2") => 1, ("Y","3") => 1),
        "map3" => Districting(("X","1") => 1, ("X","2") => 1, ("X","3") => 2, # a different partition
                              ("Y","1") => 2, ("Y","2") => 1, ("Y","3") => 2),
    ]
    writeAtlas("demo_multiscale",
               header("demo_multiscale"; districts = 2,
                      var"levels in graph" = ["county", "prec"]),
               maps)

    # The matching dual graph (NetworkX node-link JSON): one node per finest unit.
    nodes = ["""{"id":$(i-1),"county":"$c","prec":"$p"}"""
             for (i, (c, p)) in enumerate((c, p) for c in ("X", "Y") for p in ("1", "2", "3"))]
    graph = """{"directed":false,"multigraph":false,"graph":[],"nodes":[$(join(nodes, ","))]}"""
    gpath = joinpath(HERE, "demo_multiscale_graph.json")
    write(gpath, graph)
    println("wrote ", relpath(gpath), " (", filesize(gpath), " bytes)")
end
