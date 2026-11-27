# AtlasUtilities refactor plan

As of 2026-11-26. Copied from the Claude Docs doc *AtlasUtilities refactor plan* (https://claude.ai/artifact/GNrUTL7KjxQTKjxtFqXT5Q); this file is now the copy to keep up to date.

AtlasUtilities becomes one light library whose heavier roles (CycleWalk processing, shapefiles, plotting, GUI) are package extensions, plus a separate AtlasCLI package in a subdirectory of the same repo that provides the `mapatlas`, `mapatlas-plot` and `mapatlas-gui` tools. The first branch builds only the core, the CycleWalk extension and the light `mapatlas` tool; plotting is redesigned later.

## Decisions so far

All decided on 2026-11-26. The pre-refactor state is saved as the `pre-refactor` branch (main at `bbd2466`).

| Decision | Choice | Why |
| --- | --- | --- |
| Packages | Two: **AtlasUtilities** (library) and **AtlasCLI** (commands) | Fewer registrations in General; plotting stays optional through extensions |
| Heavier roles | Package extensions of AtlasUtilities, one per role | `using AtlasUtilities` stays light; each role switches on when its package is loaded |
| CycleWalk processing | An extension, triggered by `CycleWalk` | Removes 13 packages and 0.7 s from the core |
| Repo layout | AtlasUtilities at the repo root, AtlasCLI in `AtlasCLI/` | Existing `Pkg.add(url = ...)` installs keep working |
| Tools | `mapatlas` (light), `mapatlas-plot`, maybe `mapatlas-gui`, each with its own environment; `mapatlas render`/`video`/`view` hand off to the heavier tool | The light tool can never load heavy packages by accident; no more `install-render` |
| `mapatlas render` | Dropped on the first branch, back when plotting is redesigned | Plotting and GUI are redesigned from scratch |
| Plotting library | Plots.jl for maps, data plots and video; Makie only for an interactive GUI | Plots loads in ~2 s against ~5 s; with simplified outlines a 1,000-frame NC video takes ~7 min |
| Plotting API | Three layers: map data in the core, each library's own `plot`, convenience functions | Callers get native plot objects; no name clashes; report and GUI reuse the data |
| Library API | Exported, documented functions with descriptive names; `run_*` move to AtlasCLI | AtlasUtilities must be usable from other code |
| Minimum Julia | 1.11 (`[compat]`); `[workspace]` usable when developing on 1.12+ | `public` keyword; CI already tests 1.11+ |

## Structure

```text
AtlasCLI  (AtlasCLI/ subdirectory; one environment per tool)
  [*] mapatlas        core + CycleWalk extension; every command except render
  [ ] mapatlas-plot   adds Plots, Shapefile, LibGEOS; maps and videos to files
  [ ] mapatlas-gui    adds GLMakie (needs a display); interactive viewer
        |  each tool calls the public API
        v
AtlasUtilities  (repo root; the library other code loads)
  [*] core            using AtlasUtilities
                      reading and info, conversion, relabeling, histograms,
                      summaries, assignments, extraction
                      uses AtlasIO, StreamHistogram, Hungarian, JSON
                      later: map data and geometry, Plots recipes (RecipesBase), HTML report
  extensions (each switches on when its package is loaded):
  [*] CycleWalkExt    on: CycleWalk    addMapData, writers
  [ ] ShapefileExt    on: Shapefile    read shapefiles
  [ ] GEOSExt         on: LibGEOS      county outlines
  [ ] PlotsExt        on: Plots        save, video
  [ ] MakieExt        on: Makie        GUI viewer

[*] = built on the first branch    [ ] = later
```

Each tool is a launcher with its own environment; the packages it loads decide which extensions switch on. The first branch builds only the parts marked `[*]`.

## Roles

Each role is either the core itself or an extension that switches on when its trigger package is loaded. An extension can use only AtlasUtilities' own dependencies plus its triggers, so each role gets as few triggers as possible.

| Role | Where | Switched on by | Holds | Built |
| --- | --- | --- | --- | --- |
| core | AtlasUtilities | `using AtlasUtilities` | Reading and info, conversion, relabeling, histograms, summaries, assignments, extraction; later the plotting data layer and geometry | First branch |
| process | `AtlasUtilitiesCycleWalkExt` | `CycleWalk` | `addMapData`, the writers (`WriterSet` construction, `computeWriters`, `listWriters`), the CycleWalk graph; `--add` for extraction; future MFRecom work | First branch |
| geo: point graphs | core | — | Voronoi cells, county lines from graph edges, outline simplification (plain coordinate types) | With plotting |
| geo: shapefiles | `AtlasUtilitiesShapefileExt` | `Shapefile` | Reading shapefiles into the core's geometry types | With plotting |
| geo: county outlines | `AtlasUtilitiesGEOSExt` | `LibGEOS` | Dissolving precincts into counties; dropped if a pure-Julia method works on our shapefiles | With plotting |
| plot + video | core (RecipesBase recipes) plus `AtlasUtilitiesPlotsExt` | `Plots` | `plot(mapData)`, data plots, saving, `atlasVideo` | Later |
| gui | `AtlasUtilitiesMakieExt` | `Makie` (GLMakie for a window, WGLMakie for a browser) | Key-stepping viewer, later a dashboard | Later |
| report | core (+ images when `Plots` is loaded) | — | A self-contained interactive HTML report; optionally a Quarto `.qmd` (rendering needs the `quarto` program) | Later |

Analysis (histograms, summaries, assignments, relabeling) stays explicitly in the core: it is the most-used part and needs nothing heavy. A key-stepping viewer cannot be built on Plots, which has no keyboard events, so it belongs to gui (or to the HTML report).

## Where existing code goes

Every file in today's `src/` has a home; only rendering is started over. The printing `run_*` functions become library functions plus thin AtlasCLI wrappers.

| Today | New home | Notes |
| --- | --- | --- |
| `info.jl`: `atlasInfo`, `listMapData`, `atlasHeaderInfo`, script extraction | core | Printing (`run_info`) moves to AtlasCLI |
| `convert.jl` | removed | AtlasIO already exports `convertAtlas(src, dst; formatVersion, cores)`; AtlasCLI's `convert` calls it directly |
| `nodes.jl`: `nodeIdString`, node listing | core | `run_list_nodes` becomes `listNodes` + a CLI wrapper |
| `json.jl`, `threading.jl` | core | Internal helpers |
| `relabel.jl`: `findRelabeling`, `relabelMap`, `confusionMatrix`, `Hierarchy`, `loadPopulation`, ... | core | `run_relabel` becomes `relabelAtlas` + a CLI wrapper |
| `assignments.jl`: `assignmentMatrix`, CSV export | core | `run_extract_assignments` becomes `extractAssignments` |
| `extractHistogram.jl`: `mapDataHistograms`, CSV/JSON writers | core | Its `add` option calls into process |
| `summarize.jl` | core | `summarizeMapData` returns data; AtlasCLI formats the text |
| `extract.jl` | core | Its `--add` setup (`setupAddComputation`) moves to process |
| `add.jl`, `writers.jl`: `run_add`, `WriterSet` construction, `computeWriters`, `listWriters`, `buildGraph`, provenance header | process (`AtlasUtilitiesCycleWalkExt`) | The `WriterSet` type and the function names stay declared in the core; its graph field is typed `Any`, so the type needs no CycleWalk |
| `AtlasUtilities.jl`: the `@cast` commands, help text, string parsing such as `"a,b;c,d"` | AtlasCLI |  |
| `deps/build.jl`, `Comonicon.toml`, shell completions | AtlasCLI | Builds one launcher and environment per tool |
| `render.jl` and `ext/AtlasUtilitiesRenderExt/` | Removed on the first branch; reused when plotting is redesigned | Keep the ideas: `voronoiCells` and point-graph code (core geometry, without Makie types), `matchMapToRows` and `reportMatchQuality` (core), shapefile loading (Shapefile extension), county dissolve (LibGEOS extension). The drawing, `openInViewer` and `install-render` go. |
| `atlas-view` branch (GLMakie viewer) | Reference for gui | Not merged; it loads every map into memory, where the new viewer will stream |

## Public API

AtlasUtilities stays a library other code can load and build on. Rule: **export what users build on, mark `public` what advanced users need, keep the rest internal** — every exported name is a promise not to break it without a major version.

Functions whose working code lives in an extension are still declared, exported and documented by AtlasUtilities. Called without their extension, they give a clear message through Julia's error hints (`Base.Experimental.register_error_hint`), e.g. *"`addMapData` needs CycleWalk: run `using CycleWalk`"*. Library functions are silent by default; a `progress` keyword turns on progress reporting, and AtlasCLI adds the messages.

```julia
using AtlasUtilities
relabelAtlas("in.jsonl.gz", "out.jsonl.gz"; graph = "nc.json")
summarizeMapData("in.jsonl.gz")

using CycleWalk                     # switches on the process extension
addMapData("in.jsonl.gz", "out.jsonl.gz", ["get_cut_edges"]; graph = "nc.json", progress = true)
```

| Group | Exported | Public (not exported) | Source |
| --- | --- | --- | --- |
| Reading | `atlasInfo`, `listMapData`, `listNodes`, `extractScripts` | `nodeIdString` | core |
| Relabeling | `findRelabeling`, `relabelMap`, `relabelAtlas`, `confusionMatrix`, `permutationFromConfusion`, `hammingDistance`, `Hierarchy`, `loadHierarchy`, `loadPopulation` |  | core |
| Analysis | `mapDataHistograms`, `writeHistograms`, `summarizeMapData`, `assignmentMatrix`, `extractMapData`, `extractAssignments` |  | core |
| Process | `addMapData`, `WriterSet`, `computeWriters`, `writerFields`, `listWriters` | `loadGraph` | declared in core, code in the CycleWalk extension |
| Plotting (later) | `districtMapData`, `districtColors`, `atlasVideo` |  | core + extensions |

**Not re-exported:** AtlasIO (`openAtlas`, `eachMap`) and StreamHistogram (`weightedQuantile`, `densityCdf`, ...). Re-exporting would tie AtlasUtilities' version numbers to their APIs; the docs show `using AtlasIO` / `using StreamHistogram` instead.

**Kept internal:**

- `run_*` — replaced by the library names; printing moves to AtlasCLI
- `parseVotePairs`, `parseFunctionNames` — command-line parsing, to AtlasCLI; the library takes vectors, e.g. `vote_cols = [("G20_PR_D", "G20_PR_R")]`
- `parallelDo!`, `chunkranges`, `captureErrors`, `with_serial_blas` — threading internals
- `readJSONFile`, `jsonKeyString`, `stripAtlasExt`, `provenanceHeaderBytes`, `writeHeaderWithProvenance` — file-format internals
- `quartiles`, `weightsVary`, `ashQuantileGap`, `fieldSummaryLines` — returned inside `summarizeMapData`'s result
- `achievedHammingDistance`, `expandLabels`, `coverLabel`, `evalWriters*`, `hasFastMethod`, `smokeTestPartition` — relabeling and writer internals
- `loadAllMaps`, `RENDER_PACKAGES`, `renderExtension`, `run_install_render`, `openInViewer` — gone with the old render design

## Plotting design (later)

Plotting is redesigned on its own branch after the first one; this is the agreed starting point. It has three layers, and each plotting library returns its own native object, so other code can display, modify, combine or embed a map rather than only save it.

1. **Map data, in the core.** `districtMapData(atlas, geo; map = 5)` returns precinct polygons as plain coordinates, each one's district, colors, county lines and a title. No plotting package involved. The geometry is stored once and each map is only a coloring of it, so a video never rebuilds polygons. The types implement **GeoInterface** (3 small dependencies), so GeoJSON export, LibGEOS and GeoMakie understand them for free.
2. **Each library's own `plot`.** Plots: a recipe through RecipesBase (7 packages, mostly Julia's standard library), so `plot(m)` returns a `Plots.Plot`. Makie: `convert_arguments` or a Makie recipe in the Makie extension, giving `plot(m)` and `plot!(ax, m)`.
3. **Convenience functions** built on 1 and 2, e.g. `atlasVideo(atlas, geo, "out.mp4"; maps = 1:1000)`, and multi-panel figures that recipes handle poorly.

