"""A restarted kernel gets back its helpers, not only its variables.

Saved state is written when an idle kernel is released and read when the next
turn opens a new one, so these scenarios run through the real daemon: the
restore path lives in the kernel and the notice in the daemon.
"""

import os
import pickle
import time
import unittest

from harness import Albedo, Provider, exclusive, python, text

IDLE_SECONDS = 1
BIG_DEFINITION = "def big():\n    return '" + "x" * 40000 + "'\n"

DEFINE = (
    "import json\n"
    "import os.path\n"
    "import xml.dom\n"
    "def helper(x):\n    return x * 2\n"
    "class Box:\n    def __init__(self, v):\n        self.v = v\n"
    "answer = 7\n"
    "def rebound():\n    return 1\n"
    "if answer:\n    rebound = 5\n" + BIG_DEFINITION + "blob = bytes(9 * 1024 * 1024)\n"
)
FAIL = "def survivor():\n    return 'alive'\nraise RuntimeError('boom')"
RECALL = (
    "print('RESULT', helper(21), Box(3).v, json.dumps([1]), answer, rebound,\n"
    "      survivor(), os.path.basename('a/b'), xml.dom.__name__,\n"
    "      'big' in globals(), 'blob' in globals())"
)
LEGACY = "print('LEGACY', legacy)"


def latest_user(request):
    return [item["content"] for item in request["input"] if item.get("role") == "user"][
        -1
    ]


def wait_until(condition, seconds, message):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if condition():
            return
        time.sleep(0.1)
    raise AssertionError(message)


@exclusive
class KernelStateTests(unittest.TestCase):
    def setUp(self):
        cells = {"define": DEFINE, "fail": FAIL, "recall": RECALL, "legacy": LEGACY}

        def script(request):
            if request["input"][-1].get("role") == "user":
                prompt = latest_user(request).split("<system-note>")[0]
                if prompt in cells:
                    return python(cells[prompt])
            return text("ok")

        self.provider = Provider(script)
        self.addCleanup(self.provider.close)
        self.app = Albedo(
            self.provider,
            protocol="responses",
            prepare=lambda app: app.env.update(ALBEDO_IDLE_SECONDS=str(IDLE_SECONDS)),
        )
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)

    def state(self, session):
        return self.app.home / "kernels" / f"{session}.state"

    def turn(self, session, prompt):
        self.app.prompt(session, prompt).close()
        self.app.idle(session)

    def saved_after(self, session, since):
        """The idle kernel was released again: its state file is newer than `since`."""
        wait_until(
            lambda: (
                self.state(session).exists()
                and self.state(session).stat().st_mtime_ns > since
            ),
            15,
            "the idle kernel was not saved",
        )

    def outputs(self):
        return "".join(
            item.get("output", "")
            for item in self.provider.requests[-1]["request"]["input"]
        )

    def test_helpers_classes_imports_and_failed_cells_survive_a_restart(self):
        session = self.app.session()
        self.turn(session, "define")
        self.saved_after(session, 0)
        saved = self.state(session).stat().st_mtime_ns
        self.turn(session, "fail")
        self.saved_after(session, saved)
        self.turn(session, "recall")
        output = self.outputs()
        self.assertIn("RESULT 42 3 [1] 7 5 alive b xml.dom False False", output)
        notice = latest_user(self.provider.requests[-2]["request"])
        self.assertIn("re-run from source", notice)
        self.assertIn("helper", notice)

    def test_a_state_file_in_the_old_format_still_restores_its_variables(self):
        session = self.app.session()
        self.turn(session, "define")
        self.saved_after(session, 0)
        legacy = {"cwd": os.getcwd(), "names": {"legacy": pickle.dumps(5)}}
        self.state(session).write_bytes(pickle.dumps(legacy))
        self.turn(session, "legacy")
        self.assertIn("LEGACY 5", self.outputs())
