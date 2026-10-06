"""Programs the kernel puts first on PATH for the model's jobs, each in its
own directory under $ALBEDO_HOME/shims, prepended only where the program it
needs is on the job's PATH. They are written where the kernel runs (only .py
files travel to a remote kernel). robot-docs/shims.md has the measurements.

`nix` (needs nix) runs albedo_nix.py with the kernel's Python: a flake in a jj
workspace is read from its commit instead of copied into the store, and
`nix develop -c` reuses a cached dev shell. ALBEDO_PLAIN_NIX=1 runs nix as is.

`cargo` (needs mbx, jdx's mr-boxington) runs cargo through mbx, so every
checkout of a project shares compiled work: a second checkout of
native/render builds in 2 s instead of 32 s. ALBEDO_NO_MBX=1 runs plain cargo.
For mbx's process only, SDKROOT goes, because mbx names the macOS linker with
`xcrun --sdk $SDKROOT`, which rejects a path such as a nix shell's, and an
unnamed linker leaves every link, build script, and proc macro uncached.
Inside a nix shell (ALBEDO_NIX_ENV, set by albedo_nix.py) CC and CXX go too
when they are the shell's cc and c++ anyway (a shell that picks another
compiler keeps it), so build scripts' C compiles through mbx, which an
explicit CC hides it from, and HOST_CFLAGS names the shell's
compiler-wrapper flags, which no mbx key covers: without it a changed shell
could be served another checkout's stale object.
"""

from __future__ import annotations

import os
import shutil
import sys
from pathlib import Path

CARGO = r"""#!/bin/sh
# albedo's cargo: mbx when it is installed (see albedo_shims.py), else the next
# cargo on PATH.
here=$(cd "$(dirname "$0")" && pwd)
# whether compiler $1 is the $2 on PATH, which a build script runs without it
default() {
  a=$(command -v "$1" 2>/dev/null) && b=$(command -v "$2" 2>/dev/null) || return 1
  a=$(realpath "$a" 2>/dev/null) && b=$(realpath "$b" 2>/dev/null) || return 1
  [ "$a" = "$b" ]
}
if [ -z "${ALBEDO_NO_MBX:-}" ] && mbx=$(command -v mbx); then
  if [ -n "${ALBEDO_NIX_ENV:-}" ]; then
    HOST_CFLAGS="${HOST_CFLAGS:-${CFLAGS:-}} -DALBEDO_NIX_ENV_$ALBEDO_NIX_ENV"
    HOST_CXXFLAGS="${HOST_CXXFLAGS:-${CXXFLAGS:-}} -DALBEDO_NIX_ENV_$ALBEDO_NIX_ENV"
    export HOST_CFLAGS HOST_CXXFLAGS
    if default "${CC:-}" cc; then unset CC; fi
    if default "${CXX:-}" c++; then unset CXX; fi
  fi
  MBX_CARGO_SHIM_MODE=1 MBX_CARGO_SHIM_PATH="$0" exec env -u SDKROOT "$mbx" "$@"
fi
PATH=$(printf %s "$PATH" | tr : '\n' | grep -vxF "$here" | paste -sd: -)
exec cargo "$@"
"""

NIX = r"""#!/bin/sh
# albedo's nix: albedo_nix.py with the kernel's Python, else the next nix on PATH.
here=$(cd "$(dirname "$0")" && pwd)
if [ -z "${ALBEDO_PLAIN_NIX:-}" ] && [ -x "${ALBEDO_SHIMS_PYTHON:-}" ]; then
  exec "$ALBEDO_SHIMS_PYTHON" -E -s "$ALBEDO_SHIMS_LIB/albedo_nix.py" "$here" "$@"
fi
PATH=$(printf %s "$PATH" | tr : '\n' | grep -vxF "$here" | paste -sd: -)
exec nix "$@"
"""

# directory (named for the program a shim needs on PATH) -> (shim, script)
SHIMS = {"nix": ("nix", NIX), "mbx": ("cargo", CARGO)}
_written: set[Path] = set()


def _directory(needs: str) -> Path:
    """The directory of the shim that needs `needs`, written once per kernel."""
    home = os.environ.get("ALBEDO_HOME") or os.path.expanduser("~/.albedo")
    directory = Path(home, "shims", needs)
    if directory not in _written:
        name, script = SHIMS[needs]
        directory.mkdir(parents=True, exist_ok=True)
        shim = directory / name
        if not shim.is_file() or shim.read_text() != script:
            temporary = directory / f".{name}.{os.getpid()}"
            temporary.write_text(script)
            temporary.chmod(0o755)
            temporary.replace(shim)
        _written.add(directory)
    return directory


def prepend(environment: dict[str, str] | None) -> dict[str, str] | None:
    """Return the job environment with only this kernel's shims before real tools.
    Remove inherited shim generations even when their tools are absent."""
    base = environment or os.environ
    path = base.get("PATH", "")
    entries = path.split(os.pathsep)
    # Remove inherited generations before adding this kernel's shims.
    entries = [
        entry
        for entry in entries
        if not (Path(entry).name in SHIMS and Path(entry).parent.name == "shims")
    ]
    path = os.pathsep.join(entries)
    shims = [
        str(_directory(needs))
        for needs in SHIMS
        if shutil.which(needs, path=path) is not None
    ]
    if not shims:
        if environment is None and path == base.get("PATH", ""):
            return None
        return {**base, "PATH": path}
    return {
        **base,
        "PATH": os.pathsep.join([*shims, path]),
        "ALBEDO_SHIMS_PYTHON": sys.executable,
        "ALBEDO_SHIMS_LIB": str(Path(__file__).resolve().parent),
    }