```julia
m = districtMapData("atlas.jsonl.gz", "nc_pct21.zip"; key = "prec_id", map = 5)

using Plots
p = plot(m)                                   # a Plots.Plot
plot(plot(m), histogram(x); layout = (1, 2))  # combine with other plots
show(io, MIME"image/png"(), p)                # PNG bytes in memory

using CairoMakie                              # gui extension
fig = plot(m); img = Makie.colorbuffer(fig)   # an in-memory pixel matrix
```

This is the standard Julia pattern on both sides: RecipesBase recipes are how SciML solutions, MCMCChains and Distributions (via StatsPlots) become `plot(x)`; a `...MakieExt` with `convert_arguments` or a recipe is how packages support Makie.

|  |  |
| --- | --- |
| **Pros** | Core stays light; callers get native objects that fit notebooks, layouts and dashboards; report and GUI reuse layer 1; layer 1 is tested with numbers, not images; no name clashes between Plots and Makie |
| **Cons** | Recipes suit one plot, not multi-panel layouts (use layer 3); two drawing implementations to keep alike (small); Makie's recipe system changes between versions (0.24 rewrote it); `plot(districtMapData(...))` is less discoverable than one function, so docs and examples matter |

Considered and set aside: GeometryBasics types in the core (about 43 packages); functions returning only finished images (too rigid, kept as an extra); a backend argument such as `drawMap(PlotsBackend(), ...)` (not idiomatic); separate plotting packages (more registrations).

