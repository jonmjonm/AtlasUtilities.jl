"""
    AtlasUtilitiesCycleWalkExt

The CycleWalk part of AtlasUtilities, loaded when CycleWalk is (`using AtlasUtilities, CycleWalk`): building a
`WriterSet` (the CycleWalk dual graph and writer functions), `computeWriters`, `addMapData`, `listWriters`,
`listWriterDetails`, `loadGraph`, and the hook `writerSubset` that lets `extractMapData` compute only the writer
fields it writes. AtlasUtilities declares and documents these functions; without
CycleWalk, calling one says to load it.
"""
module AtlasUtilitiesCycleWalkExt

using AtlasUtilities
using AtlasUtilities: OptString, isgiven, writerFields, coverLabel, CapturedError, raiseCaptured,
                      with_serial_blas, parallelDo!, BATCH
import AtlasUtilities: WriterSet, computeWriters, writerSubset, addMapData, listWriters, listWriterDetails,
                       loadGraph
using AtlasIO
using CycleWalk
using CycleWalk: Graph, MultiLevelPartition, LinkCutPartition, BaseGraph
using Dates
import JSON
using ProgressMeter
using TOML

include("writers.jl")

end # module
