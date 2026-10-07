"""Bounded reads, exact edits, and ripgrep-backed search over workspace files.

Every external command runs through the supervised `run` job plugin, so this
module never spawns a process of its own and every child stays in a job's group.
"""

from __future__ import annotations

import asyncio
import codecs
import difflib
import fnmatch
import json
import os
import re
import shlex
import stat
import tempfile
from dataclasses import dataclass
from io import BufferedReader
from pathlib import Path
from collections.abc import Awaitable, Callable, Generator
from typing import Generic, Iterable, Sequence, TypeVar

from albedo_api import PythonApi, ReadyList, Text
import albedo_trace
from albedo_plugins import run as jobs

READ_LIMIT = 16_000
READ_CHUNK_BYTES = 64 * 1024
LINE_SEPARATORS = "\n\r\v\f\x1c\x1d\x1e\x85\u2028\u2029"
LINE_BOUNDARIES = re.compile(rf"\r\n|[{re.escape(LINE_SEPARATORS)}]")
SEARCH_TIMEOUT = 30
LINE_WIDTH = 160
CANDIDATES = 4
LISTED = 10
CONTEXT = 2
PREVIEW_LINES = 2
WITHHELD = 3


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
        fields: dict[str, str | int | bool] = {
            "path": self.path,
            "line": self.line,
            "text": self.text,
        }
        if self.context:
            fields["context"] = True
        return fields


class Rows(ReadyList):
    """A list that prints one row per line, so a REPL result reads like output.
    Like Text, it may be awaited or used directly."""

    def __init__(
        self, items: Iterable[object] = (), truncated: bool = False, note: str = ""
    ) -> None:
        super().__init__(items)
        self.truncated = truncated
        self.note = note

    def __repr__(self) -> str:
        if not self:
            return f"[]\n{self.note}" if self.note else "[]"
        body = "\n".join(str(item) for item in self)
        return body + ("\n[truncated]" if self.truncated else "")

    __str__ = __repr__


Result = TypeVar("Result")


class Search(Generic[Result]):
    """Work that runs a supervised job, so its result exists only once awaited:
    `Search[Rows]` awaits to Rows. Using it without `await` explains that
    instead of printing a coroutine."""

    def __init__(
        self, call: str, run: Callable[[], Awaitable[Result]], result: str = "rows"
    ) -> None:
        self._call = call
        self._run = run
        self._result = result

    def __await__(self) -> Generator[object, None, Result]:
        return self._run().__await__()

    def __getitem__(self: Search[Rows], index: int | slice) -> Search[object]:
        """`await files.find(...)[:10]` slices before it awaits; apply the
        slice to the rows instead of failing on precedence."""

        async def run() -> object:
            rows = await self._run()
            picked = rows[index]
            if isinstance(rows, Rows) and isinstance(index, slice):
                return Rows(picked, truncated=rows.truncated, note=rows.note)
            return picked

        return Search(self._call, run, self._result)

    def _unawaited(self) -> TypeError:
        return TypeError(
            f"{self._call}(...) runs in the background; "
            f"use `await {self._call}(...)` to get its {self._result}"
        )

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


class _ReadWindow:
    """Track selected lines, the current line, and the first rejected row."""

    def __init__(self, start_line: int, last_line: int | None, max_chars: int):
        self.start_line = start_line
        self.last_line = last_line
        self.max_chars = max_chars
        self.lines: list[str] = []
        self.used_chars = 0
        self.stopped_line: int | None = None
        self.stopped_row_chars = 0
        self.number = 1
        self.line_chars = 0
        self.fragments: list[str] = []

    def wants_line(self) -> bool:
        return (
            self.stopped_line is None
            and self.number >= self.start_line
            and (self.last_line is None or self.number <= self.last_line)
        )

    def extend(self, text: str, start: int, end: int) -> None:
        self.line_chars += end - start
        if self.wants_line():
            row_chars = max(6, len(str(self.number))) + 3 + self.line_chars
            if self.used_chars + row_chars + 1 <= self.max_chars:
                if start < end:
                    self.fragments.append(text[start:end])
            else:
                # Keep counting a giant line, but release its retained prefix.
                self.fragments.clear()

    def finish_line(self) -> None:
        if self.wants_line():
            row_chars = max(6, len(str(self.number))) + 3 + self.line_chars
            if self.used_chars + row_chars + 1 > self.max_chars:
                self.stopped_line = self.number
                self.stopped_row_chars = row_chars
            else:
                self.lines.append("".join(self.fragments))
                self.used_chars += row_chars + 1
        self.number += 1
        self.line_chars = 0
        self.fragments.clear()


