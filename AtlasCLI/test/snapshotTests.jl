# Snapshot tests: every `mapatlas` subcommand, run on the example atlases in format v1 and v2, against the
# snapshots in snapshots/. Each case is one or more commands run in a directory of its own. What it printed (stdout
# and log messages) is kept in full in snapshots/printed/<case>.txt (in fingerprints.txt instead, when longer than
# PRINTED_MAX) and compared with its numbers to within RTOL. Every file it wrote is kept as a fingerprint in
# snapshots/fingerprints.txt: the SHA-256 of its content (decompressed and normalized, see `normalize`) with each
# floating-point number replaced by `#`, and the count and three sums of those numbers, compared to within
# SUM_RTOL. Floats are compared to a tolerance because their last digits can differ between Julia versions (a sum
# done in another order) and, for a writer evaluated on a random spanning tree, between runs.
#
# After an intended change to what a command prints or writes, rewrite the snapshots and review their diff:
#
#     UPDATE_SNAPSHOTS=1 julia --project=AtlasCLI -e 'using Pkg; Pkg.test()'
using AtlasCLI: command_main
using AtlasIO, Logging, SHA
import JSON

const SNAPSHOTS = joinpath(@__DIR__, "snapshots")
const REPO = normpath(joinpath(@__DIR__, "..", ".."))
const EXAMPLES = joinpath(REPO, "examples")
const PRINTED_MAX = 16_384      # bytes of printed text kept in full
const RTOL = 1e-12              # numbers in printed text
const SUM_RTOL = 1e-9           # the sums of a file's floats

# What may differ between two runs of the same code: the date of a run (`about.md`, the "added map data" entry),
# the AtlasUtilities version in that entry, and a log message's source line. Colors are removed.
const MASKS = [r"(\*\*Extraction date:\*\* )\S+" => s"\1<date>",
               r"(\"date\": ?)\"\d{4}-\d\d-\d\dT[\d:.]+\"" => s"\1\"<date>\"",
               r"(\"version\": ?)\"\d+\.\d+\.\d+[^\"]*\"" => s"\1\"<version>\"",
               r"(└ @ \S+) .*" => s"\1 <source>",
               r"\e\[[0-9;]*m" => ""]

"""The content of the file at `path` as text, decompressed (`.gz`/`.bz2`), with `MASKS` applied. In an atlas
(`.jsonl[.gz|.bz2]`) each JSON line is written canonically (see `canonical`): a map's district assignment is a
`Dict`, written in its iteration order, which differs between Julia versions."""
function normalize(path)
    io = smartOpen(path, "r")
    text = String(read(io))
    close(io)
    if occursin(r"\.jsonl(\.gz|\.bz2)?$", path)
        text = join((startswith(l, '{') ? canonical(JSON.parse(l)) : l for l in split(text, '\n')), '\n')
    end
    return normalizeText(text)
end

"""The JSON value `x` written canonically: object keys sorted, and a format-v1 `"districting"` (a list of
one-entry objects, so a mapping) sorted. Every other list keeps its order, which means something."""
function canonical(x, key = "")
    x isa AbstractDict &&
        return "{" * join((JSON.json(k) * ":" * canonical(x[k], k) for k in sort!(collect(keys(x)))), ",") * "}"
    if x isa AbstractVector
        items = [canonical(v) for v in x]
        key == "districting" && sort!(items)
        return "[" * join(items, ",") * "]"
    end
    return JSON.json(x)
end
normalizeText(text) = foldl((t, m) -> replace(t, m), MASKS; init = text)

# A float: digits with a decimal point or an exponent, not part of a word (such as `9e640` in a hex hash).
const FLOAT = r"(?<![\w.])-?(?:\d+\.\d+(?:[eE][-+]?\d+)?|\d+[eE][-+]?\d+)(?![\w.])"
parseFloat(s) = (x = tryparse(Float64, s); x === nothing || !isfinite(x) ? nothing : x)

