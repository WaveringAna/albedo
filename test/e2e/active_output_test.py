"""An attachment during generation must recover text and thinking before replay.

The provider pauses only after a responsive subscriber has observed its prefix;
this exercises real actor capture, HTTP leases, and spill files without sleeps.
"""

import base64
import json
import socket
import subprocess
import threading
import time
import unittest
import urllib.error
import urllib.parse

from harness import Albedo, Provider, Reply, ROOT, exclusive, operation_id, text
from tool_progress_test import current_progress, tool_events


def delta(text, thinking=False):
    return {
        "id": "fixture",
        "choices": [
            {
                "index": 0,
                "delta": {"reasoning_content" if thinking else "content": text},
                "finish_reason": None,
            }
        ],
    }


def reference_text(app, reference):
    pieces = []
    token = None
    while True:
        url = urllib.parse.urlsplit(reference["url"])
        query = urllib.parse.parse_qs(url.query)
        if token is not None:
            query["next"] = [token]
        path = urllib.parse.urlunsplit(
            ("", "", url.path, urllib.parse.urlencode(query, doseq=True), "")
        )
        with app.api(path) as response:
            page = json.load(response)
        for part in page["parts"]:
            if part["field"] == reference["field"]:
                pieces.append(
                    base64.b64decode(part["text"])
                    if part["encoding"] == "base64"
                    else part["text"].encode()
                )
        token = page["next"]
        if token is None:
            return b"".join(pieces).decode()


def active_text(app, descriptor):
    return (
        descriptor["text"]
        if descriptor["text"] is not None
        else reference_text(app, descriptor["reference"])
    )


class ActiveOutputProbe:
    """Inspect actor memory or age a retired lease without advancing wall time."""

    def __init__(self, app):
        self.app = app
        subprocess.run(
            [
                "erlc",
                "-Werror",
                "-o",
                str(app.root),
                str(ROOT / "test/e2e/albedo_active_output_probe.erl"),
            ],
            check=True,
            timeout=30,
        )

    def call(self, function, *arguments):
        app = self.app
        cookie = (app.home / "inspect.cookie").read_text().strip()
        node = f"albedo_{app.daemon._pid}@{socket.gethostname().split('.')[0]}"
        values = ",".join(f"<<{json.dumps(str(argument))}>>" for argument in arguments)
        expression = (
            f"Node = '{node}', {{ok, Binary}} = file:read_file({json.dumps(str(app.root / 'albedo_active_output_probe.beam'))}), "
            "{module, albedo_active_output_probe} = rpc:call(Node, code, load_binary, "
            '[albedo_active_output_probe, "probe.erl", Binary]), '
            f"io:put_chars(rpc:call(Node, albedo_active_output_probe, {function}, [{values}])), halt()."
        )
        result = subprocess.run(
            [
                "erl",
                "+S",
                "2:2",
                "-sname",
                f"active_probe_{app.daemon._pid}",
                "-setcookie",
                cookie,
                "-noshell",
                "-eval",
                expression,
            ],
            capture_output=True,
            text=True,
            check=True,
            timeout=30,
        )
        return json.loads(result.stdout)