def _scan_read(
    source: BufferedReader, window: _ReadWindow, end_line: int | None
) -> int:
    chunk = source.read(READ_CHUNK_BYTES)
    at_eof = len(chunk) < READ_CHUNK_BYTES or not source.peek(1)
    text = chunk.decode("utf-8", errors="replace") if at_eof else ""
    # Native splitting is cheap for a bounded ASCII file. Unicode uses spans
    # instead, so dense replacement characters never build a list of substrings.
    if at_eof and text.isascii():
        lines = text.splitlines()
        total = len(lines)
        last = total if window.last_line is None else min(total, window.last_line)
        window.lines = lines[window.start_line - 1 : last]
        return total

    decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")
    if not at_eof:
        text = decoder.decode(chunk)
    skip_lf = False
    while True:
        if skip_lf and text.startswith("\n"):
            text = text[1:]
        separator_count = 0
        if any(separator in text for separator in LINE_SEPARATORS):
            separator_count = sum(
                text.count(separator) for separator in LINE_SEPARATORS
            )
            separator_count -= text.count("\r\n")
        window_complete = window.stopped_line is not None or (
            window.last_line is not None and window.number > window.last_line
        )
        if not separator_count:
            window.extend(text, 0, len(text))
        elif window_complete or window.number + separator_count < window.start_line:
            window.number += separator_count
            if end_line is not None and window.number > end_line:
                return end_line
            # Skipped lines need only an unfinished-line flag for EOF.
            # A requested line begins after a separator resets this state.
            window.line_chars = int(text[-1] not in LINE_SEPARATORS)
        else:
            position = 0
            for boundary in LINE_BOUNDARIES.finditer(text):
                window.extend(text, position, boundary.start())
                window.finish_line()
                if end_line is not None and window.number > end_line:
                    return end_line
                position = boundary.end()
            window.extend(text, position, len(text))
        skip_lf = text.endswith("\r")
        if at_eof:
            if window.line_chars:
                window.finish_line()
            return window.number - 1
        chunk = source.read(READ_CHUNK_BYTES)
        at_eof = not chunk
        text = decoder.decode(chunk, final=at_eof)