"""The fingerprint of `text`: the SHA-256 of `text` with each float replaced by `#`, and the number of floats,
their sum, the sum of their absolute values and their sum weighted by position (1 to 10, cycling)."""
function fingerprint(text)
    xs = Float64[x for x in (parseFloat(m.match) for m in eachmatch(FLOAT, text)) if x !== nothing]
    w = [1 + (i % 10) for i in eachindex(xs)]
    skeleton = replace(text, FLOAT => m -> parseFloat(m) === nothing ? m : "#")
    return (sha = bytes2hex(sha256(skeleton)), n = length(xs), sum = sum(xs; init = 0.0),
            abssum = sum(abs, xs; init = 0.0), wsum = sum(w .* xs; init = 0.0))
end

"Two fingerprints match: the same text and number of floats, and sums within `SUM_RTOL` of the floats' scale."
function sameFingerprint(a, b)
    (a.sha == b.sha && a.n == b.n) || return false
    scale = max(a.abssum, b.abssum, floatmin()) * 10
    return all(abs(getfield(a, k) - getfield(b, k)) <= SUM_RTOL * scale for k in (:sum, :abssum, :wsum))
end

fingerprintLine(f, path) = join([f.sha, f.n, repr(f.sum), repr(f.abssum), repr(f.wsum)], " ") * "  " * path
function parseFingerprintLine(line)
    fields, path = split(line, "  "; limit = 2)
    sha, n, total, abssum, wsum = split(fields, " ")
    return String(path) => (sha = String(sha), n = parse(Int, n), sum = parse(Float64, total),
                            abssum = parse(Float64, abssum), wsum = parse(Float64, wsum))
end

const NUM = r"-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?"
"`a` and `b` are the same text with each number within `RTOL`."
function sameNumbers(a, b)
    split(a, NUM) == split(b, NUM) || return false
    xs, ys = [m.match for m in eachmatch(NUM, a)], [m.match for m in eachmatch(NUM, b)]
    length(xs) == length(ys) || return false
    close(x, y) = (a = parseFloat(x); b = parseFloat(y); a !== nothing && b !== nothing && isapprox(a, b; rtol = RTOL))
    return all(x == y || close(x, y) for (x, y) in zip(xs, ys))
end

"""A help text as its words: Julia versions wrap the same Markdown differently, and only some draw a rule (`───`)
between paragraphs."""
helpWords(text) = join(split(replace(text, r"─+" => " ")), " ")

"Printed text `a` and `b` of case `name` match."
samePrinted(name, a, b) = startswith(name, "help") ? sameNumbers(helpWords(a), helpWords(b)) : sameNumbers(a, b)

# --- the cases -----------------------------------------------------------------------------------------------

const CT = "cycleWalk_ct_slice.jsonl.gz"
const META = "cycleWalk_ct_metadata.jsonl.gz"
const NC1 = "cycleWalk_v0p2_thread3_walkVSinternal_0.01_gamma0.5.jsonl.gz"
const NC2 = "cycleWalk_v0p2_thread3_walkVSinternal_0.01_gamma0.5_iso0.15.jsonl.gz"
const MS12 = "atlas_measureID12.jsonl.gz"
const ORD = "atlas_ordered.jsonl.gz"
const G3, G4, MS = "demo_grid_3x3.jsonl.gz", "demo_grid_4x4.jsonl.gz", "demo_multiscale.jsonl.gz"
const V1 = [CT, META, NC1, NC2, MS12, ORD, G3, G4, MS]
const CTGRAPH, NCGRAPH, MSGRAPH = "../../data/CT_pct20.json", "../../data/NC_pct21.json",
                                  "../../data/demo_multiscale_graph.json"
const CTG = ["--graph", CTGRAPH, "--pop-col", "POP20", "--node-col", "NAME", "--area-col", "area",
             "--border-col", "border_length", "--edge-perimeter-col", "length"]
const VOTES = ["--vote-cols", "G20PREDEM,G20PREREP;G20PREREP,G20PREDEM"]

