"""Programs the kernel puts first on PATH for the model's jobs, each in its
own directory under $ALBEDO_HOME/shims, prepended only where the program it
needs is on the job's PATH. They are written where the kernel runs (only .py
files travel to a remote kernel). robot-docs/shims.md has the measurements.

`cargo` (needs mbx, jdx's mr-boxington) runs cargo through mbx, so every
checkout of a project shares compiled work: a second checkout of
native/render builds in 2 s instead of 32 s. ALBEDO_NO_MBX=1 runs plain cargo.
For mbx's process only, SDKROOT goes, because mbx names the macOS linker with
`xcrun --sdk $SDKROOT`, which rejects a path such as a nix shell's, and an
unnamed linker leaves every link, build script, and proc macro uncached.
"""

from __future__ import annotations

import os
import shutil
from pathlib import Path

CARGO = r"""#!/bin/sh
# albedo's cargo: mbx when it is installed (see albedo_shims.py), else the next
# cargo on PATH.
here=$(cd "$(dirname "$0")" && pwd)
if [ -z "${ALBEDO_NO_MBX:-}" ] && mbx=$(command -v mbx); then
  MBX_CARGO_SHIM_MODE=1 MBX_CARGO_SHIM_PATH="$0" exec env -u SDKROOT "$mbx" "$@"
fi
PATH=$(printf %s "$PATH" | tr : '\n' | grep -vxF "$here" | paste -sd: -)
exec cargo "$@"
"""

# directory (named for the program a shim needs on PATH) -> (shim, script)
SHIMS = {"mbx": ("cargo", CARGO)}
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
    """A job's environment with each shim whose program is on its PATH first
    on that PATH; otherwise the environment as given (None inherits)."""
    base = environment or os.environ
    path = base.get("PATH", "")
    entries = path.split(os.pathsep)
    shims = [
        str(_directory(needs))
        for needs in SHIMS
        if shutil.which(needs, path=path) is not None
    ]
    shims = [directory for directory in shims if directory not in entries]
    if not shims:
        return environment
    return {**base, "PATH": os.pathsep.join([*shims, path])}
