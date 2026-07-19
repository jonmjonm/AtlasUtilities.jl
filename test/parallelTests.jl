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
using AtlasUtilities: run_add, run_extract

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
    funcs = "get_log_spanning_trees,get_isoperimetric_scores"

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

    @testset "add: cores=1 vs cores=4" begin
        d = mktempdir()
        atlas1 = joinpath(d, "s1.jsonl.gz"); a4 = joinpath(d, "s4.jsonl.gz")
        run_add(funcs, src, atlas1; gargs..., overwrite = true, quiet = true, cores = 1)
        run_add(funcs, src, a4; gargs..., overwrite = true, quiet = true, cores = 4)

        m1, m4 = readmaps(atlas1), readmaps(a4)
        @test length(m1) == length(m4)
        @test [m.name for m in m1] == [m.name for m in m4]       # order preserved (exact)
        for (x, y) in zip(m1, m4)
            @test x.districting == y.districting                  # exact (integer labels)
            @test Set(keys(x.data)) == Set(keys(y.data))
            for k in keys(x.data)
                @test approxvals(asvec(x.data[k]), asvec(y.data[k]))
            end
        end
    end

    @testset "extract: cores=1 vs cores=4" begin
        d1 = mktempdir(); d4 = mktempdir()
        s1 = joinpath(d1, "run.jsonl.gz"); cp(src, s1)
        s4 = joinpath(d4, "run.jsonl.gz"); cp(src, s4)
        run_extract(s1; add = "get_isoperimetric_scores", gargs...,
                    force = true, quiet = true, cores = 1)
        run_extract(s4; add = "get_isoperimetric_scores", gargs...,
                    force = true, quiet = true, cores = 4)

        for f in ("get_log_spanning_trees", "get_log_spanning_forests",
                  "get_isoperimetric_scores")
            n1, v1 = readcsv(joinpath(d1, "run", f * ".csv.gz"))
            n4, v4 = readcsv(joinpath(d4, "run", f * ".csv.gz"))
            @test n1 == n4                                        # same maps, same order
            @test length(v1) == length(v4)
            for (r1, r4) in zip(v1, v4)
                @test approxvals(r1, r4)
            end
        end
    end
end