"The cases, as `name => (inputs, commands)`: the example atlases copied into the case's directory, and the commands."
function snapshotCases()
    cases = Pair{String,Any}[]
    case(name, inputs, cmds...) = push!(cases, name => (inputs, collect(cmds)))
    for a in vcat(V1, "v2_" .* V1)
        case("info_$a", [a], ["info", a])
        case("list-map-data_$a", [a], ["list-map-data", a])
        case("list-nodes_$a", [a], ["list-nodes", a])
        case("summarize_$a", [a], ["summarize-map-data", a, "--quiet"])
        case("extract_$a", [a], ["extract-map-data", a, "--quiet"])
        case("histogram_$a", [a], ["extract-map-data-histogram", a, "--quiet"])
        case("assignments_$a", [a], ["extract-assignments", a, "--quiet"])
    end
    case("info_extract", [META], ["info", META, "--extract-script"], ["info", META, "--extract-script"],
         ["info", META, "--extract-script", "--force"])
    case("list-nodes_map2", [G4, MS12], ["list-nodes", G4, "--map", "2"], ["list-nodes", MS12, "--map", "3"])
    case("convert", [CT, MS12], ["convert", CT, "ct_v2.jsonl.gz", "--to", "2"],
         ["convert", "ct_v2.jsonl.gz", "ct_v1.jsonl", "--to", "1"], ["convert", MS12, "ms_v2.jsonl", "--quiet"])
    case("relabel_grid", [G4], ["relabel", G4, "out.jsonl.gz", "--quiet"],
         ["relabel", G4, "first.jsonl", "--first-map", "--quiet"])
    case("relabel_ms", [MS], ["relabel", MS, "out.jsonl.gz", MSGRAPH, "--quiet"])
    case("relabel_nc", [MS12, NC1], ["relabel", MS12, "w.jsonl.gz", NCGRAPH, "--weight-population", NCGRAPH,
                                     "--population-attr", "pop2020cen", "--quiet"],
         ["relabel", NC1, "nc1.jsonl.gz", "--quiet"])
    case("add_list", String[], ["add", "--list-writers"])
    case("add_basic", [CT], ["add", "get_log_spanning_trees,get_isoperimetric_scores", CT, "a.jsonl.gz", CTG...,
                             "--overwrite", "--quiet"])
    case("add_partisan", [CT], ["add", "[\"get_partisan_margins\", \"get_partisan_seats\"]", CT, "p.jsonl", CTG...,
                                VOTES..., "--quiet"])
    case("add_config", [CT], ["add", "get_isoperimetric_scores", CT, "c.jsonl.gz", "--config", "../../data/ct.toml",
                              "--overwrite", "--quiet"])
    case("add_chain", [CT], ["add", "get_partisan_margins", CT, "p1.jsonl.gz", CTG..., VOTES..., "--quiet"],
         ["add", "get_partisan_seats", "p1.jsonl.gz", "p2.jsonl.gz", CTG..., VOTES..., "--quiet"])
    case("add_node_data", [CT], ["add", "get_isoperimetric_scores,get_partisan_margins", CT, "a.jsonl.gz", CTG...,
                                 "--node-data", "COUNTY,G20PREDEM", "--vote-cols", "G20PREDEM,G20PREREP",
                                 "--overwrite", "--quiet"])
    case("extract_opts", [CT], ["extract-map-data", CT, "--no-compression", "--max-maps", "3", "--quiet"],
         ["extract-map-data", CT, "--quiet"], ["extract-map-data", CT, "--force", "--quiet"])
    case("extract_add", [CT], ["extract-map-data", CT, "--add", "get_isoperimetric_scores,get_partisan_margins",
                               CTG..., VOTES..., "--quiet"],
         ["extract-map-data", CT, "--add", "get_isoperimetric_scores,get_isoperimetric_score", CTG..., "--quiet"])
    case("extract_add_config", [CT], ["extract-map-data", CT, "--add", "get_log_spanning_trees", "--config",
                                      "../../data/ct.toml", "--no-compression", "--quiet"])
    case("extract_node_data", [CT], ["extract-map-data", CT, "--add", "get_log_spanning_trees", CTG...,
                                     "--node-data", "COUNTY", "--quiet"])
    case("histogram_opts", [CT], ["extract-map-data-histogram", CT, "--no-sort", "--no-compression", "--quiet"],
         ["extract-map-data-histogram", CT, "--bins", "0,250,500,1000", "--moment-powers", "1,2", "--quiet"],
         ["extract-map-data-histogram", CT, "--quiet"], ["extract-map-data-histogram", CT, "--force", "--quiet"])
    case("histogram_opts2", [CT], ["extract-map-data-histogram", CT, "--bin-range", "0,1000", "--bin-num", "10",
                                   "--burn-in", "5", "--max-maps", "10", "--quiet"],
         ["extract-map-data-histogram", CT, "--integer", "auto", "--no-compression", "--quiet"])
    case("histogram_integer", [CT], ["extract-map-data-histogram", CT, "--integer", "true", "--no-compression",
                                     "--quiet"])
    case("histogram_add", [CT], ["extract-map-data-histogram", CT, "--add",
                                 "get_isoperimetric_scores,get_partisan_seats", CTG..., VOTES..., "--no-compression",
                                 "--quiet"])
    case("histogram_config", [CT], ["extract-map-data-histogram", CT, "--add", "get_isoperimetric_scores", "--config",
                                    "../../data/ct.toml", "--node-data", "COUNTY", "--no-compression", "--quiet"])
    case("summarize_max", [CT, NC1], ["summarize-map-data", CT, "--max-maps", "5", "--quiet"],
         ["summarize-map-data", NC1, "--max-maps", "7", "--quiet"])
    case("assignments_graph", [MS, MS12],
         ["extract-assignments", MS, "--graph", MSGRAPH, "--no-compression", "--quiet"],
         ["extract-assignments", MS12, "--graph", NCGRAPH, "--quiet"],
         ["extract-assignments", MS, "--no-compression"], ["extract-assignments", MS, "--no-compression"],
         ["extract-assignments", MS, "--no-compression", "--force"])
    # Without --quiet: the messages (the progress bars go to stderr, which is not kept).
    case("loud", [CT, G4], ["relabel", G4, "r.jsonl.gz"],
         ["add", "get_isoperimetric_scores", CT, "a.jsonl.gz", CTG...],
         ["add", "get_isoperimetric_scores", CT, "a.jsonl.gz", CTG..., "--overwrite"],
         ["extract-map-data", CT], ["extract-map-data", CT],
         ["extract-map-data-histogram", CT], ["extract-map-data-histogram", CT],
         ["summarize-map-data", CT, "--max-maps", "4"], ["convert", CT, "c.jsonl.gz"])
    # The help of every subcommand (a case each, so each stays short enough to be kept in full), and the version.
    case("help", String[], ["--help"], ["--version"])
    for c in ["info", "convert", "list-map-data", "list-nodes", "relabel", "add", "extract-map-data",
              "extract-map-data-histogram", "summarize-map-data", "extract-assignments"]
        case("help_$c", String[], [c, "--help"])
    end
    # Errors meant for the user.
    case("errors", [CT, G4, MS],
         ["add", "get_log_spanning_trees", CT, "o.jsonl", "--graph", CTGRAPH, "--pop-col", "POP20", "--node-col",
          "NAME", "--quiet"],
         ["add", "get_log_spanning_trees", CT, "o.jsonl", "--pop-col", "POP20", "--node-col", "NAME"],
         ["add", "get_log_spanning_trees", CT, "o.jsonl", "--graph", CTGRAPH, "--node-col", "NAME"],
         ["add", "get_partisan_margins", CT, "o.jsonl", "--graph", CTGRAPH, "--pop-col", "POP20", "--node-col", "NAME"],
         ["add", "no_such_writer", CT, "o.jsonl", "--graph", CTGRAPH, "--pop-col", "POP20", "--node-col", "NAME"],
         ["add", "", CT, "o.jsonl"],
         ["relabel", MS, "r.jsonl", MSGRAPH, "--weight-population", CTGRAPH, "--quiet"],
         ["relabel", G4, "r.jsonl", MSGRAPH, "--quiet"],
         ["extract-map-data", CT, "--max-maps", "-1"],
         ["extract-map-data-histogram", CT, "--burn-in", "1000", "--quiet"],
         ["extract-map-data-histogram", CT, "--max-maps", "-1", "--quiet"],
         ["summarize-map-data", CT, "--max-maps", "-1"],
         ["list-nodes", CT, "--map", "0"], ["list-nodes", CT, "--map", "45"],
         ["convert", CT, "c.jsonl", "--to", "3"])
    v2 = "v2_" .* (CT, MS, MS12, G4)
    case("v2_relabel", [v2[4], v2[2], v2[3]], ["relabel", v2[4], "g.jsonl.gz", "--first-map", "--quiet"],
         ["relabel", v2[2], "m.jsonl", MSGRAPH, "--quiet"],
         ["relabel", v2[3], "w.jsonl.gz", NCGRAPH, "--weight-population", NCGRAPH, "--population-attr", "pop2020cen",
          "--quiet"])
    case("v2_add", [v2[1]], ["add", "get_log_spanning_trees,get_isoperimetric_scores,get_partisan_seats", v2[1],
                             "a.jsonl.gz", CTG..., VOTES..., "--overwrite", "--quiet"])
    case("v2_extract_add", [v2[1]], ["extract-map-data", v2[1], "--add",
                                     "get_isoperimetric_scores,get_partisan_margins", CTG..., VOTES...,
                                     "--no-compression", "--quiet"])
    case("v2_histogram_add", [v2[1]], ["extract-map-data-histogram", v2[1], "--add", "get_log_spanning_trees", CTG...,
                                       "--quiet"])
    case("v2_assignments_graph", [v2[2], v2[3]], ["extract-assignments", v2[2], "--graph", MSGRAPH, "--quiet"],
         ["extract-assignments", v2[3], "--graph", NCGRAPH, "--no-compression", "--quiet"])
    case("v2_convert", [v2[1]], ["convert", v2[1], "back.jsonl", "--to", "1"])
    return cases
