"""Bounded file-access evidence and before/after diffs for the terminal view.

This is observation, not a sandbox. External processes and native writes may bypass it.
"""

from __future__ import annotations

from collections.abc import Callable, Iterator
from typing import Protocol, cast
import albedo_shell
import contextlib
import contextvars
import difflib
import os
import shlex
import sys

GUARD = contextvars.ContextVar("albedo_trace_guard", default=False)
LIMIT = 128 * 1024


@contextlib.contextmanager
def unobserved() -> Iterator[None]:
    """Harness bookkeeping inside this block, and tasks created in it, stay out of the trace."""
    token = GUARD.set(True)
    try:
        yield
    finally:
        GUARD.reset(token)


def text(value: object) -> str:
    return (
        os.fsdecode(value)
        if isinstance(value, (str, bytes, os.PathLike))
        else str(value)
    )


def command(args: object) -> str:
    """The command as a person would type it: no `sh -c` wrapper, no store path on argv[0]."""
    if not isinstance(args, (list, tuple)):
        return text(args)
    argv = [text(arg) for arg in args]
    if not argv:
        return ""
    script = albedo_shell.shell_script(argv)
    if script is not None:
        return script
    name = os.path.basename(argv[0]) if os.path.isabs(argv[0]) else argv[0]
    return shlex.join([name, *argv[1:]])


class Trace:
    def __init__(self):
        self.activities: dict[tuple[str, str], dict[str, str]] = {}
        self.before: dict[str, str | None] = {}
        self.truncated: bool = False
        self.sealed: bool = False

    def activity(self, kind: str, target: object) -> None:
        if self.sealed:
            return
        if len(self.activities) >= 64:
            self.truncated = True
        else:
            target = str(target)[:1000]
            self.activities[(kind, target)] = {"kind": kind, "target": target}

    def renamed(self, source: str, destination: str) -> None:
        if self.sealed or source == destination:
            return
        # Atomic editors write a temporary file then replace the real target.
        # The temporary file is not an edit; snapshot the destination before rename.
        self.writing(destination)
        self.before.pop(source, None)

    def writing(self, path: str) -> None:
        if self.sealed or path in self.before:
            return
        if len(self.before) >= 16:
            self.truncated = True
            return
        self.before[path] = snapshot(path)

    def finish(self) -> dict[str, object]:
        if self.sealed:
            raise RuntimeError("trace is already sealed")
        self.sealed = True
        with unobserved():
            changes: list[dict[str, str | int]] = []
            for path, before in self.before.items():
                after = snapshot(path)
                if before == after:
                    continue
                if before is None or after is None:
                    changes.append(
                        {
                            "path": path[:1000],
                            "kind": "unavailable",
                            "reason": "binary, unreadable, or larger than 128 KiB",
                        }
                    )
                    continue
                lines = list(
                    difflib.unified_diff(
                        before.splitlines(True),
                        after.splitlines(True),
                        fromfile=path,
                        tofile=path,
                    )
                )
                diff = "".join(lines)
                self.truncated |= len(diff) > 16000
                changes.append(
                    {
                        "path": path[:1000],
                        "kind": "diff",
                        "diff": diff[:16000],
                        "added": sum(
                            line.startswith("+") and not line.startswith("+++")
                            for line in lines
                        ),
                        "removed": sum(
                            line.startswith("-") and not line.startswith("---")
                            for line in lines
                        ),
                    }
                )
            return {
                "activities": [
                    activity.copy() for activity in self.activities.values()
                ],
                "changes": changes,
                "truncated": self.truncated,
            }

    def release(self) -> None:
        if not self.sealed:
            raise RuntimeError("trace must be sealed before release")
        self.before.clear()
        self.activities.clear()


def snapshot(path: str) -> str | None:
    try:
        if not os.path.exists(path):
            return ""
        if not os.path.isfile(path) or os.path.getsize(path) > LIMIT:
            return None
        with open(path, "rb") as file:
            value = file.read(LIMIT + 1)
        return (
            value.decode("utf-8")
            if len(value) <= LIMIT and b"\0" not in value
            else None
        )
    except (OSError, UnicodeError):
        return None


class TracedCapture(Protocol):
    trace: Trace


def _no_capture() -> None:
    return None


current: Callable[[], TracedCapture | None] = _no_capture


def note(kind: str, target: str) -> None:
    """Record what a harness tool did for the running cell, as it was asked
    for: the command run() started, the pattern files.find searched."""
    capture = current()
    if capture is not None:
        capture.trace.activity(kind, target)


def install(get_capture: Callable[[], TracedCapture | None]) -> None:
    global current
    current = get_capture

    def audit(event: str, args: tuple[object, ...]) -> None:
        capture = get_capture()
        if capture is None or capture.trace.sealed or GUARD.get():
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
                if flags & (
                    os.O_WRONLY | os.O_RDWR | os.O_CREAT | os.O_TRUNC | os.O_APPEND
                ):
                    capture.trace.writing(path)
                else:
                    capture.trace.activity("read", path)
            elif event in ("os.rename", "os.replace") and len(args) >= 2:
                source, destination = (
                    os.path.abspath(os.fsdecode(cast(str | bytes, path)))
                    for path in args[:2]
                )
                capture.trace.renamed(source, destination)
            elif event in ("os.listdir", "os.scandir"):
                path = os.fsdecode(cast(str | bytes, args[0])) if args else "."
                if path != "/proc" and not path.startswith("/proc/"):
                    capture.trace.activity("list", path)
            elif event == "subprocess.Popen":
                capture.trace.activity("run", command(args[1]))
        except Exception:
            if not capture.trace.sealed:
                capture.trace.truncated = True
        finally:
            GUARD.reset(token)

    sys.addaudithook(audit)
