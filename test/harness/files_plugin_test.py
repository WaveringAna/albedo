"""The files plugin: bounded reads, guarded exact edits, supervised search."""
import asyncio
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "priv" / "python"))
from albedo_api import PythonApi, load_plugins
from albedo_plugins import files as plugin


class FakeJob:
    """What `bash(command)` returns: an awaitable handle owning its output."""

    def __init__(self, output, exit_code=0):
        self.output, self.exit_code, self.timed_out = output, exit_code, False

    def __await__(self):
        async def settled():
            return self
        return settled().__await__()

    def tail(self, _limit):
        return self.output


class FilesPluginTest(unittest.TestCase):
    def setUp(self):
        self.loop = asyncio.new_event_loop()
        self.addCleanup(self.loop.close)
        self.api = PythonApi(self.loop, None, RuntimeError, None, 100,
                             lambda event: None, lambda close: None, lambda _: None)
        self.namespace = {"__name__": "__main__", "cells": object(), "output": object()}
        self.root = Path(tempfile.mkdtemp(prefix="albedo-files-"))

    def write(self, name, content):
        path = self.root/name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
        return path

    def test_setup_binds_one_namespace_object(self):
        self.loop.run_until_complete(load_plugins(["files"], self.api, self.namespace))
        self.assertIsInstance(self.namespace["files"], plugin.Files)

    def test_read_numbers_lines_and_bounds_its_window(self):
        path = self.write("sample.txt", "".join(f"line {n}\n" for n in range(1, 21)))
        files = plugin.Files()
        self.assertEqual(files.read(str(path), start_line=2, end_line=3),
                         "     2 | line 2\n     3 | line 3")
        bounded = files.read(str(path), max_chars=40)
        self.assertIn("stopped at max_chars=40 characters", bounded)
        self.assertIn("read again with start_line=", bounded)
        self.assertLess(len(bounded.splitlines()), 20)
        self.assertIn("nothing at line 99", files.read(str(path), start_line=99))
        with self.assertRaises(ValueError):
            files.read(str(path), start_line=0)

    def test_read_keeps_long_lines_intact_or_explains_how_to_retry(self):
        long_line = "x" * 300 + " unique ending"
        path = self.write("long.txt", f"short\n{long_line}\ntail\n")
        files = plugin.Files()
        self.assertEqual(files.read(str(path), start_line=2, end_line=2),
                         f"     2 | {long_line}")
        bounded = files.read(str(path), start_line=2, end_line=2, max_chars=100)
        self.assertIn("line 2 is", bounded)
        self.assertIn("start_line=2, end_line=2, max_chars=", bounded)
        self.assertNotIn("     2 | x", bounded)
        self.assertIn("read again with start_line=2", files.read(str(path), max_chars=20))

    # Every model read `limit` as a line count; one asked for lines 144-400
    # with limit=400, got six lines of a character budget, and fell back to sed.
    def test_limit_counts_lines(self):
        path = self.write("many.txt", "".join(f"line {n}\n" for n in range(1, 501)))
        files = plugin.Files()
        window = files.read(str(path), start_line=144, end_line=400, limit=400)
        self.assertEqual(len(window.splitlines()), 257)
        self.assertTrue(window.endswith("   400 | line 400"))
        capped = files.read(str(path), start_line=10, limit=3)
        self.assertEqual(capped.splitlines()[:3],
                         ["    10 | line 10", "    11 | line 11", "    12 | line 12"])
        self.assertIn("limit=3 lines reached", capped)
        self.assertIn("start_line=13", capped)
        with self.assertRaises(ValueError):
            files.read(str(path), limit=0)

    def test_edit_replaces_one_exact_occurrence_and_keeps_the_mode(self):
        path = self.write("edit.py", "alpha\nbeta\ngamma\n")
        path.chmod(0o640)
        files = plugin.Files()
        self.assertIn("Edited", files.edit(str(path), "beta", "delta"))
        self.assertEqual(path.read_text(), "alpha\ndelta\ngamma\n")
        self.assertEqual(path.stat().st_mode & 0o777, 0o640)
        self.assertEqual(sorted(entry.name for entry in self.root.iterdir()), ["edit.py"])

    def test_a_repeated_string_reports_its_line_ranges_until_a_hint_chooses(self):
        path = self.write("repeat.py", "x = 1\nvalue = 2\ny = 3\nvalue = 2\n")
        files = plugin.Files()
        with self.assertRaises(ValueError) as failure:
            files.edit(str(path), "value = 2", "value = 9")
        message = str(failure.exception)
        self.assertIn("found 2 occurrences", message)
        self.assertIn("lines 2, 4", message)
        self.assertIn("candidate 1 of 2", message)
        self.assertEqual(path.read_text(), "x = 1\nvalue = 2\ny = 3\nvalue = 2\n")
        with self.assertRaisesRegex(ValueError, "line_hint=3 is inside none"):
            files.edit(str(path), "value = 2", "value = 9", line_hint=3)
        files.edit(str(path), "value = 2", "value = 9", line_hint=4)
        self.assertEqual(path.read_text(), "x = 1\nvalue = 2\ny = 3\nvalue = 9\n")

    def test_a_missing_string_or_file_explains_what_is_there(self):
        path = self.write("close.py", "def handler(request):\n    return request\n")
        files = plugin.Files()
        with self.assertRaises(ValueError) as failure:
            files.edit(str(path), "def handler(req):", "def handler(value):")
        self.assertIn("closest candidate lines 1-1", str(failure.exception))
        with self.assertRaises(FileNotFoundError) as missing:
            files.edit(str(self.root/"clos.py"), "a", "b")
        self.assertIn("nearby paths", str(missing.exception))

    def test_find_parses_ripgrep_through_one_supervised_job(self):
        commands = []
        matches = "\n".join(json.dumps(event) for event in [
            {"type": "begin"},
            {"type": "match", "data": {"path": {"text": "a.py"}, "line_number": 7,
                                       "lines": {"text": "needle here\n"}}},
        ])

        def fake_bash(command, timeout=None):
            commands.append(command)
            return FakeJob(matches)

        forgotten = []
        with patch.object(plugin.jobs, "bash", fake_bash), \
             patch.object(plugin.jobs, "forget", forgotten.append), \
             patch.object(plugin.jobs, "preview_limit", 65_536, create=True), \
             patch.object(plugin, "_which", lambda name: "/usr/bin/rg"):
            found = self.loop.run_until_complete(
                plugin.Files().find("needle", str(self.root), glob="*.py"))
        # The search job is the plugin's own; it must not linger in jobs or output.list().
        self.assertEqual(len(forgotten), 1)
        self.assertEqual([match.to_dict() for match in found],
                         [{"path": "a.py", "line": 7, "text": "needle here"}])
        self.assertIn("rg --json -g '*.py' -e needle", commands[0])
        self.assertIn("| head -n", commands[0])

    def test_search_falls_back_to_python_when_ripgrep_is_absent(self):
        self.write("nested/one.py", "alpha\nneedle\n")
        self.write("nested/two.txt", "needle\n")
        files = plugin.Files()
        with patch.object(plugin, "_which", lambda name: None):
            found = self.loop.run_until_complete(files.find("needle", str(self.root), glob="*.py"))
            names = self.loop.run_until_complete(files.paths("one", str(self.root)))
        self.assertEqual([(Path(match.path).name, match.line) for match in found], [("one.py", 2)])
        self.assertEqual([Path(name).name for name in names], ["one.py"])
        self.assertEqual(list(files.ls(str(self.root))), ["nested/"])

    # Agents kept awaiting the synchronous calls and forgetting to await the
    # searches; both spellings of the synchronous calls must work, and a
    # forgotten await must say what to do instead of printing a coroutine.
    def test_ready_results_may_be_awaited_or_used_directly(self):
        path = self.write("sample.py", "alpha\nbeta\n")
        files = plugin.Files()

        async def awaited():
            return (await files.read(str(path)), await files.ls(str(self.root)),
                    await files.edit(str(path), "beta", "gamma"),
                    await files.write(str(self.root/"new.txt"), "x"))

        read, listing, edited, wrote = self.loop.run_until_complete(awaited())
        self.assertEqual(read, "     1 | alpha\n     2 | beta")
        self.assertEqual(list(listing), ["sample.py"])
        self.assertIn("Edited", edited)
        self.assertIn("Wrote", wrote)
        self.assertIsInstance(files.read(str(path)), str)

    def test_an_unawaited_search_explains_itself(self):
        files = plugin.Files()
        pending = files.find("needle", str(self.root))
        self.assertIn("await files.find(", repr(pending))
        with self.assertRaisesRegex(TypeError, r"use `await files\.find"):
            list(pending)
        with self.assertRaisesRegex(TypeError, r"use `await files\.paths"):
            len(files.paths("x", str(self.root)))

    # Agents shelled out to `grep -B2 -A8` and multi-path greps because find
    # had no context and one path; they also wrote `await files.find(...)[:35]`,
    # which slices before it awaits, and `files.read(path, 600, 720)`.
    def test_find_context_paths_slicing_and_positional_reads(self):
        self.write("a/one.py", "zero\nalpha\nneedle\nbeta\nneedle\ngamma\n")
        self.write("b/two.py", "needle\n")
        files = plugin.Files()
        with patch.object(plugin, "_which", lambda name: None):
            found = self.loop.run_until_complete(files.find(
                "needle", [str(self.root/"a"), str(self.root/"b")], context=1))
            first = self.loop.run_until_complete(files.find("needle", str(self.root/"a"))[:1])
            one = self.loop.run_until_complete(files.find("needle", str(self.root/"a"))[0])
        rows = [(Path(item.path).name, item.line, item.context) for item in found]
        self.assertEqual(rows, [("one.py", 2, True), ("one.py", 3, False), ("one.py", 4, True),
                                ("one.py", 5, False), ("one.py", 6, True), ("two.py", 1, False)])
        self.assertTrue(str(found[0]).endswith("one.py-2- alpha"))
        self.assertTrue(str(found[1]).endswith("one.py:3: needle"))
        self.assertEqual(len(first), 1)
        self.assertEqual(one.line, 3)
        path = self.root/"a"/"one.py"
        self.assertEqual(files.read(str(path), 2, 3), "     2 | alpha\n     3 | needle")
        with self.assertRaises(ValueError):
            files.find("x", context=51)

    # An agent searched paths("*.md"), got [], and concluded nothing matched;
    # reading a missing file raised a bare FileNotFoundError.
    def test_path_globs_and_missing_file_diagnostics(self):
        self.write("notes.md", "x")
        self.write("sub/README.md", "y")
        self.write("a.py", "z")
        files = plugin.Files()
        with patch.object(plugin, "_which", lambda name: None):
            globbed = self.loop.run_until_complete(files.paths("*.md", str(self.root)))
            text = self.loop.run_until_complete(files.paths("readme", str(self.root)))
        self.assertEqual(sorted(Path(name).name for name in globbed), ["README.md", "notes.md"])
        self.assertEqual([Path(name).name for name in text], ["README.md"])
        with self.assertRaisesRegex(FileNotFoundError, "nearby paths: .*notes.md"):
            files.read(str(self.root/"note.md"))
        with self.assertRaisesRegex(IsADirectoryError, r"files\.ls"):
            files.read(str(self.root/"sub"))


if __name__ == "__main__":
    unittest.main()
