# WriterSet / computeWriters: CycleWalk writer statistics computed on maps in memory, the library form of
# `atlas add`. Checked against the values CycleWalk stored in the CT slice and against `atlas add`'s output.

using Test
using AtlasIO
using AtlasUtilities: WriterSet, computeWriters, writerFields, listWriters, run_add, hasFastMethod
import CycleWalk

const WCT_GRAPH = joinpath(@__DIR__, "..", "Data", "CT_pct20.json")
const WCT_ATLAS = joinpath(@__DIR__, "..", "examples", "cycleWalk_ct_slice.jsonl.gz")
const CT_COLS = (graph = WCT_GRAPH, pop_col = "POP20", node_col = "NAME", area_col = "area",
                 border_col = "border_length", edge_perimeter_col = "length")

ctmaps() = (io = smartOpen(WCT_ATLAS, "r"); a = openAtlas(io); ms = Map[]; while !eof(a) push!(ms, nextMap(a)) end;
            close(io); ms)

"Every element of `x` within `rtol` of `y`'s (a scalar or a vector)."
closeTo(x, y; rtol = 1e-10) = length(x) == length(y) && all(isapprox.(x, y; rtol = rtol))

# The general path rebuilds each district's random spanning tree, which changes the floating-point rounding (not
# the value) from one evaluation to the next, so results are compared to 1e-12.
sameResults(a::Dict, b::Dict) = keys(a) == keys(b) && all(closeTo(a[f], b[f]; rtol = 1e-12) for f in keys(a))
sameResults(a::Vector, b::Vector) = length(a) == length(b) && all(sameResults(x, y) for (x, y) in zip(a, b))

@testset "WriterSet / computeWriters" begin
    maps = ctmaps()
    stored = ["get_log_spanning_trees", "get_log_spanning_forests", "get_isoperimetric_scores"]

    @testset "reproduces the values CycleWalk stored in the atlas" begin
        ws = WriterSet(stored; CT_COLS...)
        @test writerFields(ws) == stored
        for m in maps
            got = computeWriters(ws, m)
            @test Set(keys(got)) == Set(stored)
            for f in stored
                @test closeTo(got[f], m.data[f])
            end
        end
        @test occursin("get_log_spanning_trees", sprint(show, ws)) && occursin("CT_pct20.json", sprint(show, ws))
    end

    @testset "the same values atlas add writes, partisan fields included" begin
        names = "get_log_spanning_trees,get_isoperimetric_scores,get_partisan_margins,get_partisan_seats"
        votes = "G20PREDEM,G20PREREP;G20PREREP,G20PREDEM"                  # the CT graph has one election
        ws = WriterSet(names; vote_cols = votes, CT_COLS...)
        @test writerFields(ws) == ["get_log_spanning_trees", "get_isoperimetric_scores",
                                   "get_partisan_margins_G20PREDEM_G20PREREP", "get_partisan_margins_G20PREREP_G20PREDEM",
                                   "get_partisan_seats_G20PREDEM_G20PREREP", "get_partisan_seats_G20PREREP_G20PREDEM"]
        out = joinpath(mktempdir(), "added.jsonl.gz")
        run_add(names, WCT_ATLAS, out; vote_cols = votes, overwrite = true, quiet = true, CT_COLS...)
        io = smartOpen(out, "r"); a = openAtlas(io); added = Map[]; while !eof(a) push!(added, nextMap(a)) end; close(io)
        results = computeWriters(ws, maps)
        @test length(results) == length(maps) == length(added)
        for (r, m) in zip(results, added), f in writerFields(ws)
            @test closeTo(r[f], m.data[f]; rtol = 1e-12)
        end
        # the two vote pairs are each other's complement
        r = results[1]
        @test closeTo(r["get_partisan_margins_G20PREDEM_G20PREREP"] .+ r["get_partisan_margins_G20PREREP_G20PREDEM"],
                      fill(100.0, length(r["get_partisan_margins_G20PREDEM_G20PREREP"])))
    end

    @testset "the fast and the general paths agree, and the vector form equals one map at a time" begin
        slow = first(n for n in listWriters() if !startswith(n, "get_partisan") &&
                     !hasFastMethod(getfield(CycleWalk, Symbol(n))))
        fast = WriterSet(["get_isoperimetric_scores"]; CT_COLS...)
        mixed = WriterSet(["get_isoperimetric_scores", slow]; CT_COLS...)    # one slow writer: the general path
        @test fast.treeless && !mixed.treeless
        for m in maps[1:10]
            @test closeTo(computeWriters(fast, m)["get_isoperimetric_scores"],
                          computeWriters(mixed, m)["get_isoperimetric_scores"]; rtol = 1e-12)
        end
        @test sameResults(computeWriters(mixed, maps; cores = 1), [computeWriters(mixed, m) for m in maps])
        @test sameResults(computeWriters(mixed, maps), computeWriters(mixed, maps; cores = 1))
        @test computeWriters(fast, maps) == [computeWriters(fast, m) for m in maps]     # the fast path: exactly
        @test computeWriters(mixed, Map[]) == Dict{String,Any}[]
    end

    @testset "a map's own district numbers: relabeling the map permutes the values" begin
        ws = WriterSet(["get_log_spanning_trees", "get_isoperimetric_scores"]; CT_COLS...)
        m = maps[3]
        d = maximum(values(m.districting))
        σ = [d; 1:(d - 1)]                                       # district k becomes σ[k]
        relabeled = Map(m.name, Districting(k => σ[v] for (k, v) in m.districting), m.weight, m.data)
        a, b = computeWriters(ws, m), computeWriters(ws, relabeled)
        for f in keys(a)
            @test closeTo(b[f][σ], a[f])
        end
    end

    @testset "listWriters and the errors" begin
        names = listWriters()
        @test issorted(names) && "get_log_spanning_trees" in names && "get_partisan_margins" in names
        @test_throws ErrorException WriterSet("no_such_writer_xyz"; CT_COLS...)
        @test_throws ErrorException WriterSet("get_partisan_margins"; CT_COLS...)   # no vote_cols
        err = try WriterSet("get_log_spanning_trees"; pop_col = "POP20", node_col = "NAME"); nothing catch e; e end
        @test err isa ErrorException && occursin("graph =", err.msg) && !occursin("atlas add", err.msg)
        @test_throws ErrorException WriterSet(String[]; CT_COLS...)
    end
end
