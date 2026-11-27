# Tests of the `mapatlas` command: every subcommand through `command_main`, the entry point the installed command
# uses. The library functions are tested in AtlasUtilities.
using Test
using AtlasIO
using AtlasCLI
using AtlasUtilities
import JSON

include("helpers.jl")
include("infoTests.jl")
include("nodesTests.jl")
include("assignmentsTests.jl")
include("addTests.jl")
include("convertTests.jl")
include("cliTests.jl")
include("versionsTests.jl")
include("completionTests.jl")
include("aquaTests.jl")
