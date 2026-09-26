"""Bounded reads, exact edits, and ripgrep-backed search over workspace files.

Every external command runs through the supervised `run` job plugin, so this
module never spawns a process of its own and every child stays in a job's group.
"""
from __future__ import annotations

import asyncio
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
from collections.abc import Awaitable, Callable, Generator
from typing import Generic, Iterable, Sequence, TypeVar

from albedo_api import PythonApi, ReadyList, Text
import albedo_trace
from albedo_plugins import run as jobs

READ_LIMIT = 16_000
SEARCH_TIMEOUT = 30
LINE_WIDTH = 160
CANDIDATES = 4
LISTED = 10
CONTEXT = 2
PREVIEW_LINES = 2


@dataclass(frozen=True)
class Match:
    """One matching line, or with `context=` a surrounding line that prints
    grep-style as `path-line- text`."""
    path: str
    line: int
    text: str
    context: bool = False

    def __str__(self) -> str:
        mark = "-" if self.context else ":"
        return f"{self.path}{mark}{self.line}{mark} {self.text}"

    def to_dict(self) -> dict[str, str | int | bool]:
        fields: dict[str, str | int | bool] = {"path": self.path, "line": self.line, "text": self.text}
        if self.context:
            fields["context"] = True
        return fields


class Rows(ReadyList):
    """A list that prints one row per line, so a REPL result reads like output.
    Like Text, it may be awaited or used directly."""

    def __init__(self, items: Iterable[object] = (), truncated: bool = False) -> None:
        super().__init__(items)
        self.truncated = truncated

    def __repr__(self) -> str:
        if not self:
            return "[]"
        body = "\n".join(str(item) for item in self)
        return body + ("\n[truncated]" if self.truncated else "")

    __str__ = __repr__


Result = TypeVar("Result")


class Search(Generic[Result]):
    """Work that runs a supervised job, so its result exists only once awaited:
    `Search[Rows]` awaits to Rows. Using it without `await` explains that
    instead of printing a coroutine."""

    def __init__(self, call: str, run: Callable[[], Awaitable[Result]], result: str = "rows") -> None:
        self._call = call
        self._run = run
        self._result = result

    def __await__(self) -> Generator[object, None, Result]:
        return self._run().__await__()

    def __getitem__(self, index: object) -> "Search[Result]":
        """`await files.find(...)[:10]` slices before it awaits; apply the
        slice to the rows instead of failing on precedence."""
        async def run() -> object:
            rows = await self._run()
            picked = rows[index]  # type: ignore[index]
            if isinstance(rows, Rows) and isinstance(index, slice):
                return Rows(picked, truncated=rows.truncated)
            return picked
        return Search(self._call, run, self._result)  # type: ignore[arg-type]

    def _unawaited(self) -> TypeError:
        return TypeError(f"{self._call}(...) runs in the background; "
                         f"use `await {self._call}(...)` to get its {self._result}")

    def __repr__(self) -> str:
        return f"<{self._call}(...) has not run: use `await {self._call}(...)` for its {self._result}>"

    __str__ = __repr__

    def __iter__(self):
        raise self._unawaited()

    def __len__(self) -> int:
        raise self._unawaited()


async def _run(command: str) -> tuple[int | None, str]:
    """One supervised shell job, awaited to completion, with its bounded output.
    The plugin's own work, so neither traced as the cell's command nor refused."""
    job = jobs.start(["/bin/sh", "-c", command], SEARCH_TIMEOUT, traced=False)
    try:
        await job
        return job.exit_code, job.tail(jobs.preview_limit)
    except asyncio.CancelledError:
        await job.stop()
        raise
    finally:
        if job.exit_code is not None or job.timed_out or job.termination is not None:
            jobs.forget(job)


def _numbered(number: int, lines: Sequence[str]) -> str:
    text = lines[number - 1] if 0 < number <= len(lines) else ""
    return f"{number:>6} | {text[:LINE_WIDTH]}"


