# threading.jl -- small batched-parallelism helpers shared by the map-processing
# subcommands (`relabel`, `add`, `extract-map-data`).
#
# The common pattern is: read a batch of map lines serially, do the per-map work
# (parse / reconstruct / evaluate / serialize) in parallel across `cores` tasks
# into preallocated per-index storage, then consume the results serially in map
# order. `cores` defaults to the threads Julia was started with, so `cores == 1`
# is a clean serial fallback and the same code path serves both.

# Maps processed per batch. Large enough to amortize task overhead, small enough
# to bound memory (a batch of parsed maps -- or reconstructed partitions -- is
# held at once).
const BATCH = 512

<<<<<<< HEAD
"""Read up to `BATCH` lines from `io` (fewer if `eof(io)` is reached first)."""
function readBatch(io)
    lines = String[]
    while length(lines) < BATCH && !eof(io)
=======
"""Read up to `cap` lines from `io` (fewer if `eof(io)` is reached first). `cap`
defaults to `BATCH`; pass a smaller value to stop short of a full batch (e.g. a
`--max-maps` limit close to being reached)."""
function readBatch(io, cap::Int = BATCH)
    lines = String[]
    while length(lines) < cap && !eof(io)
>>>>>>> e34b6c4a06a8daff341a75d53858faa4b49d1283
        push!(lines, readline(io))
    end
    return lines
end

"""Split `1:n` into at most `k` contiguous ranges (one per task)."""
function chunkranges(n::Int, k::Int)
    k = clamp(k, 1, max(n, 1))
    base, extra = divrem(n, k)
    ranges = UnitRange{Int}[]
    start = 1
    for c in 1:k
        len = base + (c <= extra ? 1 : 0)
        len == 0 && continue
        push!(ranges, start:(start + len - 1))
        start += len
    end
    return ranges
end

"""Run `f(i)` for `i in 1:n` across `cores` tasks (results must be written to
preallocated, per-index storage by `f`)."""
function parallelDo!(f, n::Int, cores::Int)
    @sync for r in chunkranges(n, cores)
        Threads.@spawn for i in r
            f(i)
        end
    end
end

"""
    with_serial_blas(f)

Run `f()` with BLAS restricted to a single thread, restoring the previous setting
afterward. Used around the parallel region so Julia's task threads don't
oversubscribe against BLAS's own threads (the writer functions do dense linear
algebra, e.g. the Laplacian log-determinant in `get_log_spanning_trees`).
"""
function with_serial_blas(f)
    prev = BLAS.get_num_threads()
    BLAS.set_num_threads(1)
    try
        return f()
    finally
        BLAS.set_num_threads(prev)
    end
end
