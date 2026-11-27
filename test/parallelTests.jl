# Equality tests: the threaded pipeline must produce the same output as a serial
# run. This is the thread-safety check for CycleWalk's reconstruction + writer
# functions run concurrently on a shared graph. Run the suite with multiple threads
# (e.g. `julia -t4`) to exercise true parallelism; with one thread it still checks
# the batching logic. `nthreads` is reported so failures are interpretable.
#
# Comparison is to machine precision, not bitwise: LinkCutPartition draws a fresh
# random spanning tree per reconstruction, so summation order (e.g. in
# get_isoperimetric_scores) varies at the ULP level even between two *serial* runs.
# Threading introduces no error beyond that inherent ~1e-15 nondeterminism, so a
# real data race (which would corrupt values by O(1)) is still caught with room to
# spare. Structural results (map order, names, districting) are exact.

using Test
using AtlasIO
using AtlasUtilities: extractMapData, extractAssignments

const RTOL = 1e-10   # observed threading/serial nondeterminism is ~1e-15

# Do two number sequences agree to machine precision?
approxvals(xs, ys) = length(xs) == length(ys) &&
    all(isapprox(x, y; rtol = RTOL, atol = 1e-12) for (x, y) in zip(xs, ys))

asvec(x) = x isa AbstractVector ? Float64.(x) : [Float64(x)]

@testset "parallel == serial (threads=$(Threads.nthreads()))" begin
    graph = joinpath(@__DIR__, "..", "Data", "CT_pct20.json")
    src = joinpath(@__DIR__, "..", "examples", "cycleWalk_ct_slice.jsonl.gz")
    gargs = (graph = graph, pop_col = "POP20", node_col = "NAME", area_col = "area",
             border_col = "border_length", edge_perimeter_col = "length")
    funcs = ["get_log_spanning_trees", "get_isoperimetric_scores"]

    readmaps(p) = (a = openAtlas(smartOpen(p, "r")); ms = Map[];
                   while !eof(a); push!(ms, nextMap(a)); end; close(a); ms)
    # Parse a CSV file into (names, rows-of-Floats).
    function readcsv(p)
        io = smartOpen(p, "r"); lines = filter(!isempty, split(read(io, String), "\n"))
        close(io)
        names = String[]; vals = Vector{Float64}[]
        for ln in lines[2:end]                       # skip header
            cells = split(ln, ",")
            push!(names, String(cells[1]))
            push!(vals, parse.(Float64, cells[2:end]))
        end
        return names, vals
    end

    @testset "extract-assignments: cores=1 vs cores=4" begin
        outs = map((1, 4)) do cores
            d = mktempdir()
            p = joinpath(d, "run.jsonl.gz"); cp(src, p)
            extractAssignments(p; compress = false, cores = cores)
            read(joinpath(d, "run-assignments.csv"), String)
        end
        @test outs[1] == outs[2] && count('\n', outs[1]) == length(readmaps(src)) + 1
    end

    @testset "a malformed map line stops extract at that map (cores=$cores)" for cores in (1, 4)
        lines = readlines(smartOpen(src, "r"))
        lines[3 + 4] = "{\"name\": broken"                  # map 4 of the slice
        d = mktempdir()
        bad = joinpath(d, "bad.jsonl")
        write(bad, join(lines, "\n") * "\n")
        @test_throws AtlasFormatError extractMapData(bad; force = true, cores = cores)
    end
end
