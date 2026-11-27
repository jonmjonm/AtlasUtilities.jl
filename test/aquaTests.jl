# Aqua's package quality checks: method ambiguities, unbound type parameters, undefined exports, stale and
# extra dependencies, compat bounds, type piracy and persistent tasks.
import Aqua

@testset "Aqua" begin
    # TOML is used only by the CycleWalk extension (reading a CycleWalk `config`). An extension can use only the
    # package's own [deps] and its trigger, so TOML has to stay in [deps] although the library itself never
    # loads it by name; ignore it explicitly in the stale-dependency check.
    Aqua.test_all(AtlasUtilities; stale_deps = (ignore = [:TOML],),
                  # The persistent-task check precompiles the package in a new process and allows `tmax`
                  # seconds for it to exit; on a cold depot (as on CI) the default 30 s is too short.
                  persistent_tasks = (tmax = 300,))
end