## First branch: core + process + light `mapatlas`

The first branch leaves every command except `render` working, makes the core much lighter, and decides nothing about plotting. It starts from `main` once the plan is agreed.

1. **AtlasCLI package:** create `AtlasCLI/` with its own `Project.toml`, depending on AtlasUtilities and CycleWalk. Move the `@cast` commands, help text, argument parsing, `deps/build.jl`, `Comonicon.toml` and the shell completions there. The launcher is renamed from `atlas` to `mapatlas` (avoiding MongoDB's `atlas`); its commands behave as before.
2. **Library API in the core:** replace each `run_*` with its exported library function (`relabelAtlas`, `extractMapData`, `extractAssignments`, `summarizeMapData`, `writeHistograms`, `listNodes`, `extractScripts`): silent by default, a `progress` keyword, typed arguments instead of comma strings. AtlasCLI's commands become thin wrappers.
3. **Process extension:** make CycleWalk a weak dependency; move `add.jl`, the CycleWalk parts of `writers.jl` and `setupAddComputation` into `ext/AtlasUtilitiesCycleWalkExt/`. Declare `addMapData`, `computeWriters`, `writerFields`, `listWriters` and `WriterSet`'s constructor in the core, with error hints. `extractMapData(...; add = ...)` and `mapDataHistograms(...; add = ...)` call into it.
4. **Remove rendering:** delete `src/render.jl`, the render extension, `atlas render`, `atlas install-render` and the plotting weak dependencies (they stay on `pre-refactor`).
5. **Remove CLI dependencies from the core:** Comonicon and Pkg go to AtlasCLI.
6. **Julia 1.11:** raise `[compat]` to 1.11 and use `public` for the public-not-exported names. Optionally add a root `[workspace]` with `AtlasCLI/` for development on 1.12+.
7. **Tests:** core tests run without CycleWalk; process tests load it; CLI tests move to `AtlasCLI/test/`. Add Aqua.jl checks (ambiguities, stale dependencies, compat bounds, type piracy).
8. **CI and coverage:** one job per package; Codecov reporting for both, as set up for StreamHistogram.
9. **Docs:** `library.md` becomes the API reference for the new names; the README covers installing the library and the `mapatlas` tool separately; CHANGELOG entry for the breaking changes, including the rename from `atlas`.
10. **Check:** `using AtlasUtilities` loads without CycleWalk, Comonicon or Pkg; package count and load time are measured against the 49 packages and 1.3 s of today; every former `atlas` command except `render` gives the same output as on `pre-refactor`.

### Order of work and models

The steps above are grouped by topic; do them in this order:

1. **Opus: steps 2 and 3**, first, while the commands still live in `src/AtlasUtilities.jl`. Step 2 (the library API) fixes the public signatures and step 3 (the CycleWalk extension) the extension mechanics; the existing `@cast` commands are switched to call the new functions, so the full test suite keeps passing as a check.
2. **Sonnet: step 1**, then steps 4 and 5: move the now-thin commands into `AtlasCLI/` once, onto the final API, rename the launcher to `mapatlas`, then remove rendering and the CLI dependencies from the core.
3. **Sonnet: steps 6 to 9** (Julia 1.11 and `public`, tests and Aqua, CI and coverage, docs).
4. **Step 10 and review:** run the checks against `pre-refactor` (either model), then a `/code-review` on Opus over the whole branch before merging.

Doing step 1 before steps 2 and 3 would move the commands twice and make the Opus work span two packages.

Registration order after the first branch: StreamHistogram (in progress), then AtlasUtilities, then AtlasCLI. Each new package waits 3 days in General.

## Steps 2 and 3 in detail

Design for the Opus work, written 2026-11-26 from the code on `main` (`bbd2466`). The four design decisions below were confirmed on 2026-11-26 and are marked **(decided)**.

### Conventions for the library API (step 2)

- **Function names camelCase, keywords snake_case.** This matches what is already exported: `mapDataHistograms(...; burn_in, max_maps, bin_range, moment_powers)` and `WriterSet(...; pop_col, node_col, vote_cols)`. The one camelCase keyword, `mapDataHistograms(...; sortVals)`, becomes `sort_values` in this breaking release. **(decided)**
- **Silent by default.** `progress::Bool = false` replaces `quiet::Bool = false` (the CLI passes `progress = !quiet`). ProgressMeter stays a core dependency (2 packages of its own).
- **Return results; never print.** Each function returns what it did (counts, paths written, paths skipped), and AtlasCLI prints the messages that `run_*` prints today. Existing files are skipped unless `force = true`, and the skipped paths are returned rather than logged.
- **Errors name the function and keyword, not the command:** `addMapData: graph = "x.json" does not exist`, not `atlas add: ...`. AtlasCLI's error handling adds the command name and flag. **(decided)**
- **Typed arguments instead of comma strings:** vectors of names, `vote_cols = [("G20_PR_D", "G20_PR_R")]`. The string parsing (`parseFunctionNames`, `parseVotePairs`) stays for the CLI to use.
- **`cores::Int = Threads.nthreads()`** keeps its current meaning everywhere.

### Function by function

| Command | Today | Library function after step 2 | Returns |
| --- | --- | --- | --- |
| `info` | `run_info` | `atlasInfo(path)` (exists); `atlasHeaderInfo` becomes `public` for the CLI's text; new `extractScripts(path, dir = pwd(); force = false)` | `atlasInfo`: `Dict` (unchanged). `extractScripts`: `(written, skipped)` path lists |
| `list-map-data` | `run_list_map_data` | `listMapData(path)` (exists) | `Vector{String}` |
| `list-nodes` | `run_list_nodes` | `listNodes(path; map = 1)` | `Vector{String}` of node ids |
| `convert` | `run_convert` | **none:** AtlasIO already exports `convertAtlas(src, dst; formatVersion, cores)`, so the CLI calls it directly. Defining our own would clash with `using AtlasIO, AtlasUtilities`. | (AtlasIO's) |
| `relabel` | `run_relabel(a1, a2, json; firstMap, popJsonPath, popAttr, quiet)` | `relabelAtlas(src, dst; graph = nothing, first_map = false, population_file = nothing, population_attr = nothing, cores, progress)` | number of maps written |
| `add` | `run_add(functions::String, a1, a2; graph keywords..., overwrite, quiet)` | `addMapData(src, dst, ws::WriterSet; overwrite = false, cores, progress)`, plus the convenience `addMapData(src, dst, functions::Vector{String}; graph keywords..., overwrite, cores, progress)`, which builds the `WriterSet` | number of maps written |
| `add --list-writers` | `run_list_writers` (prints) | `listWriters()` returns names; new `public` `listWriterDetails()` returns `(plain = [(name, fast::Bool)], partisan = [names])` for the CLI's listing | as stated |
| `extract-map-data` | `run_extract(a1; add::String, graph keywords..., compress, force, max_maps, quiet)` | `extractMapData(atlas, outdir = <default>; writers::Union{Nothing,WriterSet} = nothing, compress = true, force = false, max_maps = 0, cores, progress)` | `(outdir, written, skipped, nmaps)` |
| `extract-map-data-histogram` | `run_extract_map_data_histogram` | `mapDataHistograms(atlas; writers = nothing, ...)` (exists; its `add`/`vote_cols`/graph keywords become `writers`) plus new `writeHistograms(outdir, hists, nmaps; atlas, compress, force)` (CSV, JSON and `about.md`) | `mapDataHistograms`: `(hists, nmaps)` (unchanged). `writeHistograms`: `(written, skipped)` |
| `summarize-map-data` | `run_summarize_map_data` (prints) | `summarizeMapData(atlas; max_maps = 0, cores, progress)` | a `MapDataSummary` holding per-field statistics, with a `show` method that prints exactly today's text, so the CLI just prints it |
| `extract-assignments` | `run_extract_assignments` | `extractAssignments(atlas, outpath = <default>; graph = nothing, compress = true, force = false, cores, progress)` | `(path, nmaps, units, scale)`, or `nothing` if skipped |

**Writers as an object (decided).** Today `extract-map-data` and `extract-map-data-histogram` each take the writer names as a string plus nine graph keywords (`config`, `graph`, `pop_col`, `node_col`, `area_col`, `border_col`, `edge_perimeter_col`, `node_data`, `vote_cols`), and set them up through their own path (`setupAddComputation`). They take a `WriterSet` instead (`writers = WriterSet(["get_cut_edges"]; graph = "nc.json")`). The graph keywords then live in one place, the `WriterSet` constructor, and all three users share one evaluation path. The risk: that path must give the same values as `setupAddComputation` does today. Check by comparing outputs with `rtol` (threaded results agree only to about 1e-15).

During step 2 the `@cast` commands stay in `src/AtlasUtilities.jl` but call the new functions, and their printing moves into the commands. The whole test suite keeps passing as the check; tests that called `run_*` are switched to the library functions plus CLI-output tests.

### The CycleWalk extension (step 3)

- **Project.toml:** move CycleWalk from `[deps]` to `[weakdeps]`; add `[extensions] AtlasUtilitiesCycleWalkExt = "CycleWalk"`. Test targets include CycleWalk.
- **Stays in the core:** the `WriterSet` type (its `graph` field is `Any`), `writerFields(ws)` (needs no CycleWalk), `Base.show(::WriterSet)`, the string parsers, and empty declarations with docstrings: `function addMapData end`, `function computeWriters end`, `function listWriters end`, `function listWriterDetails end`, `function loadGraph end`.
- **Moves to `ext/AtlasUtilitiesCycleWalkExt/`:** all of `add.jl` (graph building and `GraphSpec`, `resolveFunctions`, the writer checks, `evalWriters*`, label alignment, the provenance header, `addMapData`), the `WriterSet(functions; graph keywords...)` constructor, `computeWriters`, `listWriters`, `listWriterDetails`, `loadGraph`, and `setupAddComputation`'s replacement.
- **One internal hook** is used by `extractMapData` and `mapDataHistograms` when `writers !== nothing`: a core declaration such as `function evalWriterSet end`, with its method in the extension. A non-`nothing` `writers` can only have been built by the extension, so no further check is needed. The hook takes an optional set of fields to compute, so `extractMapData` keeps today's saving of not computing a writer whose output file already exists and is not being overwritten (`src/extract.jl:211`).
- **Error hints:** the core's `__init__` registers `Base.Experimental.register_error_hint(MethodError)` for `addMapData`, `computeWriters`, `listWriters`, `listWriterDetails`, `loadGraph` and the `WriterSet` constructor. When the extension isn't loaded it adds: "needs CycleWalk: run `using CycleWalk` (install with `Pkg.add(\"CycleWalk\")`)".
- **Transition until step 1:** while the commands still live in the core, `atlas add` and `--add` load CycleWalk on demand (`Base.require` on CycleWalk's `PkgId`, as `atlas render` loads its packages today), and `deps/build.jl` adds CycleWalk to the command's environment. Don't reinstall the `atlas` command from this branch before step 1 without that change, or `add` breaks.
- **New tests:** in a subprocess, `using AtlasUtilities` must not load CycleWalk (`Base.get_extension(AtlasUtilities, :AtlasUtilitiesCycleWalkExt) === nothing`, and CycleWalk absent from `Base.loaded_modules`); calling `addMapData` without it shows the hint; with it loaded, results match `pre-refactor`.

### Checks for steps 2 and 3

1. The full test suite passes, with 1 and with 4 threads.
2. On the example atlases in `examples/`, every command's output files and printed text match `pre-refactor`: byte-identical where single-threaded, floats compared with `rtol = 1e-12` where threaded.
3. `using AtlasUtilities` loads without CycleWalk; its load time and package count are recorded against today's 1.3 s and 49 packages (Comonicon is still there until step 5).

## Measurements behind the decisions

Measured 2026-11-26 on macOS with Julia 1.13, warm (after precompiling), in fresh processes.

| What | Packages installed | Load (`using`) | Other |
| --- | --- | --- | --- |
| AtlasUtilities core today, no plotting | 49 (92 with Julia's standard library) | 1.3 s | `atlas --help` 1.5 s, `info` 3.0 s, `summarize-map-data` 5.0 s (most of the gap is first-call compilation) |
| ... of which CycleWalk only | 13 | 0.7 s | Used only by `add` and the writers |
| ... of which Comonicon only (incl. PackageCompiler) | 9 | 0.5 s | Used only by the CLI |
| Plots.jl | 172 | 1.6–2.2 s | Ships FFMPEG: can make video |
| CairoMakie | 247 | 5.2–5.5 s | Ships FFMPEG |
| GLMakie / WGLMakie | 260 / 259 | 4.7 s / 5.2 s | GLMakie shares 243 packages with CairoMakie |
| Shapefile + LibGEOS | 29 | — | Needed with either plotting library |
| Render extension loaded on demand | — | 4.2–4.5 s | Not loaded by any other command, even when installed |

Video of the real NC map (`Data/northCarolinaPrecinct2021.zip`: 2,650 precincts, about 2.0 million vertices), 1200×600 frames:

|  | Full outlines | Simplified to half a pixel (38,200 vertices, visually identical) |
| --- | --- | --- |
| Plots | 1.15 s/frame, ~19 min per 1,000 frames | 0.42 s/frame, ~7 min |
| CairoMakie | 2.99 s/frame, ~50 min | 0.13 s/frame, ~2 min |

Simplifying outlines matters more than the choice of library, so outline simplification goes into the core geometry layer.

## Open questions

- [ ] Is `mapatlas-gui` wanted, and with which features (hover, map data beside the map, linked histograms, side-by-side comparison)? This decides between a GLMakie window, the HTML report, or both.

  Deferred: decide after the plotting branch.
- [ ] Can county outlines be computed without LibGEOS on our NC and OH shapefiles (shared edges cancelling out)? If yes, the LibGEOS extension disappears.
- [x] Which Julia versions does DCC offer? A 1.11 minimum must be installable there.
- [ ] Are the package and tool names final before the first General registration (AtlasUtilities, AtlasCLI; `atlas`, `atlas-plot`, `atlas-gui`)?

  Candidates (packages keep the Atlas prefix, matching the registered AtlasIO):
  - Library: `AtlasUtilities` (current), `AtlasTools`, `AtlasAnalysis`, `AtlasEnsembles`
  - CLI package: `AtlasCLI` (current), `AtlasCommands`, or `<library name>CLI`
  - Commands (avoid a clash with MongoDB's `atlas`): `atlas` (current), `atl`, `atlasjl`, `ratlas`, `mapatlas`; the plot and GUI tools take the same prefix (`atl-plot`, `atl-gui`)

  Decided: the commands are `mapatlas`, `mapatlas-plot` and `mapatlas-gui` (a shell alias can still give `atlas`). Package names are still open.
- [x] Should AtlasCLI run a PrecompileTools workload, so `info` and `summarize-map-data` start close to `--help`'s 1.5 s?

  Decided: yes, added to AtlasCLI after the first branch.
- [x] Does the self-contained HTML report come before or after the Plots work?

  Decided: Plots first; the report follows and reuses its images.
