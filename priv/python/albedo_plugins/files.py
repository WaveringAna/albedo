"""Bounded reads, exact edits, and ripgrep-backed search over workspace files.

Every external command runs through the supervised `bash` job plugin, so this
module never spawns a process of its own and every child stays in a job's group.
"""
from __future__ import annotations

import difflib
import fnmatch
import json
import os
import re
import shlex
import stat
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Sequence

from albedo_api import PythonApi
from albedo_plugins import bash as jobs

READ_LIMIT = 16_000
SEARCH_TIMEOUT = 30
LINE_WIDTH = 160
CANDIDATES = 4
LISTED = 10
CONTEXT = 2
PREVIEW_LINES = 2


@dataclass(frozen=True)
class Match:
    path: str
    line: int
    text: str

    def __str__(self) -> str:
        return f"{self.path}:{self.line}: {self.text}"

    def to_dict(self) -> dict[str, str | int]:
        return {"path": self.path, "line": self.line, "text": self.text}


class Rows(list):
    """A list that prints one row per line, so a REPL result reads like output."""

    def __init__(self, items: Iterable[object] = (), truncated: bool = False) -> None:
        super().__init__(items)
        self.truncated = truncated

    def __repr__(self) -> str:
        if not self:
            return "[]"
        body = "\n".join(str(item) for item in self)
        return body + ("\n[truncated]" if self.truncated else "")

    __str__ = __repr__


async def _run(command: str) -> tuple[int | None, str]:
    """One supervised shell job, awaited to completion, with its bounded output."""
    job = jobs.bash(command, timeout=SEARCH_TIMEOUT)
    await job
    return job.returncode, job.tail(jobs.preview_limit)


def _numbered(number: int, lines: Sequence[str]) -> str:
    text = lines[number - 1] if 0 < number <= len(lines) else ""
    return f"{number:>6} | {text[:LINE_WIDTH]}"


class Files:
    """Workspace file access with the diagnostics an exact edit needs."""

    def read(self, path: str, *, start_line: int = 1, end_line: int | None = None,
             limit: int = READ_LIMIT) -> str:
        """Numbered lines from one file. The numbers are what `edit(line_hint=)` takes."""
        if start_line < 1 or (end_line is not None and end_line < start_line) or not 0 < limit <= 200_000:
            raise ValueError("start_line >= 1, end_line >= start_line, 0 < limit <= 200000")
        target = Path(path).expanduser()
        data = target.read_bytes()
        lines = data.decode("utf-8", errors="replace").splitlines()
        last = len(lines) if end_line is None else min(end_line, len(lines))
        body, used = [], 0
        for number in range(start_line, last + 1):
            row = _numbered(number, lines)
            used += len(row) + 1
            if used > limit:
                body.append(f"[{last - number + 1} more lines; read again with start_line={number}]")
                break
            body.append(row)
        if start_line > len(lines):
            return f"[{path} has {len(lines)} lines; nothing at line {start_line}]"
        return "\n".join(body)

    def ls(self, path: str = ".", pattern: str | None = None, *, hidden: bool = False) -> Rows:
        """One directory, directories suffixed with `/`."""
        directory = Path(path).expanduser()
        entries = []
        for entry in sorted(directory.iterdir(), key=lambda item: item.name):
            if not hidden and entry.name.startswith("."):
                continue
            if pattern and not fnmatch.fnmatch(entry.name, pattern):
                continue
            entries.append(entry.name + ("/" if entry.is_dir() else ""))
        return Rows(entries)

    async def find(self, pattern: str, path: str = ".", *, glob: str | Sequence[str] | None = None,
                   max_results: int = 50, literal: bool = False,
                   case_sensitive: bool | None = None, hidden: bool = False) -> Rows:
        """Content search through ripgrep when it is installed, else pure Python."""
        target = Path(path).expanduser()
        if not _which("rg"):
            return _fallback_find(pattern, target, glob, max_results, literal, case_sensitive, hidden)
        flags = ["--json"]
        if literal:
            flags.append("-F")
        if case_sensitive is True:
            flags.append("-s")
        elif case_sensitive is False:
            flags.append("-i")
        if hidden:
            flags.append("--hidden")
        for value in ([glob] if isinstance(glob, str) else list(glob or [])):
            flags += ["-g", value]
        command = " ".join(shlex.quote(part) for part in
                           ["rg", *flags, "-e", pattern, str(target)])
        status, output = await _run(f"{command} | head -n {max(1, max_results) * 4}")
        if status not in (0, 1, None) and not output.strip():
            raise RuntimeError(f"search failed: {output.strip()[:400]}")
        results = []
        for line in output.splitlines():
            try:
                event = json.loads(line)
            except ValueError:
                continue
            if event.get("type") != "match":
                continue
            data = event["data"]
            results.append(Match(data["path"]["text"], data["line_number"],
                                 data["lines"]["text"].rstrip("\r\n")[:LINE_WIDTH * 4]))
            if len(results) >= max_results:
                return Rows(results, truncated=True)
        return Rows(results)

    async def paths(self, pattern: str | None = None, path: str = ".", *,
                    glob: str | None = None, max_results: int = 100, hidden: bool = False) -> Rows:
        """File names, not contents; the same ripgrep-or-Python split."""
        target = Path(path).expanduser()
        if not _which("rg"):
            return _fallback_paths(pattern, target, glob, max_results, hidden)
        flags = ["--files"]
        if hidden:
            flags.append("--hidden")
        if glob:
            flags += ["-g", glob]
        command = " ".join(shlex.quote(part) for part in ["rg", *flags, str(target)])
        _, output = await _run(command)
        matcher = re.compile(re.escape(pattern), re.IGNORECASE) if pattern else None
        found = [line for line in output.splitlines()
                 if line and (matcher is None or matcher.search(line))]
        return Rows(found[:max_results], truncated=len(found) > max_results)

    def edit(self, path: str, old_str: str, new_str: str, line_hint: int | None = None) -> str:
        """Replace one exact, unique string. A miss reports what is actually there."""
        if not old_str:
            raise ValueError("old_str must be non-empty")
        if line_hint is not None and (isinstance(line_hint, bool) or not isinstance(line_hint, int)):
            raise ValueError(f"line_hint must be a line number, not {type(line_hint).__name__}")
        target = Path(path).expanduser()
        if not target.exists():
            raise FileNotFoundError(_missing(target, path))
        target = target.resolve()
        snapshot = _snapshot(target)
        content = snapshot[0].decode("utf-8")
        found = _occurrences(content, old_str)
        if not found:
            closest = _closest(content, old_str)
            raise ValueError(f"string not found in {path}" + (f"\n{closest}" if closest else ""))
        chosen = _choose(content, old_str, found, line_hint, path)
        replacement = (content[:chosen.index] + new_str + content[chosen.index + len(old_str):]).encode("utf-8")
        _replace(target, snapshot, replacement)
        return f"Edited {target}"

    def write(self, path: str, content: str) -> str:
        """Create or replace a whole file. Use `edit` to change part of one."""
        target = Path(path).expanduser()
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8")
        return f"Wrote {target.resolve()} ({len(content.encode())} bytes)"