class Files:
    """Workspace file access with the diagnostics an exact edit needs."""

    def read(self, path: str, start_line: int = 1, end_line: int | None = None, *,
             limit: int | None = None, max_chars: int = READ_LIMIT) -> Text:
        """Numbered lines from start_line through end_line, at most `limit` lines.

        `limit` counts lines. `max_chars` is a separate character budget (at
        most 200000) that keeps a huge window from flooding the context; when it
        stops a read early, the result says so and names the line to resume
        from. Lines are never shortened. The numbers are what `edit(line_hint=)`
        takes.
        """
        if start_line < 1 or (end_line is not None and end_line < start_line) \
                or (limit is not None and limit < 1) or not 0 < max_chars <= 200_000:
            raise ValueError("start_line >= 1, end_line >= start_line, limit >= 1 line, "
                             "0 < max_chars <= 200000")
        target = Path(path).expanduser()
        if not target.is_file():
            if target.is_dir():
                raise IsADirectoryError(f"{path} is a directory; files.ls({path!r}) lists it")
            raise FileNotFoundError(_missing(target, path))
        lines = target.read_bytes().decode("utf-8", errors="replace").splitlines()
        if start_line > len(lines):
            return Text(f"[{path} has {len(lines)} lines; nothing at line {start_line}]")
        requested = len(lines) if end_line is None else min(end_line, len(lines))
        last = requested if limit is None else min(requested, start_line + limit - 1)
        body, used = [], 0
        for number in range(start_line, last + 1):
            row = f"{number:>6} | {lines[number - 1]}"
            if used + len(row) + 1 > max_chars:
                if not body:
                    retry = (
                        f"read it alone with start_line={number}, end_line={number}, max_chars={len(row) + 1}"
                        if len(row) + 1 <= 200_000 else "it exceeds the 200000-character maximum"
                    )
                    body.append(f"[line {number} is {len(row)} characters with its number, over "
                                f"max_chars={max_chars}; {retry}]")
                else:
                    body.append(f"[stopped at max_chars={max_chars} characters; lines {number}-{last} "
                                f"not shown; read again with start_line={number}, or raise max_chars]")
                break
            used += len(row) + 1
            body.append(row)
        else:
            if last < requested:
                body.append(f"[limit={limit} lines reached; {requested - last} more through line "
                            f"{requested}; read again with start_line={last + 1}]")
        return Text("\n".join(body))

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

    def find(self, pattern: str, path: str | Sequence[str] = ".", *,
             glob: str | Sequence[str] | None = None, context: int = 0,
             max_results: int = 50, literal: bool = False,
             case_sensitive: bool | None = None, hidden: bool = False) -> Search[Rows]:
        """Content search through ripgrep when it is installed, else pure Python.
        `path` may be one path or a list; `context=N` adds N lines around each
        match. Await it: `await files.find(pattern)`."""
        if not 0 <= context <= 50:
            raise ValueError("0 <= context <= 50")
        return Search("files.find", lambda: self._find(pattern, path, glob, context, max_results,
                                                       literal, case_sensitive, hidden))

    async def _find(self, pattern: str, path: str | Sequence[str], glob: str | Sequence[str] | None,
                    context: int, max_results: int, literal: bool, case_sensitive: bool | None,
                    hidden: bool) -> Rows:
        albedo_trace.note("search", pattern)
        targets = [Path(item).expanduser() for item in ([path] if isinstance(path, str) else path)]
        if not _which("rg"):
            return _fallback_find(pattern, targets, glob, context, max_results,
                                  literal, case_sensitive, hidden)
        flags = ["--json"]
        if context:
            flags += ["-C", str(context)]
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
                           ["rg", *flags, "-e", pattern, *map(str, targets)])
        per_match = 4 + 2 * context
        status, output = await _run(f"{command} | head -n {max(1, max_results) * per_match}")
        if status not in (0, 1, None) and not output.strip():
            raise RuntimeError(f"search failed: {output.strip()[:400]}")
        results, matched = [], 0
        for line in output.splitlines():
            try:
                event = json.loads(line)
            except ValueError:
                continue
            kind = event.get("type")
            if kind not in ("match", "context"):
                continue
            if kind == "match" and matched >= max_results:
                return Rows(results, truncated=True)
            data = event["data"]
            results.append(Match(data["path"]["text"], data["line_number"],
                                 data["lines"]["text"].rstrip("\r\n")[:LINE_WIDTH * 4],
                                 context=kind == "context"))
            matched += kind == "match"
        return Rows(results)

    def paths(self, pattern: str | None = None, path: str = ".", *,
              glob: str | None = None, max_results: int = 100, hidden: bool = False) -> Search[Rows]:
        """File names, not contents; the same ripgrep-or-Python split. A pattern
        with *, ? or [ is a glob over names; other text matches anywhere in the path.
        Await it: `await files.paths(pattern)`."""
        return Search("files.paths", lambda: self._paths(pattern, path, glob, max_results, hidden))

    async def _paths(self, pattern: str | None, path: str, glob: str | None,
                     max_results: int, hidden: bool) -> Rows:
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
        matches = _name_matcher(pattern)
        found = [line for line in output.splitlines() if line and matches(line)]
        return Rows(found[:max_results], truncated=len(found) > max_results)

    def edit(self, path: str, old_str: str, new_str: str, line_hint: int | None = None) -> Text:
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
        return Text(f"Edited {target}")

    def write(self, path: str, content: str) -> Text:
        """Create or replace a whole file. Use `edit` to change part of one."""
        target = Path(path).expanduser()
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8")
        return Text(f"Wrote {target.resolve()} ({len(content.encode())} bytes)")


