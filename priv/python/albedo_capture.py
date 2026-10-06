"""Bounded cell output and image validation, independent of kernel lifetime."""

from __future__ import annotations

import base64
import os
import re
import struct
import time
from typing import BinaryIO

import albedo_api
import albedo_trace

PREVIEW = 64 * 1024
RETAIN = albedo_api.RETAIN
MAX_IMAGES = 4
# Base64 growth and the output preview must fit the 8 MiB result frame.
MAX_IMAGE_BYTES = 5 * 1024 * 1024
# A cell whose output passes the preview also gets it whole in a file, up to
# this much; the kernel sets the directory and prunes files past SPILL_KEEP.
SPILL_LIMIT = 16 * 1024 * 1024
SPILL_KEEP = 14 * 24 * 3600  # seconds, the python state expiry
SPILL_DIR: str | None = None


def prune_spills(directory: str) -> None:
    """Make `directory` the spill directory, without the files past SPILL_KEEP."""
    global SPILL_DIR
    SPILL_DIR = directory
    try:
        os.makedirs(directory, exist_ok=True)
        with os.scandir(directory) as entries:
            stale = [
                entry.path
                for entry in entries
                if entry.is_file() and time.time() - entry.stat().st_mtime > SPILL_KEEP
            ]
    except OSError:
        SPILL_DIR = None
        return
    for path in stale:
        try:
            os.unlink(path)
        except OSError:
            pass


class Capture:
    """Output as the bytes that were written: the first RETAIN of them in
    `data`, and once more than that has arrived, the last PREVIEW in a tail
    buffer that exists only from then on. A pipe reader gets the exact bytes
    back; text readers decode a window."""

    def __init__(
        self, id: str, kind: str = "cell", max_edge: int | None = None
    ) -> None:
        self.id: str = id
        self.kind: str = kind
        self.max_edge: int | None = max_edge  # the session provider's, sent per cell
        self.data: bytearray = bytearray()
        self._tail: bytearray | None = None
        self.seen: int = 0
        self.trace: albedo_trace.Trace = albedo_trace.Trace()
        self.interruption: str = "cancelled"
        self.images: list[bytes] = []
        # The file holding the whole output once it passed the preview, and
        # how much of it is there; `spill` stays set after the file closes.
        self.spill: str | None = None
        self.spilled: int = 0
        self._spill_file: BinaryIO | None = None

    def spills(self) -> bool:
        return self.kind == "cell" and SPILL_DIR is not None

    def write(self, text: str) -> None:
        room = RETAIN - len(self.data)
        if text.isascii() and len(text) > room + PREVIEW and not self.spills():
            # One byte per character: keep both ends without encoding the middle.
            self.write_bytes(text[:room].encode())
            self.seen += len(text) - room - PREVIEW
            self.write_bytes(text[-PREVIEW:].encode())
            return
        self.write_bytes(text.encode("utf-8", errors="replace"))

    def write_bytes(self, data: bytes | bytearray | memoryview) -> None:
        size = len(data)
        self.seen += size
        room = RETAIN - len(self.data)
        if size <= room:
            self.data += data
        else:
            if self._tail is None:
                # First overflow: `data` holds the whole stream so far, and from
                # now on never grows again, so drop its growth slack.
                self._tail = self.data[-PREVIEW:]
                self.data += data[:room]
                self.data = self.data[:]
            if size >= PREVIEW:
                self._tail = bytearray(data[-PREVIEW:])
            else:
                self._tail += data
                del self._tail[:-PREVIEW]
        if self.seen > PREVIEW and self.spills():
            self._spill(data, size)

    def _spill(self, data: bytes | bytearray | memoryview, size: int) -> None:
        """Append `data` to the spill file, opening it with everything before
        it on the first write past the preview. Unbuffered, so a backgrounded
        cell's file reads live. A file that will not open leaves `spill` unset."""
        if self._spill_file is None:
            if self.spill is not None or self.spilled or SPILL_DIR is None:
                return  # closed, full, refused, or failed
            path = os.path.join(SPILL_DIR, re.sub(r"[^\w.-]", "_", self.id) + ".txt")
            try:
                self._spill_file = open(path, "wb", buffering=0)
                # Before this write the stream fit in `data` whole.
                self.spilled = self._spill_file.write(self.data[: self.seen - size])
            except OSError:
                self._spill_file = None
                return
            self.spill = path
        try:
            self.spilled += self._spill_file.write(data[: SPILL_LIMIT - self.spilled])
        except OSError:
            self.end_spill()
            self.spill = None  # a file missing its end is not offered
            return
        if self.spilled >= SPILL_LIMIT:
            self.end_spill()

    def end_spill(self) -> None:
        if self._spill_file is not None:
            self._spill_file.close()
            self._spill_file = None

    def spill_note(self) -> str:
        """What the result says about output past the preview, or nothing."""
        if self.spill is None:
            return ""
        kept = (
            f"its first {SPILL_LIMIT >> 20} MiB are"
            if self.spilled >= SPILL_LIMIT
            else "all of it is"
        )
        return (
            f"\n[output was {self.seen} bytes; {kept} in {self.spill}:"
            f" files.read(path, start_line=...) reads it, await files.find(pattern, path) searches it]\n"
        )

    def tail(self, limit: int = PREVIEW) -> bytes:
        """The last `limit` bytes written, at most PREVIEW."""
        limit = min(limit, PREVIEW)
        if limit <= 0:
            return b""
        source = self.data if self._tail is None else self._tail
        return bytes(source[-limit:])

    def read(self, offset: int = 0, limit: int = 4000) -> str:
        start = max(0, offset)
        return self.data[start : start + min(max(0, limit), PREVIEW)].decode(
            "utf-8", errors="ignore"
        )

    def preview(self, status: str = "ok") -> str:
        if status == "ok":
            return self.read(0, PREVIEW)
        return self.tail().decode("utf-8", errors="ignore")

    def attach(self, data: bytes) -> str:
        """Queue one image for this cell's result; raises ValueError past the limits."""
        mime = image_type(data)
        if mime is None:
            raise ValueError("image must be PNG, JPEG, or WebP bytes")
        found = image_header(data)
        # A header this parser cannot read is left for the daemon to judge.
        if found is not None:
            _, width, height, _ = found
            if not image_complete(data, found):
                raise ValueError(
                    f"this {len(data)}-byte {mime} stops before its {IMAGE_ENDS[mime]}: "
                    "the data was cut short, so read the whole file before showing it"
                )
            if self.max_edge is not None and max(width, height) > self.max_edge:
                raise ValueError(
                    f"{width}x{height} image is over this model's {self.max_edge}px edge limit"
                )
        if len(self.images) >= MAX_IMAGES:
            raise ValueError(f"a cell returns at most {MAX_IMAGES} images")
        if sum(map(len, self.images)) + len(data) > MAX_IMAGE_BYTES:
            raise ValueError(
                f"a cell's images total at most {MAX_IMAGE_BYTES} bytes; "
                f"this {len(data)}-byte image does not fit"
            )
        self.images.append(data)
        return f"{mime}, {len(data)} bytes"

    def encoded_images(self) -> list[str]:
        return [base64.b64encode(image).decode("ascii") for image in self.images]