end

"""
Run every case under `root`: `root/cases/<case>/` holds what it wrote, and `printed[case]` what it printed. The
example atlases are copied in, along with format-v2 copies of them (`v2_<name>`), and the graphs under `root/data`,
so each case runs with relative paths and nothing printed or written depends on where.
"""
function runSnapshotCases(root)
    mkpath(joinpath(root, "data"))
    for f in ("CT_pct20.json", "NC_pct21.json")
        cp(joinpath(REPO, "Data", f), joinpath(root, "data", f))
    end
    cp(joinpath(EXAMPLES, "demo_multiscale_graph.json"), joinpath(root, "data", "demo_multiscale_graph.json"))
    write(joinpath(root, "data", "ct.toml"), """
        [plans]
        map_directory = ["..", "..", "data"]
        map_file = "CT_pct20.json"
        pop_col = "POP20"
        geo_units = ["NAME"]
        area_col = "area"
        node_border_col = "border_length"
        edge_perimeter_col = "length"
        """)
    v2dir = joinpath(root, "v2")
    mkpath(v2dir)
    for f in V1
        convertAtlas(joinpath(EXAMPLES, f), joinpath(v2dir, "v2_" * f); formatVersion = 2, cores = 1)
    end
    source(a) = startswith(a, "v2_") ? joinpath(v2dir, a) : joinpath(EXAMPLES, a)

    printed = Dict{String,String}()
    for (name, (inputs, cmds)) in snapshotCases()
        dir = joinpath(root, "cases", name)
        mkpath(dir)
        foreach(a -> cp(source(a), joinpath(dir, a)), inputs)
        log = IOBuffer()
        cd(dir) do
            for c in cmds
                println(log, "\$ mapatlas ", join(c, " "))
                out = mktemp() do path, io
                    logs = IOBuffer()
                    code = try
                        with_logger(SimpleLogger(logs, Logging.Info)) do
                            redirect_stderr(devnull) do
                                redirect_stdout(io) do
                                    command_main(c)
                                end
                            end
                        end
                    catch e
                        "error: " * sprint(showerror, e)
                    end
                    close(io)
                    read(path, String) * String(take!(logs)) * "[exit $code]\n"
                end
                print(log, out)
            end
        end
        printed[name] = normalizeText(String(take!(log)))
        rm.(joinpath.(dir, inputs))
    end
    return printed
