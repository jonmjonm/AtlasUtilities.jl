# Runs on `Pkg.add` / `Pkg.build("AtlasUtilities")`. Comonicon reads the
# [comonicon] config in Project.toml and installs the `atlas` launcher into
# ~/.julia/bin, compiling a system image (per [comonicon.sysimg]) so the command
# starts fast. Add ~/.julia/bin to your PATH to use it.
using AtlasUtilities
AtlasUtilities.comonicon_install()
