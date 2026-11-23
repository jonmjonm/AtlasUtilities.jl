# JSON helpers shared by the subcommands (and the render extension). AtlasUtilities uses JSON.jl only.

"""
    readJSONFile(path) -> Dict{String,Any}

Parse the JSON file at `path` (plain or compressed; see `smartOpen`). Objects become `Dict{String,Any}` and
arrays `Vector{Any}`, at every level, and numbers keep their type exactly (`5.0` stays a `Float64`).
"""
function readJSONFile(path::AbstractString)
    io = smartOpen(String(path), "r")
    try
        return JSON.parse(read(io, String); dicttype = Dict{String,Any})
    finally
        close(io)
    end
end

"""
    jsonKeyString(v) -> String

A graph attribute value as the string used to match atlas node keys. A whole-number float is written
without its fraction (`5.0` -> `"5"`, `-0.0` -> `"0"`), as AtlasUtilities did when it read graphs with
JSON3, which turned such numbers into integers; anything else is `string(v)`.
"""
jsonKeyString(v::AbstractFloat) =
    isinteger(v) && typemin(Int) <= v <= typemax(Int) ? string(Int(v)) : string(v)
jsonKeyString(v) = string(v)