class Files:
    """Workspace file access with the diagnostics an exact edit needs."""

    def read(
        self,
        path: str,
        start_line: int = 1,
        end_line: int | None = None,
        *,
        limit: int | None = None,
        max_chars: int = READ_LIMIT,
    ) -> Text:
        """Numbered lines from start_line through end_line, at most `limit` lines.

        `limit` counts lines. `max_chars` is a separate character budget (at
        most 200000) that keeps a huge window from flooding the context; when it
        stops a read early, the result says so and names the line to resume
        from. Lines are never shortened. The numbers are what `edit(line_hint=)`
        takes.
        """
        if (
            start_line < 1
            or (end_line is not None and end_line < start_line)
            or (limit is not None and limit < 1)
            or not 0 < max_chars <= 200_000
        ):
            raise ValueError(
                "start_line >= 1, end_line >= start_line, limit >= 1 line, "
                "0 < max_chars <= 200000"
            )
        target = Path(path).expanduser()
        if not target.is_file():
            if target.is_dir():
                raise IsADirectoryError(
                    f"{path} is a directory; files.ls({path!r}) lists it"
                )
            raise FileNotFoundError(_missing(target, path))
        last = end_line
        if limit is not None:
            limited_last = start_line + limit - 1
            last = limited_last if last is None else min(last, limited_last)
        window = _ReadWindow(start_line, last, max_chars)
        with target.open("rb") as source:
            total = _scan_read(source, window, end_line)
        if start_line > total:
            return Text(f"[{path} has {total} lines; nothing at line {start_line}]")
        requested = total if end_line is None else min(end_line, total)
        last = requested if last is None else min(last, requested)
        body, used = window.lines, 0
        number = window.stopped_line
        row_chars = window.stopped_row_chars
        for current, text in enumerate(body, start_line):
            row = f"{current:>6} | {text}"
            if used + len(row) + 1 > max_chars:
                number, row_chars = current, len(row)
                del body[current - start_line :]
                break
            used += len(row) + 1
            body[current - start_line] = row
        if number is not None:
            if not body:
                retry = (
                    f"read it alone with start_line={number}, end_line={number}, max_chars={row_chars + 1}"
                    if row_chars + 1 <= 200_000
                    else "it exceeds the 200000-character maximum"
                )
                body.append(
                    f"[line {number} is {row_chars} characters with its number, over "
                    f"max_chars={max_chars}; {retry}]"
                )
            else:
                body.append(
                    f"[stopped at max_chars={max_chars} characters; lines {number}-{last} "
                    f"not shown; read again with start_line={number}, or raise max_chars]"
                )
        elif last < requested:
            body.append(
                f"[limit={limit} lines reached; {requested - last} more through line "
                f"{requested}; read again with start_line={last + 1}]"
            )
        result = "\n".join(body)
        # Release numbered rows before Text copies the joined Unicode buffer.
        body.clear()
        return Text(result)

    def ls(
        self, path: str = ".", pattern: str | None = None, *, hidden: bool = False
    ) -> Rows:
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

    def find(
        self,
        pattern: str,
        path: str | Sequence[str] = ".",
        *,
        glob: str | Sequence[str] | None = None,
        context: int = 0,
        max_results: int = 50,
        literal: bool = False,
        case_sensitive: bool | None = None,
        hidden: bool = False,
        ignored: bool = False,
    ) -> Search[Rows]:
        """Content search through ripgrep when it is installed, else pure Python.
        `path` may be one path or a list; `context=N` adds N lines around each
        match. A missing path raises. Ignore files and hidden files are skipped
        unless `ignored=True` / `hidden=True`; an empty result says what was
        searched and skipped. Await it: `await files.find(pattern)`."""
        if not 0 <= context <= 50:
            raise ValueError("0 <= context <= 50")
        return Search(
            "files.find",
            lambda: self._find(
                pattern,
                path,
                glob,
                context,
                max_results,
                literal,
                case_sensitive,
                hidden,
                ignored,
            ),
        )

    async def _find(
        self,
        pattern: str,
        path: str | Sequence[str],
        glob: str | Sequence[str] | None,
        context: int,
        max_results: int,
        literal: bool,
        case_sensitive: bool | None,
        hidden: bool,
        ignored: bool,
    ) -> Rows:
        albedo_trace.note("search", pattern)
        targets = _targets(path)
        _require_roots(targets)
        if not _which("rg"):
            return _fallback_find(
                pattern,
                targets,
                glob,
                context,
                max_results,
                literal,
                case_sensitive,
                hidden,
            )
        flags = []
        if literal:
            flags.append("-F")
        if case_sensitive is True:
            flags.append("-s")
        elif case_sensitive is False:
            flags.append("-i")
        for value in _globs(glob):
            flags += ["-g", value]
        visible = [
            *(["--hidden"] if hidden else []),
            *(["--no-ignore"] if ignored else []),
        ]

        def search(*extra: str) -> str:
            return " ".join(
                shlex.quote(part)
                for part in ["rg", *flags, *extra, "-e", pattern, *map(str, targets)]
            )

        per_match = 4 + 2 * context
        status, output = await _run(
            f"{search('--json', *visible, *(['-C', str(context)] if context else []))}"
            f" | head -n {max(1, max_results) * per_match}"
        )
        if status not in (0, 1, None) and not output.strip():
            raise RuntimeError(f"search failed: {output.strip()[:400]}")
        results, matched, searched = [], 0, 0
        for line in output.splitlines():
            try:
                event = json.loads(line)
            except ValueError:
                continue
            kind = event.get("type")
            if kind == "summary":
                searched = event["data"]["stats"]["searches"]
            if kind not in ("match", "context"):
                continue
            if kind == "match" and matched >= max_results:
                return Rows(results, truncated=True)
            data = event["data"]
            results.append(
                Match(
                    data["path"]["text"],
                    data["line_number"],
                    data["lines"]["text"].rstrip("\r\n")[: LINE_WIDTH * 4],
                    context=kind == "context",
                )
            )
            matched += kind == "match"
        if results:
            return Rows(results)
        skipped = [
            *([] if hidden else ["hidden files"]),
            *([] if ignored else [".gitignore/.ignore rules"]),
        ]
        withheld: list[str] = []
        if skipped:
            _, listing = await _run(
                f"{search('-l', '--hidden', '--no-ignore')} | head -n {WITHHELD}"
            )
            withheld = listing.splitlines()
        return Rows(
            note=_empty_note(pattern, targets, searched, skipped, glob, withheld)
        )

    def paths(
        self,
        pattern: str | None = None,
        path: str | Sequence[str] = ".",
        *,
        glob: str | Sequence[str] | None = None,
        max_results: int = 100,
        hidden: bool = False,
    ) -> Search[Rows]:
        """File names, not contents; the same ripgrep-or-Python split. A pattern
        with *, ? or [ is a glob over names, or over the path from the search
        root when it has a /; other text matches anywhere in the path.
        `path` may be one path or a list. Await it: `await files.paths(pattern)`."""
        return Search(
            "files.paths", lambda: self._paths(pattern, path, glob, max_results, hidden)
        )

    async def _paths(
        self,
        pattern: str | None,
        path: str | Sequence[str],
        glob: str | Sequence[str] | None,
        max_results: int,
        hidden: bool,
    ) -> Rows:
        targets = _targets(path)
        globs = _globs(glob)
        if not _which("rg"):
            return _fallback_paths(pattern, targets, globs, max_results, hidden)
        flags = ["--files"]
        if hidden:
            flags.append("--hidden")
        for value in globs:
            flags += ["-g", value]
        command = " ".join(
            shlex.quote(part) for part in ["rg", *flags, *map(str, targets)]
        )
        _, output = await _run(command)
        matches = _name_matcher(pattern)
        # rg lists "./x" under ".", where a path from the root is just "x"
        listed = (line.removeprefix("./") for line in output.splitlines() if line)
        found = [line for line in listed if matches(line)]
        return Rows(found[:max_results], truncated=len(found) > max_results)

    def edit(
        self, path: str, old_str: str, new_str: str, line_hint: int | None = None
    ) -> Text:
        """Replace one exact, unique string. A miss reports what is actually there."""
        if not old_str:
            raise ValueError("old_str must be non-empty")
        if line_hint is not None and (
            isinstance(line_hint, bool) or not isinstance(line_hint, int)
        ):
            raise ValueError(
                f"line_hint must be a line number, not {type(line_hint).__name__}"
            )
        target = Path(path).expanduser()
        if not target.exists():
            raise FileNotFoundError(_missing(target, path))
        target = target.resolve()
        snapshot = _snapshot(target)
        content = snapshot[0].decode("utf-8")
        found = _occurrences(content, old_str)
        if not found:
            closest = _closest(content, old_str)
            raise ValueError(
                f"string not found in {path}"
                + (
                    "; the text is there, but whitespace differs (indentation, "
                    "tabs, trailing spaces or line endings)"
                    if _words(old_str) in _words(content) and _words(old_str)
                    else ""
                )
                + (f"\n{closest}" if closest else "")
            )
        chosen = _choose(content, old_str, found, line_hint, path)
        replacement = (
            content[: chosen.index] + new_str + content[chosen.index + len(old_str) :]
        ).encode("utf-8")
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
        candidate = Path(directory) / name
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    return None


