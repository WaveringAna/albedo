"""One honest output surface for captured local and SSH command-mode jobs."""

from __future__ import annotations

import os
from pathlib import Path
import tempfile

from albedo_api import OUTPUT_PREVIEW, RETAIN, OutputCapture, Text, excerpt


def _retention_error(capture: OutputCapture) -> ValueError:
    spill = getattr(capture, "spill", None)
    recovery = (
        f"The retained spill file is {spill}; it does not contain the discarded suffix. "
        if spill
        else ""
    )
    recovery += (
        "For job artifacts beyond retention, rerun with "
        "job.pipe('tee', path) attached before awaiting."
    )
    return ValueError(
        f"output has {capture.seen} bytes, but only the first {capture.retained} "
        "are retained; refusing incomplete output. "
        "Paginate the retained prefix with job.read(offset=0, limit=65536) "
        "or output.read(id, offset=0, limit=65536), advancing the byte offset. "
        "Bytes beyond retention cannot be recovered by pagination. " + recovery
    )


def read_page(capture: OutputCapture, offset: int, limit: int) -> Text:
    if offset < 0 or not 0 <= limit <= OUTPUT_PREVIEW:
        raise ValueError(
            f"offset >= 0 and 0 <= limit <= {OUTPUT_PREVIEW}; page with offset="
        )
    if not limit:
        return Text("")
    if min(offset + limit, capture.seen) > capture.retained:
        raise _retention_error(capture)
    return Text(capture.read(offset, limit))


def whole_characters(data: bytes) -> int:
    """How many leading bytes end on a character, as an unfinished UTF-8 sequence
    at the end is left for the bytes that follow it."""
    for back in range(1, min(4, len(data)) + 1):
        byte = data[-back]
        if byte & 0xC0 == 0x80:
            continue
        size = 4 if byte >= 0xF0 else 3 if byte >= 0xE0 else 2 if byte >= 0xC0 else 1
        return len(data) if back >= size else len(data) - back
    return len(data)


def read_window(
    capture: OutputCapture, offset: int | None, limit: int, finished: bool
) -> tuple[int, int, str]:
    """A page of at most `limit` bytes as text, with the bytes it starts and ends
    at, cut on characters so a reader that continues from its end loses none.

    Without `offset` the page is the end of the output. A `finished` writer
    adds no more, so a half character at the very end is shown, not held back.
    Raises ValueError for a bad window and LookupError for one that is lost."""
    if offset is not None and offset < 0 or not 4 <= limit <= OUTPUT_PREVIEW:
        # Four bytes hold any character, so a page always makes progress.
        raise ValueError(f"offset >= 0 and 4 <= limit <= {OUTPUT_PREVIEW}")
    seen = capture.seen
    tail = capture.tail()
    kept = seen - len(tail)  # the tail is always readable, whatever else was lost
    start = max(0, seen - limit) if offset is None else min(offset, seen)
    end = min(start + limit, seen)
    if start >= kept:
        data = tail[start - kept : end - kept]
    else:
        try:
            data = capture.read_bytes(start, end - start)
        except ValueError as error:
            raise LookupError(str(error)) from error
    if offset is None:
        # A page that opens inside a character starts at the next one.
        skip = 0
        while skip < min(3, len(data)) and data[skip] & 0xC0 == 0x80:
            skip += 1
        start, data = start + skip, data[skip:]
    if not (finished and start + len(data) == seen):
        data = data[: whole_characters(data)]
    return start, start + len(data), data.decode("utf-8", errors="replace")


class JobOutput:
    capture: OutputCapture
    duration: float | None
    exit_code: int | None
    _read: bool

    def tail(self, n: int = 4000, *, lines: int | None = None) -> Text:
        """The last n characters or lines, within the 64 KiB preview window."""
        data = self.capture.tail()
        result = excerpt(
            data.decode("utf-8", errors="ignore"),
            n,
            lines,
            end=True,
            clipped=self.capture.seen > len(data),
        )
        if self.exit_code is not None:
            self._read = True
        return result

    def head(self, n: int = 4000, *, lines: int | None = None) -> Text:
        """The first n characters or lines, within the 64 KiB preview window."""
        data = self.capture.data[:OUTPUT_PREVIEW]
        result = excerpt(
            data.decode("utf-8", errors="ignore"),
            n,
            lines,
            end=False,
            clipped=self.capture.seen > len(data),
        )
        if self.exit_code is not None:
            self._read = True
        return result

    def _require_complete(self) -> None:
        if self.duration is None:
            raise RuntimeError(
                "output is still running; await job before job.read() or job.save(path)"
            )
        if self.capture.seen > self.capture.retained:
            raise _retention_error(self.capture)

    def read(self, offset: int = 0, limit: int | None = None) -> Text:
        """Complete text after completion, or a byte-offset page with explicit limit.

        Whole text reads are at most 1 MiB. Pages are at most 64 KiB, read spill
        files transparently, and may read a running job. save() preserves bytes.
        """
        if limit is None:
            if offset < 0:
                raise ValueError("offset must be nonnegative")
            self._require_complete()
            size = max(0, self.capture.seen - offset)
            if size > RETAIN:
                raise ValueError(
                    "whole text reads are limited to 1 MiB; paginate with "
                    "job.read(offset=0, limit=65536), advancing the byte offset, "
                    "or job.save(path) for the complete artifact. "
                    "Output past 1 MiB is automatically stored on disk (up to 16 MiB)."
                )
            result = Text(
                self.capture.read_bytes(offset, size).decode("utf-8", errors="replace")
            )
        else:
            result = read_page(self.capture, offset, limit)
        if self.duration is not None:
            self._read = True
        return result

    def save(self, path: str | os.PathLike[str]) -> Text:
        """Atomically replace path with complete output bytes, or leave it untouched.

        The path is on the capture's host (local in SSH command mode). Returns
        its absolute path. Completion and full retention are required.
        """
        self._require_complete()
        target = Path(path).expanduser().absolute()
        target.parent.mkdir(parents=True, exist_ok=True)
        fd, name = tempfile.mkstemp(dir=target.parent)
        temporary = Path(name)
        try:
            with os.fdopen(fd, "wb") as file:
                for offset in range(0, self.capture.seen, OUTPUT_PREVIEW):
                    file.write(self.capture.read_bytes(offset, OUTPUT_PREVIEW))
            os.replace(temporary, target)
        finally:
            temporary.unlink(missing_ok=True)
        self._read = True
        return Text(str(target))
