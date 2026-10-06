"""Idle kernel reaping persists Python state and explains restoration to the model."""

import sqlite3
import subprocess
import time
import unittest

from harness import alive, latest_user
from harness import Albedo, Provider, exclusive, python, text
from stream_support import StreamProbe


def notes_for(app, session, cursor):
    return [
        event["data"]["text"]
        for event in app.stream_page(session, cursor)["events"]
        if event.get("type") == "note"
    ]


# Short enough that the test waits seconds, long enough to outlast a turn.
IDLE_SECONDS = 2


def kernels(home):
    """Pids of the kernels whose run directory is under this daemon's home."""
    listing = subprocess.run(
        ["ps", "-axo", "pid=,command="], capture_output=True, text=True, check=True
    ).stdout
    return [
        int(line.split(None, 1)[0])
        for line in listing.splitlines()
        if "albedo_kernel.py" in line and f"{home}/run/" in line
    ]


# exclusive: changes the daemon idle timeout and counts all its kernels
@exclusive
class IdleReapTests(unittest.TestCase):
    def setUp(self):
        def script(request):
            if request["input"][-1].get("role") == "user":
                prompt = latest_user(request)
                if prompt.startswith("remember"):
                    return python("answer = 7\nrows = [1, 2, 3]")
                if prompt.startswith("recall"):
                    return python("print('recalled', answer, rows)")
            return text("ok")

        provider = Provider(script)
        self.addCleanup(provider.close)
        self.provider = provider
        self.app = Albedo(
            provider,
            protocol="responses",
            prepare=lambda app: app.env.update(
                ALBEDO_IDLE_SECONDS=str(IDLE_SECONDS), ALBEDO_INSPECT="1"
            ),
        )
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)

    def turn(self, session, prompt):
        self.app.prompt(session, prompt).close()
        self.app.idle(session)

    def test_idle_kernel_reaps_and_restores_variables_with_notices(self):
        app = self.app
        existing = set(kernels(app.home))
        session = app.session()
        cursor = app.stream_page(session)
        self.assertEqual(
            set(kernels(app.home)) - existing,
            set(),
            "session must not eagerly open a kernel",
        )
        self.turn(session, "remember this")
        self.assertEqual(len(set(kernels(app.home)) - existing), 1)
        deadline = time.monotonic() + IDLE_SECONDS * 4
        while time.monotonic() < deadline and set(kernels(app.home)) - existing:
            time.sleep(0.1)
        self.assertEqual(
            set(kernels(app.home)) - existing, set(), "idle kernel outlived its limit"
        )
        notes = notes_for(app, session, cursor)
        self.assertIn("released", notes[-1])
        self.assertIn("2 variables saved to disk", notes[-1])
        self.assertTrue((app.home / "kernels" / f"{session}.state").exists())

        self.turn(session, "recall them")
        prompt = latest_user(self.provider.requests[-1]["request"])
        self.assertTrue(prompt.startswith("recall them<system-note>"), prompt)
        self.assertIn("restored from disk: answer, rows", prompt)
        self.assertTrue(
            any(
                "recalled 7 [1, 2, 3]" in item.get("output", "")
                for item in self.provider.requests[-1]["request"]["input"]
            )
        )
        notes = notes_for(app, session, cursor)
        self.assertTrue(
            any("restored 2 variables from disk" in note for note in notes), notes
        )

    def test_reattached_kernel_without_a_loaded_session_is_released(self):
        app = self.app
        app.restart(prepare=lambda a: a.env.update(ALBEDO_IDLE_SECONDS="600"))
        session = app.session()
        self.turn(session, "remember this")
        with sqlite3.connect(app.home / "albedo.sqlite") as database:
            (kernel,) = database.execute(
                "SELECT pid FROM kernel_links WHERE session=?", (session,)
            ).fetchone()
        saved = app.home / "kernels" / f"{session}.state"
        self.assertFalse(saved.exists())
        # A crash leaves the kernel waiting; the next daemon reattaches it
        # without loading the session.
        app.restart(
            crash=True,
            prepare=lambda a: a.env.update(ALBEDO_IDLE_SECONDS=str(IDLE_SECONDS)),
        )
        deadline = time.monotonic() + IDLE_SECONDS * 5
        while time.monotonic() < deadline and alive(kernel):
            time.sleep(0.1)
        self.assertFalse(alive(kernel), "reattached kernel outlived its limit")
        self.assertTrue(saved.exists())
        self.turn(session, "recall them")
        self.assertTrue(
            any(
                "recalled 7 [1, 2, 3]" in item.get("output", "")
                for item in self.provider.requests[-1]["request"]["input"]
            )
        )

    def test_blocked_sweep_admits_one_worker_and_continues_after_owner_death(self):
        app = self.app
        held, survivor = app.session(), app.session()
        self.turn(held, "remember held values")
        self.turn(survivor, "remember surviving values")
        probe = StreamProbe(app)
        result = probe.call("maintenance_json", f'[<<"{held}">>]')
        self.assertEqual(result["admitted"], 1)
        self.assertEqual(result["outcome"], "completed")
        saved = app.home / "kernels" / f"{survivor}.state"
        deadline = time.monotonic() + IDLE_SECONDS * 4
        while not saved.exists() and time.monotonic() < deadline:
            time.sleep(0.1)
        self.assertTrue(saved.exists(), "one dead owner prevented survivor release")
        self.turn(survivor, "recall surviving values")
        self.assertTrue(
            any(
                "recalled 7 [1, 2, 3]" in item.get("output", "")
                for item in self.provider.requests[-1]["request"]["input"]
            )
        )
