# AtlasUtilities

Command-line utilities for working with redistricting **Atlas** files (the map
container produced by the Quantifying Gerrymandering tooling; see the
[Atlas format](https://github.com/jonmjonm/AtlasIO.jl/blob/main/atlas_format.md)).

The package installs a single `atlas` command with two subcommands:

| Command | What it does |
|---------|--------------|
| `atlas info <atlas> [--extract-script]` | Print an atlas file's header — the metadata line and the atlas-parameter line. The bulky embedded `script` source is never printed; `--extract-script` writes it to its own file instead. |
| `atlas reorder <A1> <A2> [<graph.json>] [--first-map] [--quiet]` | Relabel district numbers across every map in atlas `A1` so consecutive maps stay as consistent as possible, writing the result to `A2`. |

Run `atlas --help`, `atlas info --help`, or `atlas reorder --help` for full
option details.

## Installation

`atlas` is built with [Comonicon](https://comonicon.org). Installing the package
runs a build step that drops an `atlas` launcher into `~/.julia/bin/` and
compiles a system image so the command starts fast.

### Install from GitHub

Install directly from the GitHub repository with Julia's package manager — this
clones the package, resolves its dependencies from the General registry, and runs
the build step that installs the `atlas` command:

```julia
julia -e 'using Pkg; Pkg.add(url="https://github.com/jonmjonm/AtlasUtilities.jl")'
```

Equivalently, from the Julia REPL package mode (press `]`):

```julia-repl
pkg> add https://github.com/jonmjonm/AtlasUtilities.jl
```

To pin a specific version or branch, append `#tag`/`#branch` to the URL (e.g.
`…/AtlasUtilities.jl#v0.1.0`). To update later, `Pkg.update("AtlasUtilities")`.

Then add `~/.julia/bin` to your `PATH` (one time):

```bash
echo 'export PATH="$HOME/.julia/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc
```

Now the command is available:

```bash
atlas info some_atlas.jsonl.gz
```

> The first install compiles a system image and takes a few minutes. All
> dependencies (including `AtlasIO`) resolve from the Julia General registry.

### Installing from a local clone (development)

```bash
git clone https://github.com/jonmjonm/AtlasUtilities.jl
cd AtlasUtilities.jl
julia --project -e 'using Pkg; Pkg.instantiate()'
julia --project deps/build.jl        # installs the `atlas` launcher + sysimg
```

## Usage

### `atlas info`

```bash
atlas info examples/cycleWalk_ct_metadata.jsonl.gz
```

Sample atlases ship in [`examples/`](examples) (see [Example atlases](#example-atlases)
below). The command above prints the header metadata and the atlas parameters
(alphabetized, nested values indented). The `cycleWalk_ct_metadata` atlas embeds
its run script in the header — pull it out to its own file with:

```bash
atlas info examples/cycleWalk_ct_metadata.jsonl.gz --extract-script
```

The script is written to the filename recorded in the header's `script_name`
entry (falling back to `extracted_script.jl`).

### `atlas reorder`

```bash
atlas reorder examples/demo_grid_4x4.jsonl.gz reordered.jsonl.gz
```

The `demo_grid_4x4` demo holds the same partition in every map but with the
district labels permuted; reorder canonicalizes them so map-to-map labels stay
consistent.

- `--first-map` — align every map to map 1 (the anchor) instead of to its
  predecessor.
- `--quiet` — suppress the progress bar.
- A third positional argument is an optional dual-graph hierarchy
  (NetworkX node-link JSON), **required** for multiscale/hierarchical atlases
  whose per-map node sets vary. The `demo_multiscale` example ships with its
  graph:

  ```bash
  atlas reorder examples/demo_multiscale.jsonl.gz out.jsonl.gz \
      examples/demo_multiscale_graph.json
  ```

  The real NC multiscale atlases use the precinct graph as their dual graph:

  ```bash
  atlas reorder examples/atlas_ordered.jsonl.gz out.jsonl.gz Data/NC_pct21.json
  ```

  See [`reorder.md`](reorder.md) for the full specification.

Map parsing is threaded across the threads Julia was started with. Because the
installed command runs on the Comonicon system image, control the thread count
with the `JULIA_NUM_THREADS` environment variable, e.g.:

```bash
JULIA_NUM_THREADS=8 atlas reorder input.jsonl.gz reordered.jsonl.gz
```

## Example atlases

All files below live in [`examples/`](examples) and are gzip-compressed.

| File | Maps | Description |
|------|-----:|-------------|
| `cycleWalk_ct_metadata.jsonl.gz` | few | A real CycleWalk **CT** run whose header embeds its run script — use it with `atlas info --extract-script`. |
| `demo_grid_4x4.jsonl.gz` | 6 | Toy 4×4 grid, 4 districts, same partition with permuted labels — shows `atlas reorder` canonicalization. |
| `demo_grid_3x3.jsonl.gz` | 4 | Toy 3×3 grid, 3 row districts, permuted labels across four maps. |
| `demo_multiscale.jsonl.gz` (+ `demo_multiscale_graph.json`) | 3 | Tiny mixed-resolution atlas + its dual graph — shows graph-based reorder. |
| `atlas_ordered.jsonl.gz`, `atlas_measureID12.jsonl.gz` | 100 | **NC** multiscale atlases (county/precinct levels, 14 districts). Reorder with `Data/NC_pct21.json` as the dual graph. |
| `cycleWalk_v0p2_thread3_walkVSinternal_0.01_gamma0.5.jsonl.gz`, `…_iso0.15.jsonl.gz` | 100 | **NC** single-resolution CycleWalk atlases (14 districts). Reorder directly, no graph needed. |

The toy grid/multiscale demos are generated by
[`examples/make_demos.jl`](examples/make_demos.jl). The `demo_grid_*` and
`demo_multiscale` files are self-contained. The four **NC** atlases are the first
100 maps of full CycleWalk runs (the complete multi-hundred-MB atlases live in the
Duke GitLab `Data/` directory); they were sliced with:

```bash
gzip -dc full_atlas.jsonl.gz | head -n 103 | gzip -c > examples/slice.jsonl.gz
```

(3 header lines + 100 map lines = 103.)

## Running from source without installing

You can also drive the commands directly through the package without installing
the launcher:

```bash
julia --project=. --threads=8 -e 'using AtlasUtilities; AtlasUtilities.command_main()' -- \
    reorder input.jsonl.gz reordered.jsonl.gz --quiet
```

## Development

```bash
julia --project=. -e 'using Pkg; Pkg.test()'
```

The suite covers the reorder logic (`test/runtests.jl`) and the info formatting
and extraction (`test/infoTests.jl`).

## Repository layout

```
src/AtlasUtilities.jl   module + Comonicon @cast subcommands (the CLI surface)
src/info.jl             `atlas info` implementation
src/reorder.jl          `atlas reorder` implementation
deps/build.jl           Comonicon install (launcher + sysimg)
deps/precompile.jl      exercises both subcommands while the sysimg is built
test/                   test suite
examples/               sample atlases (+ make_demos.jl that generates them)
reorder.md              reorder algorithm specification
```
