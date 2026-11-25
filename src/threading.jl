# threading.jl -- small parallelism helpers. Reading an atlas's maps in parallel is AtlasIO's `eachMap(f, ...)`
# (run with `ntasks = cores`); `parallelDo!` is for the rest (`relabel`, `computeWriters` on maps in memory).

# Maps processed per batch, where a command still batches: the maps it writes with `writeMaps!` (parallel gzip),
# the values it adds to histograms at once, and `relabel`. Large enough to amortize the per-batch work, small
# enough to bound memory.
const BATCH = 512

# Errors meant for the user, from a function run on each map in AtlasIO's `eachMap(f, ...)`. `eachMap` raises an
# error from `f` after an `@error` log with the backtrace, which helps with an unexpected failure (a writer bug)
# but is noise for a message meant for the user. So `captureErrors(f)` returns the error as a value, and the loop
# raises it with `raiseCaptured`, as itself.
struct CapturedError
    exception::Any
end

"`f`, returning a `CapturedError` instead of throwing."
captureErrors(f) = function (m)
    try
        return f(m)
    catch e
        return CapturedError(e)
    end
end

"Raise the error `r` holds, if `r` is a `CapturedError`."
raiseCaptured(r) = r isa CapturedError ? throw(r.exception) : nothing

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
preallocated, per-index storage by `f`). If `f` throws, the error is rethrown as itself
(not wrapped in Julia's `CompositeException`/`TaskFailedException`), so the user sees
its message."""
function parallelDo!(f, n::Int, cores::Int)
    try
        @sync for r in chunkranges(n, cores)
            Threads.@spawn for i in r
                f(i)
            end
        end
    catch e
        throw(firstTaskError(e))
    end
    return nothing
end

"The exception the first failed task raised (or `e` itself, if it is not a task failure)."
function firstTaskError(e)
    while true
        if e isa CompositeException && !isempty(e.exceptions)
            e = first(e.exceptions)
        elseif e isa TaskFailedException
            e = e.task.exception
        else
            return e
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
