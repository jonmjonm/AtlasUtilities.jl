# pargzip.jl -- byte-targeted parallel gzip output, shared by the atlas-writing
# subcommands (`add`, `relabel`).
#
# Serial gzip compression of the output atlas is the dominant non-parallel cost of
# `atlas add`/`relabel`: profiling shows deflate() is the single largest frame, run
# single-threaded in the write loop, which caps thread scaling (~35% serial, plateau
# ~3x). The gzip format is a series of independent "members" that concatenate into
# one valid `.gz` (RFC 1952) -- read transparently by `gunzip` and by
# AtlasIO/CodecZlib -- so the output can be compressed in PARALLEL: group consecutive
# serialized maps until their combined size reaches a byte target, gzip each group
# into one member across worker tasks, and write the member bytes serially in order
# (raw I/O, no compression on the serial path).
#
# Grouping by BYTES (not map count) keeps every member comfortably above deflate's
# 32 KB history window, so the multi-member ratio penalty stays within ~0.1% of a
# single stream for any atlas -- large-map (NC, ~66 KB/map) or small-map (CT,
# ~33 KB/map). Below the window the penalty grows (a lone ~33 KB CT member costs
# ~+18% size), which is exactly why the target is fixed in bytes: a small-map atlas
# just packs more maps per member to clear the window.
#
# Only `.gz` output uses this path. Plain (`.jsonl`) output needs no compression and
# is written directly; `.bz2` falls back to the serial stream (`smartOpen`).

using CodecZlib: GzipCompressor

# Target uncompressed bytes per gzip member. 256 KB is 8x deflate's 32 KB window (so
# the multi-member ratio penalty is negligible) yet small enough to yield many
# members per run for load-balanced parallel compression.
const GZIP_MEMBER_TARGET = 1 << 18

"""Compress `bytes` into a single standalone gzip member (concatenable into a
multi-member `.gz`)."""
gzipMember(bytes::Vector{UInt8}) = transcode(GzipCompressor, bytes)

"""True if writing `path` should produce gzip output (drives the parallel-member
path). `.bz2` is intentionally excluded -- it falls back to the serial stream."""
isGzipOutput(path::AbstractString) = endswith(path, ".gz")

"""
    groupByBytes(sizes, target) -> Vector{UnitRange{Int}}

Partition `1:length(sizes)` into consecutive ranges whose summed `sizes` each reach
at least `target` bytes (the final range may be smaller). Each range becomes one
gzip member, so grouping by bytes keeps members above deflate's history window.
"""
function groupByBytes(sizes::Vector{Int}, target::Int)
    ranges = UnitRange{Int}[]
    n = length(sizes)
    i = 1
    while i <= n
        acc = 0
        j = i
        while j <= n && acc < target
            acc += sizes[j]
            j += 1
        end
        push!(ranges, i:(j - 1))
        i = j
    end
    return ranges
end

"""
    writeGzipMembers!(out, bytes, cores; target = GZIP_MEMBER_TARGET)

Write the in-order serialized records `bytes` to `out` as byte-targeted gzip members:
group consecutive records into ~`target`-byte groups (`groupByBytes`), gzip each
group into one member in parallel across `cores` tasks, then write the members to
`out` serially in record order (raw bytes -- the only serial work is I/O). The
concatenated members form one valid `.gz`. Returns nothing.
"""
function writeGzipMembers!(out::IO, bytes::Vector{Vector{UInt8}}, cores::Int;
                           target::Int = GZIP_MEMBER_TARGET)
    isempty(bytes) && return nothing
    sizes = Int[length(b) for b in bytes]
    ranges = groupByBytes(sizes, target)
    members = Vector{Vector{UInt8}}(undef, length(ranges))
    parallelDo!(length(ranges), cores) do gi
        r = ranges[gi]
        buf = Vector{UInt8}(undef, sum(@view sizes[r]))
        off = 0
        for i in r
            b = bytes[i]
            copyto!(buf, off + 1, b, 1, length(b))
            off += length(b)
        end
        members[gi] = gzipMember(buf)
    end
    for gi in eachindex(members)
        write(out, members[gi])
    end
    return nothing
end

"""
    AtlasOutput

Output sink for an atlas's serialized map bytes that hides how the target is
written. For a `.gz` path it emits byte-targeted gzip members compressed in parallel
(`writeGzipMembers!`); for any other path it writes through a `smartOpen` stream
(plain, or serial `.bz2`). Build with [`openAtlasOutput`](@ref); feed batches of
in-order serialized maps with [`writeMaps!`](@ref); `close` it when done.
"""
struct AtlasOutput
    io::IO
    gzip::Bool
    cores::Int
end

"""
    openAtlasOutput(path, headerBytes, cores) -> AtlasOutput

Open `path` for writing and emit the atlas `headerBytes` (its three header lines).
For `.gz` output the header is written as its own gzip member and the file is opened
raw so subsequent map members can be appended; otherwise the header is written
through a `smartOpen` stream (plain or `.bz2`). `cores` is the parallel-compression
worker count for the map body.
"""
function openAtlasOutput(path::AbstractString, headerBytes::Vector{UInt8}, cores::Int)
    if isGzipOutput(path)
        io = open(String(path), "w")
        write(io, gzipMember(headerBytes))
        return AtlasOutput(io, true, cores)
    else
        io = smartOpen(String(path), "w")   # plain IOStream or serial .bz2 stream
        write(io, headerBytes)
        return AtlasOutput(io, false, cores)
    end
end

"""
    writeMaps!(out::AtlasOutput, bytes)

Append the in-order serialized map byte-vectors `bytes` to `out`: as byte-targeted
parallel gzip members for a `.gz` target, or written straight through the stream
otherwise.
"""
function writeMaps!(out::AtlasOutput, bytes::Vector{Vector{UInt8}})
    if out.gzip
        writeGzipMembers!(out.io, bytes, out.cores)
    else
        for b in bytes
            write(out.io, b)
        end
    end
    return nothing
end

Base.close(out::AtlasOutput) = close(out.io)

"""Read an atlas's three header lines from `path` as raw bytes (with trailing
newlines), for re-emitting through an [`AtlasOutput`](@ref)."""
function atlasHeaderBytes(path::AbstractString)
    src = smartOpen(String(path), "r")
    buf = IOBuffer()
    for _ in 1:3
        write(buf, readline(src), "\n")
    end
    close(src)
    return take!(buf)
end
