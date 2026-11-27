# The public API: what is exported, what is `public` but not exported, and that every one of them is documented.
using Test
using AtlasUtilities

@testset "public API" begin
    exported = [:atlasInfo, :listMapData, :listNodes, :extractScripts,
                :findRelabeling, :relabelMap, :relabelAtlas, :confusionMatrix, :permutationFromConfusion,
                :hammingDistance, :Hierarchy, :loadHierarchy, :loadPopulation,
                :mapDataHistograms, :writeHistograms, :summarizeMapData, :assignmentMatrix, :extractMapData,
                :extractAssignments,
                :addMapData, :WriterSet, :computeWriters, :writerFields, :listWriters]
    public_only = [:nodeIdString, :atlasHeaderInfo, :listWriterDetails, :loadGraph]

    @test sort(filter(n -> Base.isexported(AtlasUtilities, n) && n != :AtlasUtilities,
                      names(AtlasUtilities))) == sort(exported)
    for n in public_only
        @test Base.ispublic(AtlasUtilities, n) && !Base.isexported(AtlasUtilities, n)
    end
    for n in [exported; public_only]
        @test Base.Docs.hasdoc(AtlasUtilities, n)
    end
end
