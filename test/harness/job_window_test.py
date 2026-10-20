"""A page of a job's output, for a viewer that keeps reading from where it ended.

Pages are byte ranges cut on characters: a viewer that continues from a page's
end must lose none of what the job wrote, even where a pipe read split a
character or a page boundary fell inside one. E2E sees one job's whole output;
this holds every boundary and the output a capture no longer keeps.
"""

from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "priv" / "python"))
from albedo_capture import PREVIEW, RETAIN, Capture  # noqa: E402
from albedo_output import read_window  # noqa: E402

TEXT = "héllo wörld — ✓ 漢字 🙂\n" * 40


def written(data: bytes) -> Capture:
    capture = Capture("job", "job")
    capture.write_bytes(data)
    return capture


def read_all(capture: Capture, limit: int, finished: bool) -> str:
    shown, offset = "", 0
    while offset < capture.seen:
        start, end, text = read_window(capture, offset, limit, finished)
        assert start == offset
        if end == offset:
            break
        shown, offset = shown + text, end
    return shown


class ReadWindowTest(unittest.TestCase):
    def test_pages_of_any_size_reassemble_the_output(self):
        capture = written(TEXT.encode())
        for limit in (4, 5, 7, 64, 1000, PREVIEW):
            with self.subTest(limit=limit):
                self.assertEqual(read_all(capture, limit, True), TEXT)
                self.assertEqual(read_all(capture, limit, False), TEXT)

    def test_a_character_still_arriving_waits_for_the_page_after_it(self):
        capture = written(b"ab\xe6\xbc")  # the first two bytes of 漢
        self.assertEqual(read_window(capture, 0, 100, False), (0, 2, "ab"))
        capture.write_bytes(b"\xa2")
        self.assertEqual(read_window(capture, 2, 100, False), (2, 5, "漢"))

    def test_a_finished_job_shows_a_broken_character_at_its_end(self):
        capture = written(b"ab\xe6\xbc")
        self.assertEqual(read_window(capture, 0, 100, True), (0, 4, "ab\ufffd"))

    def test_the_end_of_the_output_starts_on_a_character(self):
        data = ("é" * 75_000 + "\n").encode()  # two bytes each
        capture = written(data)
        start, end, text = read_window(capture, None, 1000, False)
        self.assertEqual((start, end), (149_002, len(data)))  # 149_001 is inside one
        self.assertEqual(text, "é" * 499 + "\n")

    def test_a_page_past_the_end_is_empty(self):
        capture = written(b"abc")
        self.assertEqual(read_window(capture, 99, 10, False), (3, 3, ""))

    def test_lost_output_is_refused_but_the_end_of_it_is_not(self):
        capture = written(b"x" * (RETAIN + 3 * PREVIEW))  # no spill file here
        self.assertIsNone(capture.spill)
        with self.assertRaises(LookupError):
            read_window(capture, RETAIN + 10, 100, False)
        self.assertEqual(read_window(capture, 0, 100, False)[2], "x" * 100)
        start, end, text = read_window(capture, None, 100, False)
        self.assertEqual(
            (start, end, len(text)), (capture.seen - 100, capture.seen, 100)
        )

    def test_a_page_that_cannot_hold_a_character_is_refused(self):
        capture = written(b"abc")
        for offset, limit in ((-1, 10), (0, 3), (0, PREVIEW + 1)):
            with self.assertRaises(ValueError):
                read_window(capture, offset, limit, False)


if __name__ == "__main__":
    unittest.main()
