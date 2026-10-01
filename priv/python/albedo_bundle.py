"""Content hash of the packaged python tree.

The remote plugin stages a bundle under this hash, and a detached kernel and
its bridge announce it, so the daemon can tell when a kernel runs older code
than the daemon's own tree.
"""

from __future__ import annotations

import hashlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent


def digest(root: Path = ROOT) -> str:
    """sha256 over every .py file's relative path and bytes, in path order."""
    hasher = hashlib.sha256()
    for path in sorted(root.rglob("*.py")):
        hasher.update(str(path.relative_to(root)).encode())
        hasher.update(path.read_bytes())
    return hasher.hexdigest()