def _which(name: str) -> str | None:
    for directory in os.environ.get("PATH", "").split(os.pathsep):
        candidate = Path(directory)/name
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    return None


def _fallback_find(pattern, targets: list[Path], glob, context, max_results,
                   literal, case_sensitive, hidden) -> Rows:
    flags = 0 if case_sensitive else re.IGNORECASE
    matcher = re.compile(re.escape(pattern) if literal else pattern, flags)
    globs = [glob] if isinstance(glob, str) else list(glob or [])
    results, matched = [], 0
    for target in targets:
        for file in _walk(target, hidden):
            if globs and not any(fnmatch.fnmatch(str(file), value) or fnmatch.fnmatch(file.name, value)
                                 for value in globs):
                continue
            try:
                lines = file.read_text(encoding="utf-8", errors="replace").splitlines()
            except OSError:
                continue
            hits = [number for number, line in enumerate(lines, 1) if matcher.search(line)]
            hit = set(hits)
            shown = 0
            for number in hits:
                if matched >= max_results:
                    return Rows(results, truncated=True)
                for around in range(max(number - context, shown + 1), min(number + context, len(lines)) + 1):
                    results.append(Match(str(file), around, lines[around - 1][:LINE_WIDTH * 4],
                                         context=around not in hit))
                    shown = around
                matched += 1
    return Rows(results)


def _name_matcher(pattern: str | None) -> Callable[[str], bool]:
    """A pattern with *, ? or [ is a glob over the file name (or the whole path
    when it has a /); anything else matches as case-insensitive text anywhere
    in the path, so "*.md" and "readme" both mean what they look like."""
    if not pattern:
        return lambda _path: True
    folded = pattern.lower()
    if any(char in pattern for char in "*?["):
        return lambda path: fnmatch.fnmatch((path if "/" in pattern else Path(path).name).lower(), folded)
    return lambda path: folded in path.lower()


def _fallback_paths(pattern, path: Path, glob, max_results, hidden) -> Rows:
    matches = _name_matcher(pattern)
    found = [str(file) for file in _walk(path, hidden)
             if (glob is None or fnmatch.fnmatch(file.name, glob)) and matches(str(file))]
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