end

"Every file under `dir`, as paths relative to it, sorted."
filesUnder(dir) = sort!([relpath(joinpath(d, f), dir) for (d, _, fs) in walkdir(dir) for f in fs])

"The snapshot of a run: `printed` (case => text kept in full) and `fingerprints` (path => fingerprint)."
function takeSnapshot(root, printed)
    kept, fingerprints = Dict{String,String}(), Dict{String,Any}()
    for (name, text) in printed
        sizeof(text) <= PRINTED_MAX ? (kept[name] = text) : (fingerprints["$name/_printed"] = fingerprint(text))
    end
    cases = joinpath(root, "cases")
    for f in filesUnder(cases)
        fingerprints[f] = fingerprint(normalize(joinpath(cases, f)))
    end
    return (printed = kept, fingerprints = fingerprints)
end

"Write snapshot `s` to `dir`, replacing what is there."
function writeSnapshot(dir, s)
    rm(dir; force = true, recursive = true)
    mkpath(joinpath(dir, "printed"))
    for (name, text) in s.printed
        write(joinpath(dir, "printed", name * ".txt"), text)
    end
    open(joinpath(dir, "fingerprints.txt"), "w") do io
        for f in sort!(collect(keys(s.fingerprints)))
            println(io, fingerprintLine(s.fingerprints[f], f))
        end
    end