class PausedOutput:
    """One scripted response, with an actor-observed barrier and cleanup release."""

    def __init__(self, test, app, provider, chunks, thinking="", *, session=None):
        self.app, self.prefix, self.thinking = app, "".join(chunks), thinking
        self.suffix = "FINAL_SUFFIX"
        self.release, self.ready, self.observed = (threading.Event() for _ in range(3))
        self.events, self.errors, self.initial = [], [], None
        self.first_text_at = self.prefix_at = None
        test.addCleanup(self.release.set)

        def response():
            if thinking:
                yield delta(thinking, True)
            for chunk in chunks:
                yield delta(chunk)
            if not self.release.wait(60):
                raise AssertionError("paused provider was not released")
            yield delta(self.suffix)
            yield {
                "id": "fixture",
                "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
            }

        provider.script = lambda _: Reply("text", events=response())
        self.session = session or app.session()
        self.input_id = operation_id()

        def observe():
            text_chars = 0
            try:
                with app.api(
                    f"/sessions/{self.session}", headers={"Accept": "text/event-stream"}
                ) as stream:
                    for line in stream:
                        if not line.startswith(b"data: "):
                            continue
                        batch = json.loads(line[6:])
                        if self.initial is None:
                            self.initial = batch
                            self.ready.set()
                        for event in batch["events"]:
                            self.events.append(event)
                            if event["type"] == "text":
                                now = time.perf_counter()
                                self.first_text_at = self.first_text_at or now
                                text_chars += len(event["data"]["text"])
                                if text_chars == len(self.prefix):
                                    self.prefix_at = now
                                    self.observed.set()
                            if event["type"] == "turn_completed":
                                return
            except Exception as error:
                self.errors.append(error)
                self.ready.set()
                self.observed.set()

        self.thread = threading.Thread(target=observe, daemon=True)
        self.thread.start()
        test.assertTrue(self.ready.wait(10), "subscriber did not attach")
        app.api(
            f"/sessions/{self.session}/inputs/{self.input_id}",
            {"kind": "message", "text": "generate the fixture"},
            method="PUT",
        ).close()
        test.assertTrue(self.observed.wait(20), "actor did not emit complete prefix")
        test.assertFalse(self.errors)

    def snapshot(self):
        with self.app.api(f"/sessions/{self.session}?tail=20") as response:
            return json.load(response)

    def finish(self, test):
        self.release.set()
        self.app.idle(self.session)
        self.thread.join(10)
        test.assertFalse(self.thread.is_alive(), "subscriber did not see completion")
        test.assertFalse(self.errors)