def _require_roots(targets: list[Path]) -> None:
    for target in targets:
        if not target.exists():
            raise FileNotFoundError(_missing(target, str(target)))


def _empty_note(
    pattern: str,
    targets: list[Path],
    searched: int,
    skipped: list[str],
    glob: str | Sequence[str] | None,
    withheld: list[str],
) -> str:
    """Why a search came back empty: where it looked, what it left out, and
    which skipped files would have matched."""
    roots = ", ".join(str(target.resolve()) for target in targets)
    left_out = [*skipped, *([f"files outside glob {_globs(glob)}"] if glob else [])]
    note = f"no matches for {pattern!r} in {roots}: {searched} files searched"
    if left_out:
        note += f"; skipped {', '.join(left_out)}"
    if withheld:
        note += (
            f"; it matches in skipped files ({', '.join(withheld)}): "
            "rerun with hidden=True and/or ignored=True"
        )
    return note


def _fallback_find(
    pattern,
    targets: list[Path],
    glob,
    context,
    max_results,
    literal,
    case_sensitive,
    hidden,
) -> Rows:
    rows, searched = _fallback_scan(
        pattern, targets, glob, context, max_results, literal, case_sensitive, hidden
    )
    if rows:
        return rows
    withheld = []
    if not hidden:
        everything, _ = _fallback_scan(
            pattern, targets, glob, 0, WITHHELD, literal, case_sensitive, True
        )
        withheld = [match.path for match in everything]
    skipped = [] if hidden else ["hidden files"]
    return Rows(note=_empty_note(pattern, targets, searched, skipped, glob, withheld))


