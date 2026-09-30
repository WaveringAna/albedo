"""One scratch directory per test process, removed when the process exits.

Every Python suite works inside ``<root>/<name>-<pid>``, where root is
``$ALBEDO_TEST_TMP`` or ``/tmp/albedo-tests``. Claiming it points tempfile's
default directory and ``TMPDIR`` there, so daemons, their kernels and any
temporary directory a test forgets are removed together instead of piling up in
/tmp or in each nix shell's own TMPDIR. A run that died before cleaning up is
swept by the next one. The root is fixed rather than taken from TMPDIR, so
locks under it hold across shells and unix socket paths below it stay short.
"""

import atexit
import os
from pathlib import Path
import shutil
import tempfile

ROOT = Path(os.environ.get("ALBEDO_TEST_TMP", "/tmp/albedo-tests"))


def claim(name: str) -> Path:
    """This process's scratch directory, created on first use."""
    path = ROOT / f"{name}-{os.getpid()}"
    if tempfile.tempdir == str(path):
        return path
    ROOT.mkdir(parents=True, exist_ok=True)
    sweep()
    path.mkdir(exist_ok=True)
    tempfile.tempdir = str(path)
    os.environ["TMPDIR"] = str(path)
    atexit.register(shutil.rmtree, path, ignore_errors=True)
    return path


def sweep() -> None:
    """Remove the directories of test processes that no longer exist."""
    for entry in ROOT.iterdir():
        pid = entry.name.rpartition("-")[2]
        if entry.is_dir() and pid.isdigit() and not alive(int(pid)):
            shutil.rmtree(entry, ignore_errors=True)


def alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True
