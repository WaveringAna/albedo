"""Saved Python state expires with its idle session, and only then.

Expiry deletes files the daemon cannot recreate, so the bugs worth catching are
the ones that delete too much (a live kernel's file) or nothing at all (a type
mismatch once made the sweep a no-op), and only the real daemon exercises both.
"""

import os
import time
import unittest

from harness import latest_user, wait_until
from harness import Albedo, Provider, exclusive, python, text

IDLE_SECONDS = 1
EXPIRY_SECONDS = 3
LOST = (
    "<system-note>The python kernel got reset and all variables are lost</system-note>"
)


# exclusive: changes daemon idle/expiry sweep timing and tests startup cleanup
@exclusive
class StateExpiryTests(unittest.TestCase):
    def setUp(self):
        def script(request):
            if request["input"][-1].get("role") == "user":
                prompt = latest_user(request)
                if prompt.startswith("remember"):
                    return python("answer = 7")
                if prompt.startswith("pin"):
                    return python("job = run('sleep', '25')\nanswer = 8")
            return text("ok")

        self.provider = Provider(script)
        self.addCleanup(self.provider.close)
        self.app = Albedo(
            self.provider,
            protocol="responses",
            prepare=lambda app: app.env.update(
                ALBEDO_IDLE_SECONDS=str(IDLE_SECONDS),
                ALBEDO_STATE_EXPIRY_SECONDS=str(EXPIRY_SECONDS),
            ),
        )
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)

    def state(self, session):
        return self.app.home / "kernels" / f"{session}.state"

    def turn(self, session, prompt):
        self.app.prompt(session, prompt).close()
        self.app.idle(session)
        return latest_user(self.provider.requests[-1]["request"])

    def test_an_idle_session_loses_its_state_and_a_live_kernel_keeps_it(self):
        idle, live = self.app.session(), self.app.session()
        for session in (idle, live):
            self.turn(session, "remember this")
        wait_until(
            lambda: self.state(idle).exists() and self.state(live).exists(),
            15,
            "idle kernels were never saved",
        )
        # a background job pins this session's kernel, so it is not idle
        self.turn(live, "pin this")
        wait_until(
            lambda: not self.state(idle).exists(), 30, "an idle session kept its state"
        )
        self.assertTrue(self.state(live).exists(), "a live kernel lost its state")
        self.assertEqual(self.turn(idle, "recall it"), "recall it" + LOST)

    def test_old_orphan_state_goes_at_startup_and_a_young_one_stays(self):
        kernels = self.app.home / "kernels"
        kernels.mkdir(exist_ok=True)
        old, young = kernels / "orphan-old.state", kernels / "orphan-young.state"
        for path in (old, young):
            path.write_bytes(b"x")
        two_days_ago = time.time() - 2 * 86400
        os.utime(old, (two_days_ago, two_days_ago))
        self.app.restart()
        self.assertFalse(old.exists(), "an old orphan survived startup")
        self.assertTrue(young.exists(), "a young orphan was deleted")


# exclusive: changes daemon retention/idle timing and restarts the daemon
@exclusive
class StateRetentionTests(unittest.TestCase):
    def setUp(self):
        self.provider = Provider(
            lambda request: (
                python("answer = 7")
                if request["input"][-1].get("role") == "user"
                else text("ok")
            )
        )
        self.addCleanup(self.provider.close)
        self.app = Albedo(
            self.provider,
            protocol="responses",
            prepare=lambda app: app.env.update(
                ALBEDO_IDLE_SECONDS=str(IDLE_SECONDS),
                ALBEDO_STATE_EXPIRY_SECONDS=str(10 * 86400),
            ),
        )
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)

    def test_a_session_inside_its_retention_keeps_an_old_file(self):
        session = self.app.session()
        self.app.prompt(session, "remember this").close()
        self.app.idle(session)
        state = self.app.home / "kernels" / f"{session}.state"
        wait_until(state.exists, 15, "the idle kernel was never saved")
        two_days_ago = time.time() - 2 * 86400
        os.utime(state, (two_days_ago, two_days_ago))
        self.app.restart()
        time.sleep(3)  # the first periodic sweep runs within a second of startup
        self.assertTrue(state.exists(), "a session inside its retention lost its state")
