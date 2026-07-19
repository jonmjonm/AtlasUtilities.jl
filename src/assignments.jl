# assignments.jl -- the `atlas extract-assignments` subcommand.
#
# Read every map in atlas Atlas1 and write a single wide CSV: one row per map,
# first column the map name, remaining columns node1, node2, ... (the node
# ids found in the first map, sorted) holding that node's district number in
# the map. Every map must have exactly the first map's node set; multiscale
# atlases (whose node ids have more than one component, or whose node set
# varies map to map) are not supported yet and produce an error.
#
# Output is `<atlas-basename>-assignments.csv.gz` (gzip) by default, or
# `.csv` with `--no-compression`, next to the input atlas; skipped (with a
# message) if the target file already exists, unless `--force`.

"""
    run_extract_assignments(Atlas1; compress = true, force = false, quiet = false,
                            cores = Threads.nthreads())

Write `<Atlas1 basename>-assignments.csv[.gz]`: one row per map (map name, then
each node's district number in that map), columns being the sorted node ids
found in `Atlas1`'s first map. Errors if any map's node set doesn't exactly match
the first map's, including multiscale atlases (whose node ids have more than
one component).
"""
function run_extract_assignments(Atlas1::AbstractString;
                                 compress::Bool = true, force::Bool = false,
                                 quiet::Bool = false, cores::Int = Threads.nthreads())
    ext = compress ? ".csv.gz" : ".csv"
    outpath = stripAtlasExt(String(Atlas1)) * "-assignments" * ext

    if isfile(outpath) && !force
        println("atlas extract-assignments: $outpath already exists; ",
                "pass --force to overwrite.")
        return nothing
    end

    atlas = openAtlas(smartOpen(String(Atlas1), "r"))
    mpt, wt = atlas.mapParamType, atlas.weightType
    if eof(atlas)
        close(atlas)
        println("atlas extract-assignments: $Atlas1 has no maps; nothing written.")
        return nothing
    end

    first = nextMap(atlas)
    nodes = sort!(collect(keys(first.districting)); by = nodeIdString)
    any(n -> length(n) > 1, nodes) &&
        error("atlas extract-assignments: multiscale atlases (node ids with " *
              "more than one component) are not supported yet.")
    nodeSet = Set(nodes)
    nodeNames = [nodeIdString(n) for n in nodes]

    checkNodes(m) = Set(keys(m.districting)) == nodeSet ||
        error("atlas extract-assignments: map \"$(m.name)\" does not have " *
              "the same node set as the first map (multiscale atlases, whose " *
              "node set can vary map to map, are not supported yet).")
    rowFor(m) = csvcell(m.name) * "," *
                join((string(m.districting[n]) for n in nodes), ",") * "\n"

    # Write to a temp file and rename into place only on success, so a mismatched
    # node set found partway through (e.g. a multiscale atlas) never leaves a
    # partial/corrupt output file behind.
    tmppath = stripAtlasExt(String(Atlas1)) * "-assignments.tmp" * ext
    written = 1
    try
        io = smartOpen(tmppath, "w")
        write(io, "name," * join((csvcell(n) for n in nodeNames), ",") * "\n")
        write(io, rowFor(first))

        progress = quiet ? nothing :
                   ProgressUnknown(desc = "Extracting district assignments:", spinner = true)
        while !eof(atlas)
            lines = String[]
            while length(lines) < BATCH && !eof(atlas)
                push!(lines, readline(atlas.io))
            end
            n = length(lines)
            n == 0 && break

            rows = Vector{String}(undef, n)
            parallelDo!(n, cores) do i
                m = JSON3.read(lines[i], Map{mpt,wt})
                checkNodes(m)
                rows[i] = rowFor(m)
            end

            for i in 1:n
                write(io, rows[i])
            end
            written += n
            progress === nothing ||
                next!(progress; showvalues = [("maps written", written)])
        end
        progress === nothing ||
            finish!(progress; showvalues = [("maps written", written)])
        close(io)
        mv(tmppath, outpath; force = true)
    catch
        rm(tmppath; force = true)
        rethrow()
    finally
        close(atlas)
    end

    quiet || println("Wrote ", written, " map(s) to ", outpath)
    return nothing
end
