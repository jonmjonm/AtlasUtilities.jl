"""
    AtlasUtilities

A library for redistricting Atlas files (see the Atlas format at
https://github.com/jonmjonm/AtlasIO.jl/blob/main/atlas_format.md): reading and summarizing them, relabeling
districts, histograms, extraction and district assignments. `using CycleWalk` switches on an extension that
adds the CycleWalk writer statistics (`addMapData`, `WriterSet`, `computeWriters`). The `mapatlas` command,
in the AtlasCLI package of the same repository, is built on this library.
"""
module AtlasUtilities

using AtlasIO
using Dates
using Hungarian
import JSON     # all JSON reading and writing (graphs, node lists, histograms, the atlas params line)
using LinearAlgebra: BLAS
using ProgressMeter
using StreamHistogram

# Byte-targeted parallel gzip atlas output (`AtlasOutput`/`openAtlasOutput`/
# `writeMaps!`/`atlasHeaderBytes`) is provided by AtlasIO (>= 0.1.3) and used below.
include("json.jl")
include("threading.jl")
include("info.jl")
include("nodes.jl")
include("relabel.jl")
include("writers.jl")       # CycleWalk writers: declared here, defined in ext/AtlasUtilitiesCycleWalkExt
include("extract.jl")
include("extractHistogram.jl")
include("summarize.jl")
include("assignments.jl")

# Reading
export atlasInfo, listMapData, listNodes, extractScripts
# Relabeling
export findRelabeling, relabelMap, relabelAtlas, confusionMatrix, permutationFromConfusion, hammingDistance,
       Hierarchy, loadHierarchy, loadPopulation
# Analysis
export mapDataHistograms, writeHistograms, summarizeMapData, assignmentMatrix, extractMapData, extractAssignments
# Process (CycleWalk writers)
export addMapData, WriterSet, computeWriters, writerFields, listWriters
# Public but not exported (marked `public` once [compat] requires Julia 1.11): nodeIdString, atlasHeaderInfo,
# listWriterDetails, loadGraph.

function __init__()
    # Calling a CycleWalk function (`addMapData`, `WriterSet(...)`, ...) without CycleWalk says to load it.
    Base.Experimental.register_error_hint(cycleWalkHint, MethodError)
end

end # module
