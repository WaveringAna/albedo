"""Transcript paging and what the transcript keeps, through the real daemon."""
import json
import unittest

from harness import Albedo, Provider, Reply, exclusive, text


class DaemonTest(unittest.TestCase):
    def test_history_pages_recover_older_turns_once(self):
        provider = Provider(lambda _request: text("answer"))
        self.addCleanup(provider.close)
        with Albedo(provider) as app:
            session = app.session()
            for message in ("oldest prompt", "middle prompt", "newest prompt"):
                app.prompt(session, message).close()
                app.idle(session)

            pages = []
            before = None
            while True:
                suffix = "" if before is None else f"&before={before}"
                with app.api(f"/sessions/{session}/history?rows=2{suffix}") as response:
                    page = json.load(response)
                pages.append(page)
                if not page["more"]:
                    break
                self.assertIsInstance(page["before"], int)
                self.assertNotEqual(page["before"], before)
                before = page["before"]

            prompts = [
                [event["text"] for event in page["events"] if event["type"] == "user"]
                for page in pages
            ]
            self.assertEqual(
                [turn for turn in prompts if turn],
                [["newest prompt"], ["middle prompt"], ["oldest prompt"]],
            )
            self.assertFalse(pages[-1]["more"])

    @exclusive
    def test_a_clean_restart_leaves_no_registry_crash_loop(self):
        # Shutdown closes the store before the VM halts, and the supervisor
        # may restart the registry inside that window; its init used to panic
        # on the closed store ten times before the supervisor gave up. What
        # holds the VM open long enough to lose the race is the models
        # catalog refresh, so the restart runs with it enabled; the fixture
        # config itself stays, so later fixtures keep their provider.
        provider = Provider(lambda _request: text("answer"))
        self.addCleanup(provider.close)
        with Albedo(provider) as app:
            settings = json.loads((app.home / "extensions.json").read_text())
            settings.pop("models", None)
            (app.home / "extensions.json").write_text(json.dumps(settings))
            log = app.home / "daemon.log"
            before = log.stat().st_size if log.exists() else 0
            app.restart()
            app.restart()
            tail = log.read_text(errors="replace")[before:]
            for marker in ("Noproc", "reached_max_restart_intensity", "callee exited"):
                self.assertNotIn(marker, tail)

    def test_a_thoughts_duration_is_kept_with_the_transcript(self):
        # summarized thinking streams once it is written: here the response
        # opens, thinks 0.6s, and its summary comes 0.3s before the answer,
        # so the thought is timed from the opening, not the summary
        chunk = lambda delta, finish=None: {"id": "fixture", "choices": [
            {"index": 0, "delta": delta, "finish_reason": finish}]}
        reply = Reply("text", delay=0.3, events=[
            chunk({"role": "assistant"}),
            chunk({"reasoning_content": "weighing it"}),
            chunk({"content": "answer"}),
            chunk({}, "stop"),
        ])
        provider = Provider(lambda _request: reply)
        self.addCleanup(provider.close)
        with Albedo(provider) as app:
            session = app.session()
            app.prompt(session, "think first").close()
            app.idle(session)

            for source, events in (("stream", app.events(session)), ("history", app.history(session)["events"])):
                thoughts = [event for event in events if event["type"] == "thinking"]
                self.assertEqual([event["text"] for event in thoughts], ["weighing it"], source)
                self.assertGreaterEqual(thoughts[0].get("elapsedMs", 0), 500, source)


if __name__ == "__main__":
    unittest.main()
