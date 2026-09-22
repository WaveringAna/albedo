"""Bounded file-access evidence and before/after diffs for the terminal view.

This is observation, not a sandbox. External processes and native writes may bypass it.
"""
from __future__ import annotations

from collections.abc import Callable
from typing import Protocol, cast
import contextvars
import difflib
import os
import sys

GUARD = contextvars.ContextVar("albedo_trace_guard", default=False)
LIMIT = 128 * 1024

class Trace:
    def __init__(self):
        self.activities: dict[tuple[str, str], dict[str, str]] = {}
        self.before: dict[str, str | None] = {}
        self.truncated: bool = False

    def activity(self, kind: str, target: object) -> None:
        if len(self.activities) >= 64:
            self.truncated = True
        else:
            target = str(target)[:1000]
            self.activities[(kind, target)] = {"kind": kind, "target": target}

    def renamed(self, source: str, destination: str) -> None:
        if source == destination:
            return
        # Atomic editors write a temporary file then replace the real target.
        # The temporary file is not an edit; snapshot the destination before rename.
        self.writing(destination)
        self.before.pop(source, None)

    def writing(self, path: str) -> None:
        if path in self.before:
            return
        if len(self.before) >= 16:
            self.truncated = True
            return
        self.before[path] = snapshot(path)

    def finish(self) -> dict[str, object]:
        token = GUARD.set(True)
        try:
            changes: list[dict[str, str | int]] = []
            for path, before in self.before.items():
                after = snapshot(path)
                if before == after:
                    continue
                if before is None or after is None:
                    changes.append({"path": path[:1000], "kind": "unavailable", "reason": "binary, unreadable, or larger than 128 KiB"})
                    continue
                lines = list(difflib.unified_diff(before.splitlines(True), after.splitlines(True), fromfile=path, tofile=path))
                diff = "".join(lines)
                self.truncated |= len(diff) > 16000
                changes.append({"path": path[:1000], "kind": "diff", "diff": diff[:16000],
                    "added": sum(line.startswith("+") and not line.startswith("+++") for line in lines),
                    "removed": sum(line.startswith("-") and not line.startswith("---") for line in lines)})
            return {"activities": list(self.activities.values()), "changes": changes, "truncated": self.truncated}
        finally:
            GUARD.reset(token)

def snapshot(path: str) -> str | None:
    try:
        if not os.path.exists(path):
            return ""
        if not os.path.isfile(path) or os.path.getsize(path) > LIMIT:
            return None
        with open(path, "rb") as file:
            value = file.read(LIMIT + 1)
        return value.decode("utf-8") if len(value) <= LIMIT and b"\0" not in value else None
    except (OSError, UnicodeError):
        return None

class TracedCapture(Protocol):
    trace: Trace

def install(get_capture: Callable[[], TracedCapture | None]) -> None:
    def audit(event: str, args: tuple[object, ...]) -> None:
        capture = get_capture()
        if capture is None or GUARD.get():
            return
        token = GUARD.set(True)
        try:
            if event == "open" and isinstance(args[0], (str, bytes)):
                path = os.path.abspath(os.fsdecode(args[0]))
                if path == "/proc" or path.startswith("/proc/"):
                    return  # process supervision is harness bookkeeping, not user exploration
                flags = args[2]
                if not isinstance(flags, int):
                    raise TypeError("invalid open flags")
                if flags & (os.O_WRONLY | os.O_RDWR | os.O_CREAT | os.O_TRUNC | os.O_APPEND):
                    capture.trace.writing(path)
                else:
                    capture.trace.activity("read", path)
            elif event in ("os.rename", "os.replace") and len(args) >= 2:
                source, destination = (os.path.abspath(os.fsdecode(path)) for path in args[:2])
                capture.trace.renamed(source, destination)
            elif event in ("os.listdir", "os.scandir"):
                path = os.fsdecode(args[0]) if args else "."
                if path != "/proc" and not path.startswith("/proc/"):
                    capture.trace.activity("list", path)
            elif event == "subprocess.Popen":
                capture.trace.activity("run", " ".join(map(str, cast(list[object] | tuple[object, ...], args[1]))) if isinstance(args[1], (tuple,list)) else args[1])
        except Exception:
            capture.trace.truncated = True
        finally:
            GUARD.reset(token)
    sys.addaudithook(audit)
