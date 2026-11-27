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
    cli(f, command; cyclewalk = false)

Run the body `f()` of the command `command`, reporting a library error in the command's terms (see
[`cliMessage`](@ref)). With `cyclewalk`, CycleWalk is loaded first (see [`loadCycleWalk`](@ref)) and `f` runs in
the world where the extension's methods exist. Returns `nothing`.
"""
function cli(f, command::AbstractString; cyclewalk::Bool = false)
    try
        if cyclewalk
            loadCycleWalk(command)
            Base.invokelatest(f)
        else
            f()
        end
    catch e
        e isa ErrorException || rethrow()
        msg = cliMessage(e.msg, command)
        msg == e.msg && rethrow()
        throw(ErrorException(msg))
    end
    return nothing
end

"CycleWalk's package id: AtlasUtilities' weak dependency, the trigger of AtlasUtilitiesCycleWalkExt."
const CYCLEWALK = Base.PkgId(Base.UUID("ac9cec89-1413-42d8-a7d6-c246d938c565"), "CycleWalk")

"""
    loadCycleWalk(command) -> Module

The AtlasUtilitiesCycleWalkExt extension, loading CycleWalk first if it is installed but not yet loaded (as
`using CycleWalk` would). Errors, saying how to install it, if it is not installed. (Until the commands move to
AtlasCLI, whose `mapatlas` environment has CycleWalk, `atlas add` and `--add` load it this way.)
"""
function loadCycleWalk(command::AbstractString)
    ext = Base.get_extension(@__MODULE__, :AtlasUtilitiesCycleWalkExt)
    ext === nothing || return ext
    Base.locate_package(CYCLEWALK) === nothing &&
        error("atlas $command: needs the package CycleWalk, which is not installed in this environment " *
              "($(Base.active_project())); install it with `import Pkg; Pkg.add(\"CycleWalk\")`.")
    Base.require(CYCLEWALK)
    ext = Base.get_extension(@__MODULE__, :AtlasUtilitiesCycleWalkExt)
    ext === nothing && error("atlas $command: CycleWalk loaded, but the AtlasUtilitiesCycleWalkExt extension did " *
                             "not. Check that its version satisfies AtlasUtilities' [compat].")
    return ext
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
    println("Writer functions usable with atlas add / --add (CycleWalk ", pkgversion(Base.root_module(CYCLEWALK)),
            "):")
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