def _fallback_scan(
    pattern,
    targets: list[Path],
    glob,
    context,
    max_results,
    literal,
    case_sensitive,
    hidden,
) -> tuple[Rows, int]:
    flags = 0 if case_sensitive else re.IGNORECASE
    matcher = re.compile(re.escape(pattern) if literal else pattern, flags)
    globs = _globs(glob)
    results, matched, searched = [], 0, 0
    for target in targets:
        for file in _walk(target, hidden):
            if not _globbed(file, globs):
                continue
            try:
                lines = file.read_text(encoding="utf-8", errors="replace").splitlines()
            except OSError:
                continue
            searched += 1
            hits = [
                number for number, line in enumerate(lines, 1) if matcher.search(line)
            ]
            hit = set(hits)
            shown = 0
            for number in hits:
                if matched >= max_results:
                    return Rows(results, truncated=True), searched
                for around in range(
                    max(number - context, shown + 1),
                    min(number + context, len(lines)) + 1,
                ):
                    results.append(
                        Match(
                            str(file),
                            around,
                            lines[around - 1][: LINE_WIDTH * 4],
                            context=around not in hit,
                        )
                    )
                    shown = around
                matched += 1
    return Rows(results), searched


def _targets(path: str | Sequence[str]) -> list[Path]:
    return [
        Path(item).expanduser() for item in ([path] if isinstance(path, str) else path)
    ]


def _globs(glob: str | Sequence[str] | None) -> list[str]:
    return [glob] if isinstance(glob, str) else list(glob or [])


def _globbed(file: Path, globs: list[str]) -> bool:
    """True when there is no glob, or one matches the path or the file name."""
    return not globs or any(
        fnmatch.fnmatch(str(file), value) or fnmatch.fnmatch(file.name, value)
        for value in globs
    )


def _name_matcher(pattern: str | None) -> Callable[[str], bool]:
    """A pattern with *, ? or [ is a glob over the file name (or the whole path
    when it has a /); anything else matches as case-insensitive text anywhere
    in the path, so "*.md" and "readme" both mean what they look like."""
    if not pattern:
        return lambda _path: True
    folded = pattern.lower().removeprefix("./")
    if any(char in pattern for char in "*?["):
        return lambda path: fnmatch.fnmatch(
            (path if "/" in pattern else Path(path).name).lower(), folded
        )
    return lambda path: folded in path.lower()


def _fallback_paths(
    pattern, targets: list[Path], globs: list[str], max_results, hidden
) -> Rows:
    matches = _name_matcher(pattern)
    found = [
        str(file)
        for target in targets
        for file in _walk(target, hidden)
        if _globbed(file, globs) and matches(str(file))
    ]
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
            yield Path(root) / name


def _snapshot(target: Path) -> tuple[bytes, tuple[int, int, int, int, int]]:
    """Bytes plus identity: an edit refuses to publish over a concurrent change."""
    for _ in range(3):
        before = target.stat()
        data = target.read_bytes()
        after = target.stat()
        identity = (
            after.st_dev,
            after.st_ino,
            stat.S_IMODE(after.st_mode),
            after.st_size,
            after.st_mtime_ns,
        )
        if identity == (
            before.st_dev,
            before.st_ino,
            stat.S_IMODE(before.st_mode),
            before.st_size,
            before.st_mtime_ns,
        ):
            return data, identity
    raise ValueError(f"file changed while reading {target}; refusing to edit it")


def _replace(
    target: Path,
    snapshot: tuple[bytes, tuple[int, int, int, int, int]],
    replacement: bytes,
) -> None:
    descriptor, name = tempfile.mkstemp(
        dir=target.parent, prefix=f".{target.name}.", suffix=".tmp"
    )
    temporary = Path(name)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            os.fchmod(stream.fileno(), snapshot[1][2])
            stream.write(replacement)
            stream.flush()
            os.fsync(stream.fileno())
        if _snapshot(target) != snapshot:
            raise ValueError(
                f"file changed while editing {target}; refusing to overwrite concurrent changes"
            )
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
        return (
            str(self.start_line)
            if self.start_line == self.end_line
            else f"{self.start_line}-{self.end_line}"
        )