class ActiveOutputTest(unittest.TestCase):
    def setUp(self):
        self.provider = Provider(lambda _: Reply("text", value="unused"))
        self.addCleanup(self.provider.close)
        self.app = self.enterContext(Albedo(self.provider))

    def assert_prefix(self, paused, snapshot):
        descriptors = snapshot["active_output"]
        by_kind = {item["kind"]: item for item in descriptors}
        self.assertEqual(active_text(self.app, by_kind["text"]), paused.prefix)
        self.assertEqual(by_kind["text"]["bytes"], len(paused.prefix.encode()))
        if paused.thinking:
            self.assertEqual(
                active_text(self.app, by_kind["thinking"]), paused.thinking
            )
        self.assertTrue(
            all(item["message_id"] and item["run_id"] for item in descriptors)
        )
        return descriptors

    def test_fresh_attachment_restores_text_and_thinking_before_future_deltas(self):
        paused = PausedOutput(
            self, self.app, self.provider, ["prefix α🙂"], "reasoning β"
        )
        batch = self.app.stream_page(paused.session)
        descriptors = self.assert_prefix(paused, batch["snapshot"])
        paused.finish(self)
        commits = [
            event["data"] for event in paused.events if event["type"] == "committed"
        ]
        replaced = {
            identifier
            for commit in commits
            for identifier in commit["replaces_live_ids"]
        }
        self.assertTrue({item["message_id"] for item in descriptors} <= replaced)
        self.assertEqual(paused.snapshot()["active_output"], [])

    def test_evicted_cursor_restores_large_prefix_and_unflushed_tail(self):
        chunks = [str(index).zfill(6) + "x" * 250 for index in range(4096)] + [
            "small tail α🙂"
        ]
        paused = PausedOutput(self, self.app, self.provider, chunks, "thinking" * 10000)
        batch = self.app.stream_page(paused.session, paused.initial)
        self.assertEqual(batch["events"][0]["type"], "reset")
        descriptors = self.assert_prefix(paused, batch["snapshot"])
        self.assertTrue(any(item["reference"] is not None for item in descriptors))
        paused.finish(self)

    def test_encoded_budget_spills_escaped_unicode_without_truncation(self):
        paused = PausedOutput(
            self, self.app, self.provider, ['"\\\n🙂' * 12000], "β" * 18000
        )
        snapshot = paused.snapshot()
        descriptors = self.assert_prefix(paused, snapshot)
        inline = [item["text"] for item in descriptors if item["text"] is not None]
        self.assertLessEqual(
            sum(len(json.dumps(text, ensure_ascii=False).encode()) for text in inline),
            65536,
        )
        self.assertTrue(any(item["reference"] is not None for item in descriptors))
        paused.finish(self)

    def test_json_string_budget_below_at_and_above_boundary(self):
        for size in [65533, 65534, 65535]:
            with self.subTest(bytes=size):
                paused = PausedOutput(self, self.app, self.provider, ["x" * size])
                descriptors = self.assert_prefix(paused, paused.snapshot())
                self.assertEqual(descriptors[0]["reference"] is not None, size > 65534)
                paused.finish(self)

    def test_snapshot_lease_remains_readable_after_commit(self):
        paused = PausedOutput(self, self.app, self.provider, ["large α🙂" * 20000])
        descriptors = paused.snapshot()["active_output"]
        reference = next(
            item["reference"] for item in descriptors if item["reference"] is not None
        )
        path = urllib.parse.urlsplit(reference["url"]).path
        for query in ["", "?snapshot="]:
            with self.assertRaises(urllib.error.HTTPError) as caught:
                self.app.api(path + query)
            self.assertEqual(caught.exception.code, 400)
        paused.finish(self)
        self.assertEqual(reference_text(self.app, reference), paused.prefix)

    def test_cancellation_clears_prefix_before_next_run(self):
        paused = PausedOutput(self, self.app, self.provider, ["cancelled prefix α🙂"])
        old_ids = {item["message_id"] for item in paused.snapshot()["active_output"]}
        self.app.api(
            f"/sessions/{paused.session}/inputs/{paused.input_id}/cancel", {}
        ).close()
        paused.release.set()
        self.app.idle(paused.session)
        self.assertEqual(paused.snapshot()["active_output"], [])
        next_run = PausedOutput(
            self, self.app, self.provider, ["new run prefix"], session=paused.session
        )
        descriptors = self.assert_prefix(next_run, next_run.snapshot())
        self.assertTrue(old_ids.isdisjoint(item["message_id"] for item in descriptors))
        next_run.finish(self)

    def gated_model_steps(self, *, first_completes):
        gates = [threading.Event(), threading.Event()]
        ready = [threading.Event(), threading.Event()]
        for gate in gates:
            self.addCleanup(gate.set)

        def model_events(index):
            for event in [
                delta(f"step {index} prefix α🙂"),
                delta(f"step {index} thinking β", True),
            ]:
                event["id"] = "progress-response"
                yield event
            yield from tool_events(
                "chat_completions",
                [(0, f"step-{index}", f"pass # step {index}")],
                ready[index],
                gates[index],
                complete=index == 1 or first_completes,
            )

        self.provider.script = lambda _: [
            Reply("text", events=model_events(0)),
            Reply("text", events=model_events(1)),
            text("done"),
        ]
        session = self.app.session()
        self.app.prompt(session, "exercise model steps").close()
        self.assertTrue(ready[0].wait(20))
        old = current_progress(self.app, session, lambda values: len(values) == 1)[
            "snapshot"
        ]
        old_ids = {item["message_id"] for item in old["active_output"]}
        self.assertEqual(
            {active_text(self.app, item) for item in old["active_output"]},
            {"step 0 prefix α🙂", "step 0 thinking β"},
        )
        gates[0].set()
        self.assertTrue(ready[1].wait(20))
        new = current_progress(
            self.app,
            session,
            lambda values: (
                len(values) == 1
                and values[0].get("preview", {}).get("text") == "pass # step 1"
            ),
        )["snapshot"]
        self.assertEqual(
            {active_text(self.app, item) for item in new["active_output"]},
            {"step 1 prefix α🙂", "step 1 thinking β"},
        )
        self.assertTrue(
            old_ids.isdisjoint(item["message_id"] for item in new["active_output"])
        )
        gates[1].set()
        self.app.idle(session)
        with self.app.api(f"/sessions/{session}?tail=20") as response:
            self.assertEqual(json.load(response)["active_output"], [])

    def test_retry_replaces_failed_attempt_output_before_reusing_indices(self):
        self.gated_model_steps(first_completes=False)

    def test_later_model_step_contains_only_its_own_output_segments(self):
        self.gated_model_steps(first_completes=True)


