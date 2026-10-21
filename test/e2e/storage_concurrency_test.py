"""catches global-store read serialization under real concurrent daemon work."""

import json
import unittest

from harness import Albedo, Provider, ROOT, exclusive, text, wait_until
from inspect_support import Inspection


@exclusive
class StorageConcurrencyTest(unittest.TestCase):
    def setUp(self):
        self.provider = Provider(lambda _: text("committed while storage is reading"))
        self.addCleanup(self.provider.close)

    def test_reads_and_prompt_commit_continue_while_snapshot_is_held(self):
        def prepare(app):
            app.daemon.env["ALBEDO_INSPECT"] = "1"

        with Albedo(self.provider, prepare=prepare) as app:
            probe = Inspection(
                app, ROOT / "test/e2e/albedo_storage_concurrency_probe.erl"
            )
            session = app.session()
            ready = app.home / "snapshot-ready"
            try:
                probe.call("hold_snapshot", f"[<<{json.dumps(str(ready))}>>]")
                wait_until(ready.exists, 10, "snapshot gate never opened")

                with app.api("/sessions?scope=all") as response:
                    self.assertEqual(response.status, 200)
                    self.assertTrue(json.load(response)["items"])
                with app.api(f"/sessions/{session}/history") as response:
                    self.assertEqual(response.status, 200)

                app.prompt(session, "commit while a reader snapshot is held").close()
                app.idle(session)
                self.assertTrue(
                    any(
                        part.get("text") == "committed while storage is reading"
                        for part in app.history(session)["items"][-1]["content"]
                    )
                )
            finally:
                probe.call("release")
                wait_until(
                    lambda: not ready.exists(), 10, "snapshot gate did not close"
                )

    def test_reads_do_not_wait_on_an_uncommitted_writer_transaction(self):
        def prepare(app):
            app.daemon.env["ALBEDO_INSPECT"] = "1"

        with Albedo(self.provider, prepare=prepare) as app:
            probe = Inspection(
                app, ROOT / "test/e2e/albedo_storage_concurrency_probe.erl"
            )
            session = app.session()
            ready = app.home / "writer-ready"
            try:
                probe.call("hold_writer", f"[<<{json.dumps(str(ready))}>>]")
                wait_until(ready.exists, 10, "writer gate never opened")

                with app.api("/sessions?scope=all") as response:
                    self.assertEqual(response.status, 200)
                    items = json.load(response)["items"]
                    self.assertTrue(items)
                    self.assertNotIn(
                        "uncommitted storage gate",
                        json.dumps(items),
                    )
                with app.api(f"/sessions/{session}/history") as response:
                    self.assertEqual(response.status, 200)
            finally:
                probe.call("release")
                wait_until(lambda: not ready.exists(), 10, "writer gate did not close")

    def test_large_scans_do_not_fill_four_default_sqlite_caches(self):
        def prepare(app):
            app.daemon.env["ALBEDO_INSPECT"] = "1"

        with Albedo(self.provider, prepare=prepare) as app:
            probe = Inspection(
                app, ROOT / "test/e2e/albedo_storage_concurrency_probe.erl"
            )
            measured = probe.call_json("reader_cache_growth")
            self.assertLess(measured["growth"], 1024 * 1024, measured)