def _occurrences(content: str, needle: str) -> list[_Occurrence]:
    found, span, start = [], needle.count("\n") + 1, 0
    while True:
        index = content.find(needle, start)
        if index < 0:
            return found
        first = content.count("\n", 0, index) + 1
        found.append(_Occurrence(index, first, first + span - 1))
        start = index + len(needle)


def _choose(
    content: str,
    old_str: str,
    found: list[_Occurrence],
    line_hint: int | None,
    path: str,
) -> _Occurrence:
    if len(found) == 1:
        return found[0]
    listed = ", ".join(one.label for one in found[:LISTED]) + (
        f", ... ({len(found)} total)" if len(found) > LISTED else ""
    )
    if line_hint is None:
        raise ValueError(
            f"found {len(found)} occurrences in {path}: lines {listed}. Nothing was changed. "
            "Retry with line_hint=<a line inside the range you want>, or widen old_str until it is unique.\n"
            + _candidates(content, found)
        )
    inside = next(
        (one for one in found if one.start_line <= line_hint <= one.end_line), None
    )
    if inside is None:
        raise ValueError(
            f"line_hint={line_hint} is inside none of the {len(found)} occurrences in {path}: lines {listed}. "
            f"Nothing was changed.\n{_candidates(content, found)}"
        )
    return inside


def _candidates(content: str, found: list[_Occurrence]) -> str:
    lines = content.splitlines()
    blocks = []
    for position, occurrence in enumerate(found[:CANDIDATES], 1):
        matched = occurrence.end_line - occurrence.start_line + 1
        preview = min(matched, PREVIEW_LINES)
        first = max(1, occurrence.start_line - CONTEXT)
        last = min(len(lines), occurrence.end_line + CONTEXT)
        body = [
            _numbered(number, lines) for number in range(first, occurrence.start_line)
        ]
        body += [
            _numbered(number, lines)
            for number in range(occurrence.start_line, occurrence.start_line + preview)
        ]
        if matched > preview:
            body.append(f"{'...':>6} | ({matched - preview} further matching lines)")
        body += [
            _numbered(number, lines)
            for number in range(occurrence.end_line + 1, last + 1)
        ]
        blocks.append(
            f"candidate {position} of {len(found)}: lines {occurrence.label}\n"
            + "\n".join(body)
        )
    if len(found) > CANDIDATES:
        blocks.append(f"... {len(found) - CANDIDATES} further occurrences not shown")
    return "\n\n".join(blocks)


def _words(text: str) -> str:
    """text with every run of whitespace as one space, to see a whitespace-only miss."""
    return " ".join(text.split())


def _closest(content: str, needle: str) -> str:
    lines, needle_lines = content.splitlines(), needle.splitlines()
    head = next((line.strip() for line in needle_lines if line.strip()), "")
    if not lines or not head:
        return ""
    ranked = sorted(
        (
            (
                difflib.SequenceMatcher(
                    None, head, line.strip(), autojunk=False
                ).ratio(),
                index,
            )
            for index, line in enumerate(lines)
            if line.strip()
        ),
        reverse=True,
    )[:12]
    width = max(1, len(needle_lines))
    scored = []
    for _, start in ranked:
        end = min(len(lines), start + width)
        current = "\n".join(lines[start:end]).strip()
        scored.append(
            (
                difflib.SequenceMatcher(
                    None, needle.strip(), current, autojunk=False
                ).ratio(),
                start,
                end,
            )
        )
    blocks = []
    for score, start, end in sorted(scored, reverse=True):
        if score < 0.25:
            continue
        body = "\n".join(_numbered(number + 1, lines) for number in range(start, end))
        blocks.append(
            f"closest candidate lines {start + 1}-{end} (similarity {score:.0%}):\n{body}"
        )
        if len(blocks) == 3:
            break
    return "\n\n".join(blocks)


def _missing(target: Path, original: str) -> str:
    message = f"{original} not found (cwd: {Path.cwd()})"
    parent = target.parent
    if not parent.is_dir():
        return message
    close = difflib.get_close_matches(
        target.name, [entry.name for entry in parent.iterdir()], n=3, cutoff=0.35
    )
    return message + (
        f"; nearby paths: {', '.join(str(parent / name) for name in close)}"
        if close
        else ""
    )


def setup(api: PythonApi) -> dict[str, object]:
    return {"files": Files()}