def image_size(data: bytes) -> tuple[str, int, int] | None:
    """MIME type, width and height of a whole image, or None. A port of
    `inspect` in image.gleam, which stays the authority: the daemon checks
    every image again, and image_header_parity_test holds the two equal."""
    found = image_header(data)
    if found is None or not image_complete(data, found):
        return None
    return found[:3]


def image_header(data: bytes) -> tuple[str, int, int, int] | None:
    """MIME type, width, height, and where image_complete looks for the end."""
    if data[:16] == b"\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR" and len(data) >= 24:
        width, height = struct.unpack(">II", data[16:24])
        return ("image/png", width, height, 8) if width > 0 and height > 0 else None
    if data[:2] == b"\xff\xd8":
        return jpeg_size(data, 2)
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP" and len(data) >= 12:
        if struct.unpack("<I", data[4:8])[0] + 8 == len(data):
            size = webp_size(data, 12)
            return None if size is None else (*size, len(data))
    return None


IMAGE_ENDS = {"image/png": "IEND chunk", "image/jpeg": "end-of-image marker"}


def image_complete(data: bytes, header: tuple[str, int, int, int]) -> bool:
    """A PNG's chunks run whole up to IEND; a JPEG has its end-of-image marker
    after the frame header (stuffed entropy data never forges one). WebP's
    RIFF size already covers the whole file."""
    mime, _, _, at = header
    if mime == "image/png":
        while at + 12 <= len(data):
            size, kind = struct.unpack(">I4s", data[at : at + 8])
            if size == 0 and kind == b"IEND":
                return True
            at += 12 + size
        return False
    if mime == "image/jpeg":
        return data.find(b"\xff\xd9", at) >= 0
    return True


JPEG_FRAMES = {0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7}
JPEG_FRAMES |= {0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF}


def jpeg_size(data: bytes, at: int) -> tuple[str, int, int, int] | None:
    while True:
        at = data.find(b"\xff", at)
        if at < 0:
            return None
        at += 1
        while at < len(data) and data[at] == 0xFF:
            at += 1
        if at >= len(data):
            return None
        marker = data[at]
        if marker in (0xD8, 0x01) or 0xD0 <= marker <= 0xD7:
            at += 1
            continue
        if at + 3 > len(data):
            return None
        length = struct.unpack(">H", data[at + 1 : at + 3])[0]
        end = at + 1 + length
        if length < 2 or end > len(data):
            return None
        if marker in JPEG_FRAMES:
            frame = data[at + 3 : end]
            if len(frame) < 5:
                return None
            height, width = struct.unpack(">HH", frame[1:5])
            if width > 0 and height > 0:
                return ("image/jpeg", width, height, end)
            return None
        if marker in (0xDA, 0xD9):
            return None
        at = end


def webp_size(data: bytes, at: int) -> tuple[str, int, int] | None:
    while at + 8 <= len(data):
        kind = data[at : at + 4]
        size = struct.unpack("<I", data[at + 4 : at + 8])[0]
        body = data[at + 8 :]
        if kind == b"VP8X" and size == 10 and len(body) >= 10:
            width = int.from_bytes(body[4:7], "little") + 1
            height = int.from_bytes(body[7:10], "little") + 1
            return ("image/webp", width, height)
        if kind == b"VP8L" and size >= 5 and len(body) >= 5 and body[0] == 0x2F:
            bits = struct.unpack("<I", body[1:5])[0]
            return ("image/webp", (bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1)
        if kind == b"VP8 " and size >= 10 and len(body) >= 10:
            if body[3:6] == b"\x9d\x01\x2a":
                width, height = struct.unpack("<HH", body[6:10])
                width, height = width & 0x3FFF, height & 0x3FFF
                return ("image/webp", width, height) if width and height else None
        at += 8 + size + size % 2
        if at > len(data):
            return None
    return None


def image_type(data: bytes) -> str | None:
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png"
    if data.startswith(b"\xff\xd8"):
        return "image/jpeg"
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "image/webp"
    return None