end

"Read the snapshot in `dir`."
function readSnapshot(dir)
    printed = Dict(splitext(f)[1] => read(joinpath(dir, "printed", f), String)
                   for f in readdir(joinpath(dir, "printed")))
    fingerprints = Dict{String,Any}(parseFingerprintLine(l) for l in eachline(joinpath(dir, "fingerprints.txt")))
    return (printed = printed, fingerprints = fingerprints)
end

"What differs between the snapshots `want` and `got`, one line per difference."
function snapshotDifferences(want, got)
    out = String[]
    for (what, w, g, same) in (("printed text of", want.printed, got.printed, samePrinted),
                               ("file", want.fingerprints, got.fingerprints, (_, a, b) -> sameFingerprint(a, b)))
        foreach(k -> push!(out, "missing: $what $k"), sort!(collect(setdiff(keys(w), keys(g)))))
        foreach(k -> push!(out, "new: $what $k"), sort!(collect(setdiff(keys(g), keys(w)))))
        for k in sort!(collect(intersect(keys(w), keys(g))))
            same(k, w[k], g[k]) || push!(out, "differs: $what $k")
        end
    end
    return out
end

@testset "snapshots: what every command prints and writes" begin
    root = mktempdir()
    printed = withenv("COLUMNS" => "120", "LINES" => "40") do      # the help text is wrapped to the width
        runSnapshotCases(root)
    end
    got = takeSnapshot(root, printed)
    if get(ENV, "UPDATE_SNAPSHOTS", "") == "1"
        writeSnapshot(SNAPSHOTS, got)
        @info "Rewrote the snapshots in $SNAPSHOTS: review their diff before committing."
    end
    diffs = snapshotDifferences(readSnapshot(SNAPSHOTS), got)
    if !isempty(diffs)
        kept = joinpath(tempdir(), "mapatlas-snapshot-run")
        rm(kept; force = true, recursive = true)
        cp(root, kept)
        writeSnapshot(joinpath(kept, "snapshots"), got)     # to diff against snapshots/
        @error "The commands' output differs from snapshots/ (an intended change? rerun with UPDATE_SNAPSHOTS=1 " *
               "and review the diff). This run's output is in $kept.\n" * join(diffs, "\n")
    end
    @test isempty(diffs)
    @test length(got.printed) + count(endswith("/_printed"), keys(got.fingerprints)) == length(snapshotCases())
end
