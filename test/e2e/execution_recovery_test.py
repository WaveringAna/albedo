"""Cancellation releases execution workers and long tool turns complete."""

from concurrent.futures import ThreadPoolExecutor
import json
import time

from harness import exclusive
from stream_support import StreamProbe

from integration_support import IntegrationScenario


class ExecutionRecoveryTests(IntegrationScenario):
    # exclusive: enables the existing native inspection seam
    @exclusive
    def test_interrupt_before_first_token_stops_worker_without_killing_it(self):
        for protocol in ("responses", "chat_completions"):
            with self.subTest(protocol=protocol):
                app = self.app_for(
                    protocol, prepare=lambda app: app.env.update(ALBEDO_INSPECT="1")
                )
                session = app.session()
                start = len(self.provider.requests)
                with app.prompt(session, "no first token") as response:
                    input_id = json.load(response)["id"]
                self.wait_for_request(start)
                captured = self.read(app, f"/sessions/{session}?tail=0")
                probe = StreamProbe(app)
                ready = app.workspace / f"monitor-{protocol}"
                arguments = (
                    "["
                    + ",".join(
                        "<<" + json.dumps(value) + ">>"
                        for value in [session, captured["status"]["run_id"], str(ready)]
                    )
                    + "]"
                )
                with ThreadPoolExecutor(max_workers=1) as pool:
                    exited = pool.submit(probe.call, "worker_exit_json", arguments)
                    deadline = time.monotonic() + 30
                    while not ready.exists() and time.monotonic() < deadline:
                        time.sleep(0.01)
                    self.assertTrue(ready.exists(), "worker monitor was not installed")
                    app.api(
                        f"/sessions/{session}/interrupt",
                        {
                            "run_id": captured["status"]["run_id"],
                            "through_input_order": captured["input_order"],
                        },
                    ).close()
                    self.assertEqual(exited.result(timeout=40), {"reason": "normal"})
                app.idle(session)
                receipt = self.read(app, f"/sessions/{session}/inputs/{input_id}")
                self.assertEqual(receipt["turn"]["state"], "interrupted")
                # The interrupted session takes a new turn and commits it.
                self.send(app, session, "continue from branch")
                self.assertTrue(
                    any(
                        e["kind"] == "assistant" and self.entry_text(e) == "finished"
                        for e in self.history(app, session)
                    )
                )

    def test_more_than_hundred_tool_turns_complete(self):
        for protocol in ("responses", "chat_completions"):
            with self.subTest(protocol=protocol):
                app = self.app_for(protocol)
                session = app.session()
                start = len(self.provider.requests)
                self.send(app, session, "continue for over 100 turns")
                self.assertEqual(len(self.records(start)), 106)
                events = self.history(app, session)
                self.assertEqual(sum(e["kind"] == "tool_result" for e in events), 105)
                self.assertTrue(
                    any(
                        e["kind"] == "assistant" and self.entry_text(e) == "finished"
                        for e in events
                    )
                )
