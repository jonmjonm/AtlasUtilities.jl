# `mapatlas add`: its string arguments and its command line.
using AtlasCLI: parseFunctionNames, parseVotePairs, parseNodeData, add

@testset "mapatlas add" begin

    @testset "parseFunctionNames" begin
        @test parseFunctionNames("get_log_spanning_trees") == ["get_log_spanning_trees"]
        @test parseFunctionNames("a,b,c") == ["a", "b", "c"]
        @test parseFunctionNames("[a, b]") == ["a", "b"]           # bracketed list
        @test parseFunctionNames("[\"a\", \"b\"]") == ["a", "b"]   # quoted, bracketed
        @test parseFunctionNames("  a , b ,") == ["a", "b"]        # trailing comma / spaces
        @test_throws ErrorException parseFunctionNames("")
        @test_throws ErrorException parseFunctionNames("[]")
    end

    @testset "mapatlas add --list-writers prints plain + partisan writers" begin
        out = capture_stdout() do
            cli_list_writers()
        end
        @test occursin("get_log_spanning_trees", out)
        @test occursin("get_partisan_margins", out)
        @test occursin("get_partisan_seats", out)
        @test occursin("--vote-cols", out)
    end

    @testset "mapatlas add --list-writers: short-circuits without functions/atlas1/atlas2" begin
        out = capture_stdout() do
            add(; list_writers = true)
        end
        @test occursin("get_log_spanning_trees", out)
    end

    @testset "mapatlas add: missing functions/atlas1/atlas2 errors clearly (without --list-writers)" begin
        @test_throws ErrorException add()
    end

    @testset "parseNodeData" begin
        @test parseNodeData("") == String[]
        @test parseNodeData("COUNTY, NAME") == ["COUNTY", "NAME"]
    end

    @testset "parseVotePairs" begin
        @test parseVotePairs("") == Tuple{String,String}[]
        @test parseVotePairs("A,B") == [("A", "B")]
        @test parseVotePairs("A,B;C,D") == [("A", "B"), ("C", "D")]
        @test parseVotePairs(" A , B ; C , D ") == [("A", "B"), ("C", "D")]  # spaces trimmed
        @test parseVotePairs("A,B;") == [("A", "B")]                         # trailing ; ignored
        @test_throws ErrorException parseVotePairs("A")                      # not a pair
        @test_throws ErrorException parseVotePairs("A,B,C")                  # too many cols
    end

end
