"""Finalized traces survive buffer release, nested evaluation, and late edits."""

import json
import unittest

from harness import Albedo, Provider, python, text


class TracesTests(unittest.TestCase):
    def setUp(self):
        self.code = ""
        self.provider = Provider(
            lambda request: (
                python(self.code)
                if request["messages"][-1].get("role") == "user"
                else text("done")
            )
        )
        self.addCleanup(self.provider.close)
        self.app = Albedo(self.provider)
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)
        self.session = self.app.session()

    def run_cell(self, code, status="ok"):
        self.code = code
        self.app.prompt(self.session, "execute this cell").close()
        self.app.idle(self.session)
        event = [
            event
            for event in self.app.events(self.session)
            if event.get("type") == "tool" and event.get("name") == "python"
        ][-1]
        result = json.loads(event["result"])
        self.assertEqual(result["status"], status, result)
        return result, event["trace"]

    def read_trace(self, id):
        result, _ = self.run_cell(
            f"import json\nprint(json.dumps(await cells.trace({id!r})))"
        )
        return json.loads(result["output"])

    def test_top_level_and_nested_traces_preserve_changes_for_all_outcomes(self):
        for status, ending in (
            ("ok", ""),
            ("error", "raise ValueError('failed')"),
            ("interrupted", "raise __import__('asyncio').CancelledError()"),
        ):
            with self.subTest(status=status):
                (self.app.workspace / "note.txt").write_text("before\n")
                (self.app.workspace / "binary.dat").unlink(missing_ok=True)
                source = (
                    """
import os
open('temporary.txt', 'w').write('after\\n')
os.replace('temporary.txt', 'note.txt')
open('note.txt').read()
open('binary.dat', 'wb').write(b'\\0binary')
"""
                    + ending
                )
                original, trace = self.run_cell(source, status)
                self.assertEqual(trace, self.read_trace(original["cell_id"]))
                self.assert_changes(trace)
                # The exact saved source runs as a separate nested cell.
                (self.app.workspace / "note.txt").write_text("before\n")
                (self.app.workspace / "binary.dat").unlink()
                parent, parent_trace = self.run_cell(
                    f"try:\n    await cells.run({original['cell_id']!r}, allow_partial=True)\n"
                    "except BaseException:\n    pass\nprint(cells.last_id)"
                )
                child = parent["output"].strip().splitlines()[-1]
                nested = self.read_trace(child)
                self.assert_changes(nested)
                self.run_cell(
                    f"assert (await cells.info({child!r}))['status'] == {status!r}"
                )
                self.assertEqual(parent_trace["changes"], [])

    def assert_changes(self, trace):
        changes = {change["path"].split("/")[-1]: change for change in trace["changes"]}
        self.assertNotIn("temporary.txt", changes)
        self.assertIn("-before", changes["note.txt"]["diff"])
        self.assertIn("+after", changes["note.txt"]["diff"])
        self.assertEqual(changes["binary.dat"]["kind"], "unavailable")
        self.assertTrue(
            any(
                activity["kind"] == "read" and activity["target"].endswith("note.txt")
                for activity in trace["activities"]
            )
        )

    def test_many_edit_heavy_cells_release_buffers_and_keep_old_traces(self):
        oldest = None
        oldest_trace = None
        for index in range(18):
            result, trace = self.run_cell(
                f"for index in range(20):\n    open(f'edit-{{index}}.txt', 'w').write({str(index)!r})\n"
                "open('edit-0.txt').read()"
            )
            self.assertTrue(trace["truncated"])
            self.assertTrue(trace["changes"])
            if oldest is None:
                oldest, oldest_trace = result["cell_id"], trace
        result, _ = self.run_cell("""
import __main__ as kernel
completed = [capture for capture in kernel.ARCHIVES.values() if capture.trace.sealed]
assert completed
assert all(not capture.trace.before and not capture.trace.activities for capture in completed)
print('released')
""")
        self.assertIn("released", result["output"])
        self.assertEqual(self.read_trace(oldest), oldest_trace)

    def test_late_background_edits_execute_without_changing_finalized_trace(self):
        result, trace = self.run_cell("""
import asyncio
import __main__ as kernel
late_gate = asyncio.Event()
async def late_edit():
    await late_gate.wait()
    open('late.txt', 'w').write('late\\n')
    open('late.txt').read()
late_task = asyncio.create_task(late_edit())
open('early.txt', 'w').write('early\\n')
""")
        self.run_cell(f"""
late_gate.set()
await late_task
capture = kernel.ARCHIVES[{result["cell_id"]!r}]
assert capture.trace.sealed
assert not capture.trace.before and not capture.trace.activities
""")
        self.assertEqual((self.app.workspace / "late.txt").read_text(), "late\n")
        self.assertEqual(self.read_trace(result["cell_id"]), trace)
