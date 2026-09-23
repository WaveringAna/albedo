"""Source ranges and diffs as syntax-highlighted images, for reviewing code by
its shape.

Rendering is albedo-render (native/render), run as a supervised `bash` job
like the files plugin's searches; its pages attach to the running cell.
"""
from __future__ import annotations

import os
import shlex
import tempfile
from collections.abc import Callable
from pathlib import Path

from albedo_api import PythonApi, Text
from albedo_plugins.files import Search, _missing, _run, _which

# Built by native/render/install.sh next to the kernel's own files.
RENDERER = Path(__file__).resolve().parents[2]/"bin"/"albedo-render"
ROWS = 80  # display rows per image: legible after providers scale a page down
IMAGES = 4  # the kernel's per-cell image limit


def setup(api: PythonApi) -> dict[str, object]:
    attach = api.attach_image

    def view_code(path: str, start_line: int = 1, end_line: int | None = None, *,
                  columns: int = 79) -> Search[Text]:
        """See lines start_line through end_line (default: as far as fits) as
        syntax-highlighted images, returned to you with this cell's result.
        Lines wrap at `columns`. At most 4 images of 80 display rows each; a
        wrapped line takes several rows, so wrap-heavy code fits fewer source
        lines per image. The text names the lines each image shows and the
        call that continues. Await it: `await view_code(path, 40, 120)`."""
        _check_range(start_line, end_line, columns)

        async def run() -> Text:
            renderer, target = _renderer(attach), _existing(path)
            if target.is_dir():
                raise IsADirectoryError(f"{path} is a directory; view_code shows one file")
            return await _render(renderer, attach, target, path, start_line, end_line, columns,
                                 [], lambda line: f"view_code({path!r}, {line})")
        return Search("view_code", run, "images")

    def view_diff(path: str = ".", start_line: int = 1, *, staged: bool = False,
                  columns: int = 80) -> Search[Text]:
        """See your uncommitted changes under `path` (git diff; staged=True for
        the index) as highlighted images: each hunk with its surrounding lines,
        + for added and - for removed. `columns` is 80 so a 79-column line and
        its mark fit. Files git does not track yet are not included; view them
        with view_code. start_line counts lines of the diff, to continue where
        a call stopped. Await it: `await view_diff()`."""
        _check_range(start_line, None, columns)

        def resume(line: int) -> str:
            return f"view_diff({path!r}, {line}{', staged=True' if staged else ''})"

        async def run() -> Text:
            renderer, target = _renderer(attach), _existing(path)
            where = target if target.is_dir() else target.parent
            with tempfile.TemporaryDirectory(prefix="albedo-diff-") as scratch:
                diff = Path(scratch)/"changes.diff"
                git = ["git", "-C", str(where)]
                changes = [*git, "diff", "--no-color", "--no-ext-diff",
                           *(["--staged"] if staged else []), "--", str(target.resolve())]
                # Outside a repository git diff compares paths instead; ask first.
                command = (" ".join(map(shlex.quote, [*git, "rev-parse", "--git-dir"]))
                           + " > /dev/null && " + " ".join(map(shlex.quote, changes))
                           + " > " + shlex.quote(str(diff)))
                status, output = await _run(command)
                if status != 0:
                    raise RuntimeError(f"git diff failed: {output.strip()[-400:] or f'exit {status}'}")
                if diff.stat().st_size == 0:
                    return Text(f"no {'staged' if staged else 'uncommitted'} changes under {path}")
                label = f"diff of {path}" + (" (staged)" if staged else "")
                return await _render(renderer, attach, diff, label, start_line, None, columns,
                                     ["--language", "diff", "--no-line-numbers"], resume)
        return Search("view_diff", run, "images")

    return {"view_code": view_code, "view_diff": view_diff}


def _check_range(start_line: int, end_line: int | None, columns: int) -> None:
    if start_line < 1 or (end_line is not None and end_line < start_line):
        raise ValueError("start_line >= 1 and end_line >= start_line")
    if not 20 <= columns <= 400:
        raise ValueError("20 <= columns <= 400")


def _renderer(attach: Callable[[bytes], str] | None) -> str:
    """The renderer to run, checked before any work that needs it."""
    if attach is None:
        raise RuntimeError("this kernel cannot return images")
    renderer = str(RENDERER) if os.access(RENDERER, os.X_OK) else _which("albedo-render")
    if renderer is None:
        raise RuntimeError("albedo-render is not built; run native/render/install.sh, "
                           "or use files.read for the text")
    return renderer


def _existing(path: str) -> Path:
    target = Path(path).expanduser()
    if not target.exists():
        raise FileNotFoundError(_missing(target, path))
    return target


async def _render(renderer: str, attach: Callable[[bytes], str], file: Path, label: str,
                  start_line: int, end_line: int | None, columns: int, options: list[str],
                  resume: Callable[[int], str]) -> Text:
    """Render `file` and attach its pages to the cell; `resume` names the call
    that continues from a line."""
    with tempfile.TemporaryDirectory(prefix="albedo-view-") as out:
        command = " ".join(shlex.quote(part) for part in [
            renderer, str(file.resolve()), "--out", out, "--start", str(start_line),
            "--end", str(end_line or 2**32), "--columns", str(columns),
            "--max-rows", str(ROWS), "--max-images", str(IMAGES), *options])
        status, output = await _run(command)
        if status != 0:
            failure = [line for line in output.splitlines() if line.startswith("albedo-render:")]
            raise RuntimeError(failure[-1].removeprefix("albedo-render: ") if failure
                               else f"albedo-render did not finish: {output.strip()[-400:]}")
        return _attach_pages(attach, label, output, resume)


def _attach_pages(attach: Callable[[bytes], str], label: str, report: str,
                  resume: Callable[[int], str]) -> Text:
    """Attach each page the renderer wrote, in order, and say what was shown."""
    language, shown, rest = "plain", [], None
    for line in report.splitlines():
        kind, _, fields = line.partition(" ")
        if kind == "language":
            language = fields
        elif kind == "image":
            file, first, last, size = fields.rsplit(" ", 3)
            shown.append((file, int(first), int(last), size))
        elif kind == "remaining":
            rest = int(fields.split()[0])
    notes = [f"{label} ({language})"]
    for number, (file, first, last, size) in enumerate(shown, 1):
        try:
            _ = attach(Path(file).read_bytes())
        except ValueError as full:
            notes.append(f"image {number} not attached: {full}")
            rest = first
            break
        notes.append(f"image {number}: lines {first}-{last}, {size}")
    if rest is not None:
        notes.append(f"not shown from line {rest}: {resume(rest)}")
    return Text("\n".join(notes))
