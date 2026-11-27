# cli.jl -- what the `atlas` command adds to the library functions: turning flags into typed arguments, printing
# the results, and naming the command and its flags in error messages. (These move to AtlasCLI with the commands.)

# The library functions whose error messages start with their name (`relabelAtlas: ...`); in a command's errors
# that becomes the command (`atlas relabel: ...`).
const LIBRARY_FUNCTIONS = Set(["atlasInfo", "listMapData", "listNodes", "extractScripts", "relabelAtlas",
                               "mapDataHistograms", "writeHistograms", "summarizeMapData", "assignmentMatrix",
                               "extractMapData", "extractAssignments", "addMapData", "WriterSet", "computeWriters",
                               "loadGraph", "listWriters", "listWriterDetails"])

# Library keywords as the command's flags: `max_maps = 5` -> `--max-maps 5`, `overwrite = true` -> `--overwrite`.
const KEYWORD_FLAGS = Dict(k => "--" * replace(k, '_' => '-') for k in
    ["graph", "config", "pop_col", "node_col", "area_col", "border_col", "edge_perimeter_col", "node_data",
     "vote_cols", "overwrite", "force", "max_maps", "burn_in", "map", "first_map", "population_attr", "bin_range",
     "bin_num", "bins", "moment_powers", "integer"])
KEYWORD_FLAGS["population_file"] = "--weight-population"
KEYWORD_FLAGS["writers"] = "--add"

"""
    cliMessage(msg, command) -> String

A library error message as the command `command` reports it: a leading library function name becomes
`atlas <command>`, and each keyword it names (`max_maps = 5`, `overwrite = true`) becomes the flag
(`--max-maps 5`, `--overwrite`). Any other message is returned unchanged.
"""
function cliMessage(msg::AbstractString, command::AbstractString)
    m = match(r"^([A-Za-z]+): ", msg)
    (m === nothing || !(m.captures[1] in LIBRARY_FUNCTIONS)) && return String(msg)
    out = "atlas $command: " * msg[(length(m.match) + 1):end]
    out = replace(out, r"\b([a-z][a-z0-9_]*) = true\b" => s -> get(KEYWORD_FLAGS, s[1:(end - 7)], s))
    out = replace(out, r"\b([a-z][a-z0-9_]*) = " => s -> haskey(KEYWORD_FLAGS, s[1:(end - 3)]) ?
                                                         KEYWORD_FLAGS[s[1:(end - 3)]] * " " : s)
    return out
end

"""
    cli(f, command)

Run the body `f()` of the command `command`, reporting a library error in the command's terms (see
[`cliMessage`](@ref)). Returns `nothing`.
"""
function cli(f, command::AbstractString)
    try
        f()
    catch e
        e isa ErrorException || rethrow()
        msg = cliMessage(e.msg, command)
        msg == e.msg && rethrow()
        throw(ErrorException(msg))
    end
    return nothing
end

"Print `msg` to stdout, so it shows in the normal output, and to stderr, for pipelines that only watch that."
printBoth(msg) = (println(msg); println(stderr, msg))

"""
    cliWriterSet(functions; config, graph, pop_col, node_col, area_col, border_col, edge_perimeter_col,
                 node_data, vote_cols) -> WriterSet

The `WriterSet` of `atlas add`'s arguments, or of `--add`: the writer names and every flag are strings as given
on the command line (an empty flag is unset).
"""
cliWriterSet(functions::AbstractString; node_data::AbstractString = "", vote_cols::AbstractString = "", kw...) =
    WriterSet(parseFunctionNames(functions); node_data = parseNodeData(node_data),
              vote_cols = parseVotePairs(vote_cols), kw...)

"Print what `extractScripts` did, as `atlas info --extract-script` reports it."
function printExtracted(r)
    any(e -> first(e) == "script", r.entries) ||
        printBoth("--extract-script: this atlas has no \"$SCRIPT_KEY\" entry.")
    for (entry, path) in r.entries
        if path in r.skipped
            printBoth("--extract-script: $(basename(path)) already exists; the $entry entry was not " *
                      "written (pass --force to overwrite).")
        else
            println("Wrote $entry entry to: ", basename(path))
        end
    end
end

"Print the writers `atlas add --list-writers` lists."
function printWriterList()
    d = listWriterDetails()
    println("Writer functions usable with atlas add / --add (CycleWalk ", pkgversion(CycleWalk), "):")
    println()
    for (n, fast) in d.plain
        println("  ", n, fast ? " (fast)" : "")
    end
    println()
    println("Partisan writers (require --vote-cols votes1,votes2[;votes1,votes2...]):")
    for n in d.partisan
        println("  ", n)
    end
end
