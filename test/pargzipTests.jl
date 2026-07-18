# Tests for the byte-targeted parallel-gzip atlas output (src/pargzip.jl) and its
# use by `run_add` / `run_reorder`. The key invariants: a `.gz` output is a valid
# multi-member gzip that (a) the system `gunzip` accepts, (b) AtlasIO reads back with
# the same maps as an uncompressed run, and (c) round-trips gzipMember; and grouping
# is by bytes so members clear deflate's history window.

using Test
using AtlasIO
using CodecZlib: GzipDecompressor, transcode
using AtlasUtilities: run_add, run_reorder, groupByBytes, gzipMember,
                     writeGzipMembers!, isGzipOutput, GZIP_MEMBER_TARGET

@testset "pargzip" begin

    readmaps(p) = (a = openAtlas(smartOpen(p, "r")); ms = Map[];
                   while !eof(a); push!(ms, nextMap(a)); end; close(a); ms)
    asvec(x) = x isa AbstractVector ? Float64.(x) : [Float64(x)]
    gzipMagic(bytes, i) = bytes[i] == 0x1f && bytes[i+1] == 0x8b && bytes[i+2] == 0x08
    countMembers(path) = (b = read(path); sum(i -> gzipMagic(b, i), 1:(length(b)-2)))

    @testset "isGzipOutput" begin
        @test isGzipOutput("a.jsonl.gz")
        @test !isGzipOutput("a.jsonl")
        @test !isGzipOutput("a.jsonl.bz2")   # .bz2 falls back to the serial stream
    end

    @testset "groupByBytes" begin
        # exact-fit groups
        @test groupByBytes([4, 4, 4, 4], 8) == [1:2, 3:4]
        # a group closes as soon as it reaches target (>= target), last may be short
        @test groupByBytes([3, 3, 3, 3, 3], 8) == [1:3, 4:5]
        # a single oversized record is its own group
        @test groupByBytes([100, 1, 1], 8) == [1:1, 2:3]
        # target larger than everything -> one group
        @test groupByBytes([1, 1, 1], 100) == [1:3]
        @test groupByBytes(Int[], 8) == UnitRange{Int}[]
        # every record covers a distinct index exactly once, in order
        for sizes in ([5, 1, 9, 2, 7, 3], fill(1, 37))
            rs = groupByBytes(sizes, 8)
            @test reduce(vcat, collect.(rs)) == collect(1:length(sizes))
        end
    end

    @testset "gzipMember round-trip + concatenation" begin
        a = Vector{UInt8}("hello world\n" ^ 100)
        b = Vector{UInt8}("second chunk\n" ^ 100)
        @test transcode(GzipDecompressor, gzipMember(a)) == a
        # concatenated members decode to the concatenation (multi-member gzip)
        @test transcode(GzipDecompressor, vcat(gzipMember(a), gzipMember(b))) == vcat(a, b)
    end

    @testset "writeGzipMembers! -> valid multi-member gzip in order" begin
        recs = [Vector{UInt8}("record $i line\n") for i in 1:50]
        io = IOBuffer()
        # tiny target so most records become their own member (exercises many members)
        writeGzipMembers!(io, recs, 1; target = 8)
        gz = take!(io)
        @test transcode(GzipDecompressor, gz) == reduce(vcat, recs)   # order preserved
        @test count(i -> gz[i] == 0x1f && gz[i+1] == 0x8b, 1:(length(gz)-1)) >= 2
    end

    # --- end-to-end: run_add .gz vs plain .jsonl produce the same atlas ----------
    graph = joinpath(@__DIR__, "..", "Data", "CT_pct20.json")
    oracle = joinpath(@__DIR__, "..", "examples", "cycleWalk_ct_slice.jsonl.gz")
    addkw = (graph = graph, pop_col = "POP20", node_col = "NAME", area_col = "area",
             border_col = "border_length", edge_perimeter_col = "length",
             node_data = "COUNTY,NAME,POP20,area,border_length",
             overwrite = true, quiet = true)

    @testset "run_add: .gz output == plain output" begin
        dir = mktempdir()
        A2gz = joinpath(dir, "out.jsonl.gz")
        A2plain = joinpath(dir, "out.jsonl")
        run_add("get_log_spanning_trees", oracle, A2gz; addkw...)
        run_add("get_log_spanning_trees", oracle, A2plain; addkw...)

        # the .gz is a valid gzip the system tool accepts, and is multi-member
        # (header member + >=1 body member)
        @test success(`gzip -t $A2gz`)
        @test countMembers(A2gz) >= 2

        gz, pl = readmaps(A2gz), readmaps(A2plain)
        @test length(gz) == length(pl) >= 40
        for (mg, mp) in zip(gz, pl)
            @test mg.name == mp.name
            @test asvec(mg.data["get_log_spanning_trees"]) == asvec(mp.data["get_log_spanning_trees"])
        end
    end

    # --- end-to-end: run_reorder .gz vs plain on a small-map atlas ---------------
    @testset "run_reorder: .gz output == plain output" begin
        demo = joinpath(@__DIR__, "..", "examples", "demo_grid_4x4.jsonl.gz")
        dir = mktempdir()
        A2gz = joinpath(dir, "rel.jsonl.gz")
        A2plain = joinpath(dir, "rel.jsonl")
        run_reorder(demo, A2gz; quiet = true)
        run_reorder(demo, A2plain; quiet = true)

        @test success(`gzip -t $A2gz`)
        @test countMembers(A2gz) >= 2          # header member + anchor/body members

        gz, pl = readmaps(A2gz), readmaps(A2plain)
        @test length(gz) == length(pl) >= 4
        for (mg, mp) in zip(gz, pl)
            @test mg.name == mp.name
            @test mg.districting == mp.districting   # identical relabeling
        end
    end

end