def _which(name: str) -> str | None:
    for directory in os.environ.get("PATH", "").split(os.pathsep):
        candidate = Path(directory)/name
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    return None


def _fallback_find(pattern, path: Path, glob, max_results, literal, case_sensitive, hidden) -> Rows:
    flags = 0 if case_sensitive else re.IGNORECASE
    matcher = re.compile(re.escape(pattern) if literal else pattern, flags)
    globs = [glob] if isinstance(glob, str) else list(glob or [])
    results = []
    for file in _walk(path, hidden):
        if globs and not any(fnmatch.fnmatch(str(file), value) or fnmatch.fnmatch(file.name, value) for value in globs):
            continue
        try:
            text = file.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for number, line in enumerate(text.splitlines(), 1):
            if matcher.search(line):
                results.append(Match(str(file), number, line[:LINE_WIDTH * 4]))
                if len(results) >= max_results:
                    return Rows(results, truncated=True)
    return Rows(results)


def _fallback_paths(pattern, path: Path, glob, max_results, hidden) -> Rows:
    matcher = re.compile(re.escape(pattern), re.IGNORECASE) if pattern else None
    found = [str(file) for file in _walk(path, hidden)
             if (glob is None or fnmatch.fnmatch(file.name, glob))
             and (matcher is None or matcher.search(str(file)))]
    return Rows(found[:max_results], truncated=len(found) > max_results)


def _walk(path: Path, hidden: bool):
    if path.is_file():
        yield path
        return
    for root, directories, names in os.walk(path):
        if not hidden:
            directories[:] = [name for name in directories if not name.startswith(".")]
            names = [name for name in names if not name.startswith(".")]
        for name in sorted(names):
            yield Path(root)/name


def _snapshot(target: Path) -> tuple[bytes, tuple[int, int, int, int, int]]:
    """Bytes plus identity: an edit refuses to publish over a concurrent change."""
    for _ in range(3):
        before = target.stat()
        data = target.read_bytes()
        after = target.stat()
        identity = (after.st_dev, after.st_ino, stat.S_IMODE(after.st_mode), after.st_size, after.st_mtime_ns)
        if identity == (before.st_dev, before.st_ino, stat.S_IMODE(before.st_mode), before.st_size, before.st_mtime_ns):
            return data, identity
    raise ValueError(f"file changed while reading {target}; refusing to edit it")