@exclusive
class ActiveOutputFailureTest(unittest.TestCase):
    def test_daemon_restart_removes_spill_owned_by_crashed_incarnation(self):
        provider = Provider(lambda _: Reply("text", value="unused"))
        self.addCleanup(provider.close)
        with Albedo(
            provider, prepare=lambda app: app.daemon.env.update(ALBEDO_INSPECT="1")
        ) as app:
            paused = PausedOutput(self, app, provider, ["crashed prefix " * 10000])
            reference = next(
                item["reference"]
                for item in paused.snapshot()["active_output"]
                if item["reference"] is not None
            )
            app.restart(crash=True)
            paused.release.set()
            with self.assertRaises(urllib.error.HTTPError) as caught:
                reference_text(app, reference)
            # A daemon restart rotates the signing secret, invalidating old tokens.
            self.assertEqual(caught.exception.code, 400)
            content_id = urllib.parse.urlsplit(reference["url"]).path.rsplit("/", 1)[1]
            probe = ActiveOutputProbe(app)
            probe.call("expire", app.home, content_id)
            probe.call("sweep", app.home)
            self.assertEqual(list((app.home / "active-output").glob("*.data")), [])

    def test_expired_retired_lease_is_unreadable_and_swept(self):
        provider = Provider(lambda _: Reply("text", value="unused"))
        self.addCleanup(provider.close)
        with Albedo(
            provider, prepare=lambda app: app.daemon.env.update(ALBEDO_INSPECT="1")
        ) as app:
            paused = PausedOutput(self, app, provider, ["expiry prefix " * 10000])
            reference = next(
                item["reference"]
                for item in paused.snapshot()["active_output"]
                if item["reference"] is not None
            )
            content_id = urllib.parse.urlsplit(reference["url"]).path.rsplit("/", 1)[1]
            paused.finish(self)
            probe = ActiveOutputProbe(app)
            probe.call("expire", app.home, content_id)
            with self.assertRaises(urllib.error.HTTPError) as caught:
                reference_text(app, reference)
            self.assertEqual(caught.exception.code, 410)
            probe.call("sweep", app.home)
            self.assertFalse(
                (app.home / "active-output" / f"{content_id}.data").exists()
            )
            self.assertFalse(
                (app.home / "active-output" / f"{content_id}.meta").exists()
            )

    def test_deleted_session_revokes_snapshot_and_removes_spill(self):
        provider = Provider(lambda _: Reply("text", value="unused"))
        self.addCleanup(provider.close)
        with Albedo(provider) as app:
            paused = PausedOutput(self, app, provider, ["delete prefix " * 20000])
            reference = next(
                item["reference"]
                for item in paused.snapshot()["active_output"]
                if item["reference"] is not None
            )
            app.api(
                f"/sessions/{paused.session}/inputs/{paused.input_id}/cancel", {}
            ).close()
            paused.finish(self)
            resource = f"/sessions/{paused.session}?view=configuration"
            with app.api(resource) as response:
                revision = response.getheader("ETag")
                response.read()
            app.api(resource, method="DELETE", headers={"If-Match": revision}).close()
            paused.release.set()
            with self.assertRaises(urllib.error.HTTPError) as caught:
                reference_text(app, reference)
            self.assertEqual(caught.exception.code, 410)
            self.assertEqual(list((app.home / "active-output").glob("*.data")), [])

    def test_spill_read_failure_is_visible_but_durable_commit_survives(self):
        provider = Provider(lambda _: Reply("text", value="unused"))
        self.addCleanup(provider.close)
        with Albedo(provider) as app:
            paused = PausedOutput(self, app, provider, ["read failure prefix " * 10000])
            reference = next(
                item["reference"]
                for item in paused.snapshot()["active_output"]
                if item["reference"] is not None
            )
            content_id = urllib.parse.urlsplit(reference["url"]).path.rsplit("/", 1)[1]
            spill = app.home / "active-output" / f"{content_id}.data"
            spill.unlink()
            spill.mkdir()
            with self.assertRaises(urllib.error.HTTPError) as caught:
                reference_text(app, reference)
            self.assertEqual(caught.exception.code, 503)
            paused.finish(self)
            self.assertEqual(paused.snapshot()["active_output"], [])
            self.assertTrue(
                any(event["type"] == "committed" for event in paused.events)
            )

    def test_spill_creation_failure_does_not_interrupt_generation(self):
        provider = Provider(lambda _: Reply("text", value="unused"))
        self.addCleanup(provider.close)

        def prepare(app):
            (app.home / "active-output").write_text("injected creation failure")

        with Albedo(provider, prepare=prepare) as app:
            paused = PausedOutput(self, app, provider, ["unavailable spill " * 12000])
            with self.assertRaises(urllib.error.HTTPError) as caught:
                paused.snapshot()
            self.assertEqual(caught.exception.code, 503)
            paused.finish(self)
            snapshot = paused.snapshot()
            self.assertEqual(snapshot["active_output"], [])
            assistant = [
                entry
                for entry in snapshot["history"]["items"]
                if entry["kind"] == "assistant"
            ]
            self.assertTrue(assistant, snapshot)
