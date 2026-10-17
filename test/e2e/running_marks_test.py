"""Stopped turns and deleted sessions release their daemon-wide running marks."""

import json
import threading
import unittest

from harness import Albedo, Provider, ROOT, exclusive, text, wait_until
from inspect_support import Inspection


class RunningMarksTest(unittest.TestCase):
    # exclusive: enables inspection at daemon startup
    @exclusive
    def test_completed_closed_and_deleted_sessions_release_running_marks(self):
        ready, release = threading.Event(), threading.Event()
        self.addCleanup(release.set)

        def script(_request):
            ready.set()
            if not release.wait(30):
                raise AssertionError("test did not release the provider")
            return text("finished")

        provider = Provider(script)
        self.addCleanup(provider.close)
        with Albedo(
            provider,
            prepare=lambda app: app.daemon.env.update(ALBEDO_INSPECT="1"),
        ) as app:
            inspection = Inspection(app, ROOT / "test/e2e/albedo_running_probe.erl")
            for ending in ("completed", "closed", "deleted"):
                with self.subTest(ending=ending):
                    ready.clear()
                    release.clear()
                    session = app.session()
                    arguments = f"[<<{json.dumps(session)}>>]"
                    self.assertEqual(
                        inspection.call_json("state", arguments),
                        {"running": False, "records": 0},
                    )
                    app.prompt(session, ending).close()
                    try:
                        self.assertTrue(ready.wait(20), "provider was not reached")
                        self.assertEqual(
                            inspection.call_json("state", arguments),
                            {"running": True, "records": 1},
                        )
                        if ending == "completed":
                            release.set()
                            app.idle(session)
                        elif ending == "closed":
                            self.assertEqual(
                                inspection.call("close", arguments), "closed"
                            )
                        else:
                            path = f"/sessions/{session}?view=configuration"
                            with app.api(path) as response:
                                response.read()
                                revision = response.headers["ETag"]
                            path += (
                                "&scope=subtree&family_revision="
                                + app.family_revision(session)
                            )
                            app.api(
                                path, method="DELETE", headers={"If-Match": revision}
                            ).close()
                        wait_until(
                            lambda: (
                                inspection.call_json("state", arguments)
                                == {"running": False, "records": 0}
                            ),
                            10,
                            "stopped session retained its running mark",
                        )
                    finally:
                        release.set()
