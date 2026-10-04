"""Long cells detach without losing output, deadlines, or completion wakes."""

import json
import time
import unittest

from harness import Albedo, Provider, Reply, exclusive, python, text


def user_text(request):
    return next(
        (
            item.get("content", "")
            for item in reversed(request["messages"])
            if item.get("role") == "user"
        ),
        "",
    )


def wait_for(predicate, timeout=40):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if result := predicate():
            return result
        time.sleep(0.1)
    raise AssertionError("background cell did not wake session")


@exclusive
class CellBackgroundTests(unittest.TestCase):
    def setUp(self):
        self.results = []
        self.read_before_idle = False
        self.deadline = False
        self.synchronous = False
        self.cell_id = None

        def script(request):
            last = request["messages"][-1]
            user = user_text(request)
            if last.get("role") == "tool":
                result = json.loads(last["content"])
                self.results.append(result)
                if result.get("status") == "backgrounded":
                    self.cell_id = result["cell_id"]
                return text("waiting for the background cell")
            if "background python cells finished" in user:
                return text("completion received")
            if "start cell" in user:
                code = (
                    "import asyncio\n"
                    "cell_gate = asyncio.Event()\n"
                    "cell_done = asyncio.Event()\n"
                    "print('before detach')\n"
                    "await cell_gate.wait()\n"
                    "print('after detach')\n"
                    "cell_done.set()\n"
                    "{'answer': 42}"
                )
                if self.synchronous:
                    code = "import time\nprint('before detach')\ntime.sleep(10)\nprint('after detach')"
                if self.deadline:
                    return Reply(
                        "python", tool_arguments={"code": code, "timeout_ms": 1800}
                    )
                return python(code)
            if "release cell" in user:
                code = "print('other cell output')\ncell_gate.set()"
                if self.read_before_idle:
                    code += f"\nawait cell_done.wait()\nprint(output.read({self.cell_id!r}))"
                return python(code)
            if "cancel cell" in user:
                return python(f"print(await cells.cancel({self.cell_id!r}))")
            if "inspect cell" in user:
                return python(
                    f"print(await cells.info({self.cell_id!r}))\nprint(output.read({self.cell_id!r}))"
                )
            return text("done")

        def prepare(app):
            app.env["ALBEDO_CELL_BACKGROUND_SECONDS"] = "0.5"
            app.env["ALBEDO_IDLE_SECONDS"] = "2"

        self.provider = Provider(script)
        self.addCleanup(self.provider.close)
        self.app = Albedo(self.provider, prepare=prepare)
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)

    def prompt(self, session, message):
        self.app.prompt(session, message).close()
        self.app.idle(session)

    def wakes(self):
        return [
            record
            for record in self.provider.requests
            if "background python cells finished" in user_text(record["request"])
        ]

    def start(self):
        session = self.app.session()
        self.prompt(session, "start cell")
        result = self.results[0]
        self.assertEqual(result["status"], "backgrounded")
        self.assertIn("before detach", result["output"])
        self.assertIn("do NOT poll or sleep", result["output"])
        self.assertIn("wake automatically", result["output"])
        return session

    def test_cell_wakes_once_and_keeps_its_capture_separate(self):
        session = self.start()
        self.prompt(session, "inspect cell")
        self.assertIn("'status': 'started'", self.results[-1]["output"])
        self.assertIn("before detach", self.results[-1]["output"])
        self.prompt(session, "release cell")
        self.assertEqual(self.results[-1]["output"].strip(), "other cell output")
        wait_for(lambda: self.wakes())
        self.app.idle(session)
        self.assertEqual(len(self.wakes()), 1)
        notes = [
            entry
            for entry in self.app.history(session)["items"]
            if entry["kind"] == "note"
            and any(
                part["kind"] == "text" and "cell finished" in part["text"]
                for part in entry["content"]
            )
        ]
        self.assertEqual(len(notes), 1)
        shown = next(
            part["text"] for part in notes[0]["content"] if part["kind"] == "text"
        )
        self.assertTrue(shown.startswith("cell finished (status=ok"), shown)
        # the transcript names the code, the model's notice the cell id
        self.assertTrue(shown.endswith("import asyncio"), shown)
        self.assertNotIn("<system-note>", shown)
        self.assertIn(self.cell_id, user_text(self.wakes()[0]["request"]))
        self.prompt(session, "inspect cell")
        self.assertIn("'status': 'ok'", self.results[-1]["output"])
        self.assertIn("after detach", self.results[-1]["output"])
        self.assertIn("{'answer': 42}", self.results[-1]["output"])
        self.assertNotIn("other cell output", self.results[-1]["output"])
        time.sleep(2.5)
        self.assertEqual(len(self.wakes()), 1)

    def test_reading_finished_output_suppresses_the_wake(self):
        self.read_before_idle = True
        session = self.start()
        self.prompt(session, "release cell")
        self.assertIn("after detach", self.results[1]["output"])
        time.sleep(2.5)
        self.assertEqual(self.wakes(), [])

    def test_original_deadline_interrupts_the_background_cell(self):
        self.deadline = True
        session = self.start()
        wait_for(lambda: self.wakes())
        self.app.idle(session)
        self.assertIn("status=interrupted", user_text(self.wakes()[0]["request"]))
        self.prompt(session, "inspect cell")
        self.assertIn("'status': 'interrupted'", self.results[-1]["output"])

    def test_background_cell_survives_idle_reaping_and_daemon_restart(self):
        session = self.start()
        time.sleep(4)
        self.app.restart()
        self.prompt(session, "release cell")
        wait_for(lambda: self.wakes())
        self.app.idle(session)
        self.assertEqual(len(self.wakes()), 1)
        self.assertIn("status=ok", user_text(self.wakes()[0]["request"]))

    def test_cancelled_background_cell_does_not_wake(self):
        session = self.start()
        self.prompt(session, "cancel cell")
        self.assertEqual(self.results[1]["output"].strip(), "True")
        time.sleep(2.5)
        self.prompt(session, "inspect cell")
        self.assertIn("'status': 'interrupted'", self.results[-1]["output"])
        self.assertEqual(self.wakes(), [])

    def test_synchronous_cell_returns_early_and_keeps_its_deadline(self):
        self.synchronous = True
        self.deadline = True
        session = self.start()
        wait_for(lambda: self.wakes())
        self.app.idle(session)
        self.assertEqual(len(self.wakes()), 1)
        self.assertIn("status=interrupted", user_text(self.wakes()[0]["request"]))