def _replace(target: Path, snapshot: tuple[bytes, tuple[int, int, int, int, int]], replacement: bytes) -> None:
    descriptor, name = tempfile.mkstemp(dir=target.parent, prefix=f".{target.name}.", suffix=".tmp")
    temporary = Path(name)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            os.fchmod(stream.fileno(), snapshot[1][2])
            stream.write(replacement)
            stream.flush()
            os.fsync(stream.fileno())
        if _snapshot(target) != snapshot:
            raise ValueError(f"file changed while editing {target}; refusing to overwrite concurrent changes")
        os.replace(temporary, target)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


@dataclass(frozen=True)
class _Occurrence:
    index: int
    start_line: int
    end_line: int

    @property
    def label(self) -> str:
        return str(self.start_line) if self.start_line == self.end_line else f"{self.start_line}-{self.end_line}"


def _occurrences(content: str, needle: str) -> list[_Occurrence]:
    found, span, start = [], needle.count("\n") + 1, 0
    while True:
        index = content.find(needle, start)
        if index < 0:
            return found
        first = content.count("\n", 0, index) + 1
        found.append(_Occurrence(index, first, first + span - 1))
        start = index + len(needle)


def _choose(content: str, old_str: str, found: list[_Occurrence], line_hint: int | None, path: str) -> _Occurrence:
    if len(found) == 1:
        return found[0]
    listed = ", ".join(one.label for one in found[:LISTED]) + (f", ... ({len(found)} total)" if len(found) > LISTED else "")
    if line_hint is None:
        raise ValueError(
            f"found {len(found)} occurrences in {path}: lines {listed}. Nothing was changed. "
            "Retry with line_hint=<a line inside the range you want>, or widen old_str until it is unique.\n"
            + _candidates(content, found))
    inside = next((one for one in found if one.start_line <= line_hint <= one.end_line), None)
    if inside is None:
        raise ValueError(
            f"line_hint={line_hint} is inside none of the {len(found)} occurrences in {path}: lines {listed}. "
            f"Nothing was changed.\n{_candidates(content, found)}")
    return inside


def _candidates(content: str, found: list[_Occurrence]) -> str:
    lines = content.splitlines()
    blocks = []
    for position, occurrence in enumerate(found[:CANDIDATES], 1):
        matched = occurrence.end_line - occurrence.start_line + 1
        preview = min(matched, PREVIEW_LINES)
        first = max(1, occurrence.start_line - CONTEXT)
        last = min(len(lines), occurrence.end_line + CONTEXT)
        body = [_numbered(number, lines) for number in range(first, occurrence.start_line)]
        body += [_numbered(number, lines) for number in range(occurrence.start_line, occurrence.start_line + preview)]
        if matched > preview:
            body.append(f"{'...':>6} | ({matched - preview} further matching lines)")
        body += [_numbered(number, lines) for number in range(occurrence.end_line + 1, last + 1)]
        blocks.append(f"candidate {position} of {len(found)}: lines {occurrence.label}\n" + "\n".join(body))
    if len(found) > CANDIDATES:
        blocks.append(f"... {len(found) - CANDIDATES} further occurrences not shown")
    return "\n\n".join(blocks)


def _closest(content: str, needle: str) -> str:
    lines, needle_lines = content.splitlines(), needle.splitlines()
    head = next((line.strip() for line in needle_lines if line.strip()), "")
    if not lines or not head:
        return ""
    ranked = sorted(((difflib.SequenceMatcher(None, head, line.strip(), autojunk=False).ratio(), index)
                     for index, line in enumerate(lines) if line.strip()), reverse=True)[:12]
    width = max(1, len(needle_lines))
    scored = []
    for _, start in ranked:
        end = min(len(lines), start + width)
        current = "\n".join(lines[start:end]).strip()
        scored.append((difflib.SequenceMatcher(None, needle.strip(), current, autojunk=False).ratio(), start, end))
    blocks = []
    for score, start, end in sorted(scored, reverse=True):
        if score < 0.25:
            continue
        body = "\n".join(_numbered(number + 1, lines) for number in range(start, end))
        blocks.append(f"closest candidate lines {start + 1}-{end} (similarity {score:.0%}):\n{body}")
        if len(blocks) == 3:
            break
    return "\n\n".join(blocks)


def _missing(target: Path, original: str) -> str:
    message = f"{original} not found (cwd: {Path.cwd()})"
    parent = target.parent
    if not parent.is_dir():
        return message
    close = difflib.get_close_matches(target.name, [entry.name for entry in parent.iterdir()], n=3, cutoff=0.35)
    return message + (f"; nearby paths: {', '.join(str(parent/name) for name in close)}" if close else "")


def setup(api: PythonApi) -> dict[str, object]:
    return {"files": Files()}
