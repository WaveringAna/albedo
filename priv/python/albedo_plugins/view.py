"""Source ranges as syntax-highlighted images, for reviewing code by its shape.

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
ROWS = 80  # rows per image: legible after providers scale a page down
IMAGES = 4  # the kernel's per-cell image limit


def setup(api: PythonApi) -> dict[str, object]:
    attach = api.attach_image

    def view_code(path: str, start_line: int = 1, end_line: int | None = None, *,
                  columns: int = 79) -> Search:
        """See lines start_line through end_line (default: as far as fits) as
        syntax-highlighted images, returned to you with this cell's result.
        Lines wrap at `columns`. At most 4 images of about 80 rows each; the
        text names the lines each image shows and any left for another call.
        Await it: `await view_code(path, 40, 120)`."""
        if start_line < 1 or (end_line is not None and end_line < start_line):
            raise ValueError("start_line >= 1 and end_line >= start_line")
        if not 20 <= columns <= 400:
            raise ValueError("20 <= columns <= 400")
        return Search("view_code", lambda: _view(attach, path, start_line, end_line, columns), "images")

    return {"view_code": view_code}


async def _view(attach: Callable[[bytes], str] | None, path: str, start_line: int,
                end_line: int | None, columns: int) -> Text:
    if attach is None:
        raise RuntimeError("this kernel cannot return images")
    target = Path(path).expanduser()
    if not target.is_file():
        raise FileNotFoundError(_missing(target, path))
    renderer = str(RENDERER) if os.access(RENDERER, os.X_OK) else _which("albedo-render")
    if renderer is None:
        raise RuntimeError("albedo-render is not built; run native/render/install.sh, "
                           "or use files.read for the text")
    with tempfile.TemporaryDirectory(prefix="albedo-view-") as out:
        command = " ".join(shlex.quote(part) for part in [
            renderer, str(target.resolve()), "--out", out, "--start", str(start_line),
            "--end", str(end_line or 2**32), "--columns", str(columns),
            "--max-rows", str(ROWS), "--max-images", str(IMAGES)])
        status, output = await _run(command)
        if status != 0:
            failure = [line for line in output.splitlines() if line.startswith("albedo-render:")]
            raise RuntimeError(failure[-1].removeprefix("albedo-render: ") if failure
                               else f"albedo-render did not finish: {output.strip()[-400:]}")
        return _attach_pages(attach, path, output)


def _attach_pages(attach: Callable[[bytes], str], path: str, report: str) -> Text:
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
    notes = [f"{path} ({language})"]
    for number, (file, first, last, size) in enumerate(shown, 1):
        try:
            _ = attach(Path(file).read_bytes())
        except ValueError as full:
            notes.append(f"image {number} not attached: {full}")
            rest = first
            break
        notes.append(f"image {number}: lines {first}-{last}, {size}")
    if rest is not None:
        notes.append(f"not shown from line {rest}: view_code({path!r}, {rest})")
    return Text("\n".join(notes))
