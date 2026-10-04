"""Output retention invariants the daemon cannot observe through a cell result.

A capture keeps the first RETAIN bytes and the last PREVIEW bytes of what was
written, as bytes: a pipe chunk that splits a UTF-8 character must survive,
the tail must equal the true end of the stream whichever path wrote it, and
the memory held must stay within the two caps however much flows through.
"""

from pathlib import Path
import sys
import tempfile
import tracemalloc
from typing import cast
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "priv" / "python"))
import albedo_state  # noqa: E402
from albedo_capture import PREVIEW, RETAIN, Capture  # noqa: E402


def stream_of(capture: Capture, pieces) -> bytes:
    whole = bytearray()
    for piece in pieces:
        if isinstance(piece, str):
            capture.write(piece)
            whole += piece.encode("utf-8", errors="replace")
        else:
            capture.write_bytes(piece)
            whole += piece
    return bytes(whole)


class CaptureTest(unittest.TestCase):
    def test_a_character_split_across_pipe_chunks_is_kept_whole(self):
        capture = Capture("job", "job")
        text = "héllo wörld — ✓\n".encode()
        for cut in range(1, len(text)):
            capture.write_bytes(text[:cut])
            capture.write_bytes(text[cut:])
        self.assertEqual(capture.read(0, RETAIN), text.decode() * (len(text) - 1))
        self.assertNotIn("\ufffd", capture.tail().decode())

    def test_both_write_paths_agree_on_what_is_kept(self):
        for pieces in (
            ["x" * (RETAIN + 3 * PREVIEW)],  # one ASCII print past every cap
            ["x" * 10, "y" * (RETAIN + PREVIEW + 1), "tail"],
            ["ü" * (RETAIN + 10)],  # two bytes per character: the full encode
            [b"\xff" * 100, "ascii" * 100, b"\xe2\x9c\x93" * (RETAIN // 3)],
            ["short", b"bytes"],
        ):
            with self.subTest(pieces=[len(p) for p in pieces]):
                capture = Capture("c")
                whole = stream_of(capture, pieces)
                self.assertEqual(capture.seen, len(whole))
                self.assertEqual(bytes(capture.data), whole[:RETAIN])
                self.assertEqual(capture.tail(), whole[-PREVIEW:])
                self.assertEqual(capture.tail(16), whole[-16:])
                self.assertEqual(capture.tail(0), b"")

    def test_retained_bytes_stay_within_the_two_caps(self):
        for label, pieces in (
            ("pipe chunks", [bytes(range(256)) * 1000] * 40),
            ("small prints", ["some line of output\n"] * 300_000),
            ("one print", ["x" * (3 * RETAIN)]),
        ):
            with self.subTest(label):
                capture = Capture("c")
                whole = stream_of(capture, pieces)
                self.assertEqual(capture.seen, len(whole))
                self.assertEqual(len(capture.data), RETAIN)
                # bytearray growth slack is bounded; the buffers themselves are capped.
                held = sys.getsizeof(capture.data) + sys.getsizeof(capture._tail)
                self.assertLess(held, RETAIN + PREVIEW + PREVIEW // 4)

    def test_a_tail_buffer_exists_only_once_the_start_is_full(self):
        capture = Capture("c")
        capture.write("a" * (RETAIN - 1))
        self.assertIsNone(capture._tail)
        self.assertEqual(capture.tail(4), b"aaaa")
        capture.write("bb")
        self.assertIsNotNone(capture._tail)
        self.assertEqual(capture.tail(4), b"aabb")
        self.assertEqual(len(capture.data), RETAIN)

    def test_a_huge_ascii_print_is_not_encoded_whole(self):
        capture = Capture("c")
        text = "z" * (64 * 1024 * 1024)
        tracemalloc.start()
        try:
            capture.write(text)
            _, peak = tracemalloc.get_traced_memory()
        finally:
            tracemalloc.stop()
        self.assertEqual(capture.seen, len(text))
        # The transient is a few retained-size pieces, not the 64 MiB text encoded.
        self.assertLess(peak, 4 * RETAIN)


class SnapshotBoundTest(unittest.TestCase):
    def test_an_oversized_value_costs_the_cap_not_its_size(self):
        namespace: dict[str, object] = {"big": list(range(4_000_000)), "small": [1]}
        target = Path(self.enterContext(tempfile.TemporaryDirectory()))
        tracemalloc.start()
        try:
            state = albedo_state.save_state(str(target / "state"), namespace, {}, set())
            _, peak = tracemalloc.get_traced_memory()
        finally:
            tracemalloc.stop()
        skipped = cast(list[dict[str, str]], state["skipped"])
        self.assertEqual(state["saved"], ["small"])
        self.assertEqual([item["name"] for item in skipped], ["big"])
        self.assertIn("per-variable cap", skipped[0]["reason"])
        self.assertLess(peak, 3 * albedo_state.STATE_MAX_VALUE)


if __name__ == "__main__":
    unittest.main()
