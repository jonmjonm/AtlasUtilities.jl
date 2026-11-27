# Aqua's package quality checks: method ambiguities, unbound type parameters, undefined exports, stale and
# extra dependencies, compat bounds, type piracy and persistent tasks.
import Aqua

@testset "Aqua" begin
    # Pkg is used only by deps/build.jl, which runs with AtlasCLI's dependencies, so it is listed but not
    # loaded by the package itself.
    Aqua.test_all(AtlasCLI; stale_deps = (ignore = [:Pkg],),
                  # The persistent-task check precompiles the package in a new process and allows `tmax`
                  # seconds for it to exit; on a cold depot (as on CI) the default 30 s is too short.
                  persistent_tasks = (tmax = 300,))
end
