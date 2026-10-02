"""Idle kernel reaping persists Python state and explains restoration to the model."""

import subprocess
import time
import unittest

from harness import Albedo, Provider, exclusive, python, text


def notes_for(app, session, cursor):
    return [
        event["text"]
        for event in app.stream_page(session, cursor)["events"]
        if event.get("type") == "note"
    ]


# Short enough that the test waits seconds, long enough to outlast a turn.
IDLE_SECONDS = 2


def latest_user(request):
    return [item["content"] for item in request["input"] if item.get("role") == "user"][
        -1
    ]


def kernels(daemon_pid):
    listing = subprocess.run(
        ["ps", "-o", "pid=,ppid=,command=", "-ax"], capture_output=True, text=True
    )
    processes = {}
    for line in listing.stdout.splitlines():
        fields = line.split(maxsplit=2)
        if len(fields) == 3 and fields[0].isdigit() and fields[1].isdigit():
            processes[int(fields[0])] = (int(fields[1]), fields[2])
    owned, frontier = [], [daemon_pid]
    while frontier:
        parent = frontier.pop()
        for pid, (ppid, command) in processes.items():
            if ppid == parent:
                frontier.append(pid)
                if "albedo_kernel.py" in command:
                    owned.append(pid)
    return owned


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
            prepare=lambda app: app.env.update(ALBEDO_IDLE_SECONDS=str(IDLE_SECONDS)),
        )
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)

    def turn(self, session, prompt):
        self.app.prompt(session, prompt).close()
        self.app.idle(session)

    def test_idle_kernel_reaps_and_restores_variables_with_notices(self):
        app = self.app
        daemon = app.connection["pid"]
        existing = set(kernels(daemon))
        session = app.session()
        cursor = app.stream_page(session)
        self.assertEqual(
            set(kernels(daemon)) - existing,
            set(),
            "session must not eagerly open a kernel",
        )
        self.turn(session, "remember this")
        self.assertEqual(len(set(kernels(daemon)) - existing), 1)
        deadline = time.monotonic() + IDLE_SECONDS * 4
        while time.monotonic() < deadline and set(kernels(daemon)) - existing:
            time.sleep(0.1)
        self.assertEqual(
            set(kernels(daemon)) - existing, set(), "idle kernel outlived its limit"
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
