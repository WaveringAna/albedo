"""What the daemon's folder browser and project readers need from a remote host.

    albedo_gather.py

reads one JSON request line on stdin and prints one JSON snapshot. The daemon
interprets the snapshot with the same code it uses on its own disk
(albedo/daemon/folders.gleam, albedo/harness/vcs.gleam), so this side only
collects: directory entries, which repository markers exist, the vcs
commands the daemon planned, file sizes, and project files. Everything comes
back in one ssh round trip per question.

Request: `{route, dir, plans, separators, deadline, counted}`, `dir` absolute
and normalised. `route` is list, repo, preview or project, or exists, which
answers `directory` alone.

Snapshot: `{directory, entries: {dir: [[name, dir, modified]]}, exists:
[path], outputs: {key: stdout}, sizes: {path: bytes}, files: {relative:
base64}}`. An output's key is its program and arguments joined by NUL; only
commands that exit 0 within the deadline answer.
"""

from __future__ import annotations

import base64
import json
import os
import stat
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

MARKERS = (".jj", ".git")
SUBDIRECTORIES = 256  # child directories whose entries a preview lists
PROJECT_FILES = 512
PROJECT_BYTES = 8 * 1024 * 1024
FILE_BYTES = 1024 * 1024 + 1  # one past the instruction limit, so it still warns


def child(directory: str, name: str) -> str:
    return "/" + name if directory == "/" else f"{directory}/{name}"


def shown(name: str) -> bool:
    """Names the daemon can show and send back: valid UTF-8."""
    try:
        name.encode()
        return True
    except UnicodeEncodeError:
        return False


def entries(directory: str) -> list[list[object]]:
    try:
        names = os.listdir(directory)
    except OSError:
        return []
    listed: list[list[object]] = []
    for name in filter(shown, names):
        try:
            info = os.stat(child(directory, name))
            listed.append([name, stat.S_ISDIR(info.st_mode), int(info.st_mtime)])
        except OSError:
            listed.append([name, False, 0])
    return listed


def marks(directory: str, exists: list[str]) -> str | None:
    """Record the markers at `directory`; the kind it roots, .jj first."""
    found = None
    for marker in MARKERS:
        path = child(directory, marker)
        if os.path.lexists(path) and (os.path.isfile(path) or os.path.isdir(path)):
            exists.append(path)
            found = found or marker
    return found


def parent(directory: str) -> str | None:
    return None if directory == "/" else os.path.dirname(directory) or "/"


def checkout(directory: str, exists: list[str]) -> tuple[str, str] | None:
    """The nearest enclosing repository: (kind, root)."""
    current: str | None = directory
    while current is not None:
        found = marks(current, exists)
        if found is not None:
            return found[1:], current
        current = parent(current)
    return None


def key(program: str, args: list[str]) -> str:
    return "\0".join([program, *args])


def run(
    command: list, root: str, directory: str, deadline: float
) -> tuple[str, str | None]:
    program, args, at = command
    try:
        done = subprocess.run(
            [program, *args],
            cwd=root if at == "root" else directory,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            timeout=deadline,
        )
    except (OSError, subprocess.TimeoutExpired):
        return key(program, args), None
    output = done.stdout.decode(errors="replace") if done.returncode == 0 else None
    return key(program, args), output


def project(directory: str) -> dict[str, str]:
    """Project instruction files and skills, relative to `directory`."""
    picked: list[str] = []
    for relative in ("", ".agents", ".albedo"):
        base = child(directory, relative) if relative else directory
        try:
            names = sorted(filter(shown, os.listdir(base)))
        except OSError:
            continue
        for name in names:
            if name.lower().endswith(".md") and os.path.isfile(child(base, name)):
                picked.append(f"{relative}/{name}" if relative else name)
    for relative in (".agents/skills", ".albedo/skills"):
        for root, directories, names in os.walk(child(directory, relative)):
            directories.sort()
            for name in sorted(filter(shown, names)):
                path = os.path.join(root, name)
                if os.path.isfile(path) and len(picked) < PROJECT_FILES:
                    picked.append(os.path.relpath(path, directory))
    files: dict[str, str] = {}
    budget = PROJECT_BYTES
    for relative in picked:
        try:
            with open(child(directory, relative), "rb") as handle:
                data = handle.read(min(FILE_BYTES, budget))
        except OSError:
            continue
        budget -= len(data)
        files[relative] = base64.b64encode(data).decode()
        if budget <= 0:
            break
    return files


def gather(request: dict) -> dict[str, object]:
    route, directory = request["route"], request["dir"]
    snapshot: dict[str, object] = {"directory": os.path.isdir(directory)}
    if not snapshot["directory"] or route == "exists":
        return snapshot
    if route == "project":
        snapshot["files"] = project(directory)
        return snapshot
    exists: list[str] = []
    listed = {directory: entries(directory)}
    snapshot.update(entries=listed, exists=exists)
    if route == "list":
        for name, is_directory, _ in listed[directory]:
            if is_directory:
                marks(child(directory, str(name)), exists)
        return snapshot
    found = checkout(directory, exists)
    if route == "preview":
        children = [
            child(directory, str(name))
            for name, is_directory, _ in listed[directory]
            if is_directory and not str(name).startswith(".")
        ]
        for path in children[:SUBDIRECTORIES]:
            listed[path] = entries(path)
    if found is None:
        return snapshot
    kind, root = found
    deadline = float(request.get("deadline", 2.0))
    plan = request.get("plans", {}).get(kind, [])
    with ThreadPoolExecutor(max_workers=max(1, len(plan))) as pool:
        answers = dict(pool.map(lambda c: run(c, root, directory, deadline), plan))
    outputs = {k: v for k, v in answers.items() if v is not None}
    snapshot["outputs"] = outputs
    if route == "preview":
        tracked = next((c for c in plan if c[2] == "dir"), None)
        separator = request.get("separators", {}).get(kind, "\n")
        listing = outputs.get(key(tracked[0], tracked[1])) if tracked else None
        sizes: dict[str, int] = {}
        for relative in (listing or "").split(separator)[
            : int(request.get("counted", 0))
        ]:
            if not relative:
                continue
            path = child(directory, relative)
            try:
                info = os.stat(path)
            except OSError:
                continue
            if stat.S_ISREG(info.st_mode):
                sizes[path] = info.st_size
        snapshot["sizes"] = sizes
    return snapshot


def main() -> int:
    request = json.loads(sys.stdin.readline())
    print(json.dumps(gather(request)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
