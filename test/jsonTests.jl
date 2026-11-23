# JSON helpers (src/json.jl): AtlasUtilities reads and writes JSON with JSON.jl only.
using AtlasUtilities: readJSONFile, jsonKeyString

@testset "json helpers" begin
    @testset "jsonKeyString keeps the key spelling AtlasUtilities used with JSON3" begin
        @test jsonKeyString("052") == "052"
        @test jsonKeyString(12) == "12"
        @test jsonKeyString(5.0) == "5"          # JSON3 read 5.0 as the integer 5
        @test jsonKeyString(-0.0) == "0"
        @test jsonKeyString(1e3) == "1000"
        @test jsonKeyString(2.5) == "2.5"
        @test jsonKeyString(1e30) == "1.0e30"    # beyond Int: left as a float
        @test jsonKeyString(true) == "true"
    end

    @testset "readJSONFile: plain and gzip, String keys, exact numbers" begin
        dir = mktempdir()
        text = """{"nodes":[{"id":0,"name":"A","pop":5.0,"big":12345678901234567890}],"adjacency":[[]]}"""
        for name in ("g.json", "g.json.gz")
            io = smartOpen(joinpath(dir, name), "w"); write(io, text); close(io)
            g = readJSONFile(joinpath(dir, name))
            @test g isa Dict{String,Any} && g["nodes"][1] isa Dict{String,Any}
            n = g["nodes"][1]
            @test n["pop"] === 5.0 && n["id"] === 0 && n["big"] == 12345678901234567890
        end
    end

    @testset "graph keys from whole-number float attributes" begin
        dir = mktempdir()
        path = joinpath(dir, "floatkeys.json")
        write(path, """{"nodes":[{"id":0,"county":"A","prec":1.0,"pop":10.0},
                                 {"id":1,"county":"A","prec":2.0,"pop":20}],"adjacency":[[],[]]}""")
        h = loadHierarchy(path, ["county", "prec"])
        @test h.finest == [("A", "1"), ("A", "2")]
        @test loadPopulation(path, ["county", "prec"], "pop") == Dict(("A", "1") => 10, ("A", "2") => 20)
    end
end
