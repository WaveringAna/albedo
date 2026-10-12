"""Command mutations share conditional edits' checks, persistence, and context reset."""

import json
import os
from pathlib import Path
import threading
import unittest

from harness import Albedo, Provider, ROOT, exclusive, release_fifo, text, wait_until
from inspect_support import Inspection
from kernel_support import editable_daemon


@exclusive
class SessionConfigureTest(unittest.TestCase):
    """Isolated global defaults, catalog, inspection, and copied kernel startup."""

    marker: Path

    def setUp(self):
        self.provider = Provider(lambda _request: text("done"))
        self.addCleanup(self.provider.close)
        self.gate = None

        def prepare(app):
            app.daemon.env["ALBEDO_INSPECT"] = "1"
            catalog = {
                "fixture-cloud": {
                    "api": self.provider.url,
                    "models": {
                        model: {
                            "id": model,
                            "reasoning_options": [
                                {"type": "effort", "values": efforts}
                            ],
                        }
                        for model, efforts in {
                            "first": ["low", "high"],
                            "second": ["medium", "high"],
                            "third": ["low", "medium"],
                        }.items()
                    },
                }
            }
            (app.home / "models.json").write_text(json.dumps(catalog))
            app.write_extensions({"models": {"refreshHours": 0}})
            if (
                self._testMethodName
                == "test_commands_reject_changes_during_kernel_boot"
            ):
                launcher, bundle = editable_daemon(app.root)
                app.env["ALBEDO_DAEMON"] = str(launcher)
                self.gate = app.workspace / "kernel-gate"
                self.marker = app.workspace / "kernel-started"
                os.mkfifo(self.gate)
                gate = self.gate
                self.addCleanup(lambda: gate.exists() and release_fifo(gate))
                (bundle / "albedo_kernel.py").write_text(
                    "from pathlib import Path\n"
                    f"Path({str(self.marker)!r}).touch()\n"
                    f"open({str(self.gate)!r}, 'rb').read(1) if Path({str(self.gate)!r}).exists() else None\n"
                    "import runpy\n"
                    "runpy.run_module('albedo_cells', run_name='__main__', alter_sys=True)\n"
                )

        self.app = Albedo(
            self.provider,
            prepare=prepare,
            providers={
                "fixture": {
                    "extension": "openai",
                    "baseUrl": self.provider.url,
                    "apiKey": "fixture-key",
                    "model": "first",
                    "effort": "high",
                    "protocol": "responses",
                }
            },
        ).__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)
        self.session = self.app.session()
        self.inspection = Inspection(
            self.app, ROOT / "test/e2e/albedo_session_configure_probe.erl"
        )

    def read(self, path):
        with self.app.api(path) as response:
            return json.load(response)

    def configuration(self):
        return self.read(f"/sessions/{self.session}?view=configuration")

    def defaults(self):
        return self.read("/settings?group=providers")

    def invoke(self, method, *values):
        arguments = [self.session, *values]
        erl = ", ".join(
            "null" if value is None else f"<<{json.dumps(value)}>>"
            for value in arguments
        )
        return self.inspection.call_json(method, f"[{erl}]")

    def model(self, model, provider=None, effort=None):
        return self.invoke("model", model, provider, effort)

    def turn(self):
        self.app.prompt(self.session, "prepare a request").close()
        self.app.idle(self.session)

    def context(self):
        return self.read(f"/sessions/{self.session}/context")

    def test_commands_save_defaults_resolve_effort_and_reset_prepared_context(self):
        self.turn()
        self.assertEqual(self.context()["state"], "ready")
        cursor = self.app.stream_page(self.session)
        selected = self.model("second")["ok"]
        self.assertEqual((selected["model"], selected["effort"]), ("second", "high"))
        self.assertEqual(self.context()["state"], "pending")
        changes = self.app.stream_page(self.session, cursor)["events"]
        invalidated = {
            event["data"]["kind"] for event in changes if event["type"] == "invalidate"
        }
        self.assertTrue({"session", "context"}.issubset(invalidated), changes)
        new = self.read(f"/sessions/{self.app.session()}")
        self.assertEqual(new["model"], "second")

        self.turn()
        defaults = self.defaults()
        self.assertEqual(
            self.invoke("effort", " LOW ")["error"],
            "unsupported reasoning effort: low; available: medium, high",
        )
        self.assertEqual(self.context()["state"], "ready")
        changed = self.invoke("effort", " MEDIUM ")["ok"]
        self.assertEqual(changed["effort"], "medium")
        self.assertEqual(self.defaults(), defaults)
        self.assertEqual(self.context()["state"], "pending")

        before = self.configuration()
        rejected = self.model("third", effort="high")
        self.assertIn("unsupported reasoning effort", rejected["error"])
        self.assertEqual(self.configuration(), before)
        self.assertEqual(self.defaults(), defaults)
        self.invoke("effort", "high")
        self.assertEqual(self.model("third")["ok"]["effort"], "medium")
        self.assertEqual(self.configuration()["effort"], "medium")

        # HTTP edits share mutation validation, but never remember defaults.
        route = f"/sessions/{self.session}?view=configuration"
        with self.app.api(route) as response:
            json.load(response)
            etag = response.headers["ETag"]
        defaults = self.defaults()
        with self.app.api(
            route,
            {"model": "second", "effort": "high"},
            method="PATCH",
            headers={"If-Match": etag},
        ) as response:
            json.load(response)
        self.assertEqual(self.defaults(), defaults)
        self.turn()
        self.assertEqual(
            self.provider.requests[-1]["request"]["reasoning"]["effort"], "high"
        )

    def test_commands_reject_even_unchanged_values_during_a_turn(self):
        entered, release = threading.Event(), threading.Event()
        self.addCleanup(release.set)

        def script(_request):
            entered.set()
            release.wait(20)
            return text("done")

        self.provider.script = script
        self.app.prompt(self.session, "hold the turn").close()
        self.assertTrue(entered.wait(10))
        before, defaults = self.configuration(), self.defaults()
        try:
            self.assertEqual(
                self.model("first")["error"], "model must be nonempty and session idle"
            )
            self.assertEqual(
                self.invoke("effort", "high")["error"],
                "switching effort requires an idle session",
            )
            self.assertEqual(self.configuration(), before)
            self.assertEqual(self.defaults(), defaults)
            route = f"/sessions/{self.session}?view=configuration"
            with self.app.api(route) as response:
                json.load(response)
                etag = response.headers["ETag"]
            with self.app.api(
                route,
                {"model": "first", "effort": "high"},
                method="PATCH",
                headers={"If-Match": etag},
            ) as response:
                json.load(response)
        finally:
            release.set()
            self.app.idle(self.session)

    def test_commands_reject_changes_during_kernel_boot(self):
        self.app.prompt(self.session, "wait for the kernel").close()
        wait_until(
            lambda: self.marker.exists(), 10, "kernel startup did not reach its gate"
        )
        before, defaults = self.configuration(), self.defaults()
        try:
            self.assertEqual(
                self.model("second")["error"], "model must be nonempty and session idle"
            )
            self.assertEqual(
                self.invoke("effort", "low")["error"],
                "switching effort requires an idle session",
            )
            self.assertEqual(self.configuration(), before)
            self.assertEqual(self.defaults(), defaults)
        finally:
            assert self.gate is not None
            wait_until(
                lambda: release_fifo(self.gate), 10, "kernel did not open its gate"
            )
            self.gate.unlink()
        self.app.idle(self.session)
        self.assertEqual(self.provider.requests[-1]["request"]["model"], "first")


if __name__ == "__main__":
    unittest.main()
