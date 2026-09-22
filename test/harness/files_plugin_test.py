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
        self.output, self.exit_code = output, exit_code

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
        load_plugins(["files"], self.api, self.namespace)
        self.assertIsInstance(self.namespace["files"], plugin.Files)

    def test_read_numbers_lines_and_bounds_its_window(self):
        path = self.write("sample.txt", "".join(f"line {n}\n" for n in range(1, 21)))
        files = plugin.Files()
        self.assertEqual(files.read(str(path), start_line=2, end_line=3),
                         "     2 | line 2\n     3 | line 3")
        bounded = files.read(str(path), limit=40)
        self.assertIn("more lines; read again with start_line=", bounded)
        self.assertLess(len(bounded.splitlines()), 20)
        self.assertIn("nothing at line 99", files.read(str(path), start_line=99))
        with self.assertRaises(ValueError):
            files.read(str(path), start_line=0)

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

        with patch.object(plugin.jobs, "bash", fake_bash), \
             patch.object(plugin.jobs, "preview_limit", 65_536, create=True), \
             patch.object(plugin, "_which", lambda name: "/usr/bin/rg"):
            found = self.loop.run_until_complete(
                plugin.Files().find("needle", str(self.root), glob="*.py"))
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


if __name__ == "__main__":
    unittest.main()
