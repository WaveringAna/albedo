"""Clients recover bounded live tool progress without reconstructing arguments."""

import json
import threading
import time
import unittest

from harness import Albedo, Provider, Reply, exclusive, text
from stream_pressure_test import StreamProbe, unread_stream
from stream_replay_test import restart_actor


def tool_events(
    protocol,
    calls,
    ready,
    release,
    *,
    chunk_size=7,
    complete=True,
    extra=None,
    barrier=False,
):
    """Pause the actual provider after argument fragments, before execution."""
    arguments = {
        index: json.dumps({"code": code, **(extra or {})}) for index, _, code in calls
    }
    if protocol == "responses":
        yield {"type": "response.created", "response": {"id": "progress-response"}}
        for index, identity, _ in calls:
            yield {
                "type": "response.output_item.added",
                "output_index": index,
                "item": {
                    "id": f"item-{index}",
                    "type": "function_call",
                    "call_id": identity,
                    "name": "python",
                },
            }
    for offset in range(0, max(map(len, arguments.values())), chunk_size):
        for index, identity, _ in calls:
            fragment = arguments[index][offset : offset + chunk_size]
            if not fragment:
                continue
            if protocol == "responses":
                yield {
                    "type": "response.function_call_arguments.delta",
                    "output_index": index,
                    "delta": fragment,
                }
            else:
                call = {"index": index, "function": {"arguments": fragment}}
                if offset == 0:
                    call.update(
                        id=identity,
                        type="function",
                        function={"name": "python", "arguments": fragment},
                    )
                yield {
                    "id": "progress-response",
                    "choices": [
                        {
                            "index": 0,
                            "delta": {"tool_calls": [call]},
                            "finish_reason": None,
                        }
                    ],
                }
    if barrier:
        # A later visible call proves the daemon consumed all prior fragments.
        assert protocol == "responses"
        index = max(arguments) + 1
        identity = "progress-barrier"
        calls = [*calls, (index, identity, "pass")]
        arguments[index] = json.dumps({"code": "pass"})
        yield {
            "type": "response.output_item.added",
            "output_index": index,
            "item": {
                "id": f"item-{index}",
                "type": "function_call",
                "call_id": identity,
                "name": "python",
            },
        }
        yield {
            "type": "response.function_call_arguments.delta",
            "output_index": index,
            "delta": arguments[index],
        }
    ready.set()
    if not release.wait(30):
        raise AssertionError("test did not release the provider")
    if not complete:
        raise ConnectionResetError("scripted provider stream ended before completion")
    if protocol == "responses":
        output = [
            {"id": f"gap-{index}", "type": "reasoning", "summary": []}
            for index in range(max(arguments) + 1)
        ]
        for index, identity, _ in calls:
            output[index] = {
                "id": f"item-{index}",
                "type": "function_call",
                "call_id": identity,
                "name": "python",
                "arguments": arguments[index],
                "status": "completed",
            }
        yield {
            "type": "response.completed",
            "response": {
                "id": "progress-response",
                "status": "completed",
                "output": output,
                "usage": {"input_tokens": 10, "output_tokens": 20},
            },
        }
    else:
        yield {
            "id": "progress-response",
            "choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}],
        }


def current_progress(app, session, predicate):
    deadline = time.monotonic() + 20
    page = None
    while time.monotonic() < deadline:
        page = app.stream_page(session)
        if predicate(page["currentProgress"]):
            return page
        time.sleep(0.01)
    raise AssertionError(f"live progress did not reach the provider barrier: {page}")


class ToolProgressTests(unittest.TestCase):
    def gated_reply(self, protocol, calls, **options):
        ready, release = threading.Event(), threading.Event()
        self.addCleanup(release.set)
        reply = Reply(
            "python",
            events=tool_events(protocol, calls, ready, release, **options),
        )
        return reply, ready, release

    def assert_bounds(self, progress):
        self.assertLessEqual(
            len(json.dumps({"type": "tool_progress", "progress": progress}).encode()),
            8192,
        )
        self.assertLessEqual(len(progress["name"].encode()), 100)
        if "code" in progress:
            self.assertGreaterEqual(progress["code"]["offset"], 0)
            self.assertLessEqual(len(progress["code"]["text"]), 512)
            self.assertLessEqual(len(progress["code"]["text"].encode()), 2048)

    def test_fragment_burst_flushes_latest_preview_without_more_provider_events(self):
        code = ("# " + "x" * 1000 + "\n") * 128 + "print('quiet provider')"
        reply, ready, release = self.gated_reply(
            "responses", [(0, "quiet-call", code)], chunk_size=64
        )
        provider = Provider(lambda _: [reply, text("done")])
        self.addCleanup(provider.close)
        with Albedo(provider, protocol="responses") as app:
            session = app.session()
            before = app.stream_page(session)
            app.prompt(session, "pause after a burst of tiny fragments").close()
            self.assertTrue(ready.wait(30), "provider never reached its quiet barrier")
            snapshot = current_progress(
                app,
                session,
                lambda values: (
                    len(values) == 1
                    and values[0].get("code", {}).get("text") == code[-512:]
                ),
            )
            # Reading a reset sees unflushed state and must not consume the
            # update owed to subscribers that already hold a replay cursor.
            deadline = time.monotonic() + 20
            while True:
                replay = app.stream_page(session, before)
                self.assertNotIn("reset", [event["type"] for event in replay["events"]])
                updates = [
                    event["progress"]
                    for event in replay["events"]
                    if event["type"] == "tool_progress"
                    and event["progress"] is not None
                ]
                if updates and updates[-1].get("code", {}).get("text") == code[-512:]:
                    break
                if time.monotonic() >= deadline:
                    self.fail("the quiet provider's final preview was never published")
                time.sleep(0.01)
            self.assertEqual(updates[-1], snapshot["currentProgress"][0])
            release.set()
            app.idle(session)
            completion = app.stream_page(session, replay)["events"]
            running_seen = False
            for event in completion:
                if event["type"] == "tool_progress" and event["progress"] is not None:
                    phase = event["progress"]["phase"]
                    if phase == "running":
                        running_seen = True
                    elif running_seen:
                        self.fail(
                            "a delayed generating preview followed tool execution"
                        )
            self.assertTrue(running_seen, "running transition was not delivered")
            [result] = [event for event in completion if event["type"] == "tool"]
            self.assertEqual(json.loads(result["args"])["code"], code)

    def test_unicode_preview_window_keeps_offsets_and_durable_arguments(self):
        code = (
            "# " + "prefix " * 400 + "\n"
            "from pathlib import Path\n"
            "Path('résumé😀.txt').write_text('escaped \\\" quote')\n"
        )
        for protocol in ("responses", "chat"):
            with self.subTest(protocol=protocol):
                reply, ready, release = self.gated_reply(
                    protocol, [(0, "unicode-call", code)]
                )
                provider = Provider(lambda _: [reply, text("done")])
                self.addCleanup(provider.close)
                with Albedo(
                    provider,
                    protocol="responses"
                    if protocol == "responses"
                    else "chat_completions",
                ) as app:
                    session = app.session()
                    self.assertEqual(app.stream_page(session)["currentProgress"], [])
                    app.prompt(session, "write the Unicode file").close()
                    self.assertTrue(ready.wait(20), "provider did not stream arguments")
                    snapshot = current_progress(
                        app,
                        session,
                        lambda values: (
                            len(values) == 1
                            and values[0].get("code", {}).get("text") == code[-512:]
                        ),
                    )
                    progress = snapshot["currentProgress"][0]
                    self.assert_bounds(progress)
                    self.assertEqual(progress["phase"], "generating")
                    self.assertEqual(progress["code"]["offset"], len(code) - 512)
                    for page in (
                        app.stream_page(session, tail=1),
                        app.stream_page(session),
                    ):
                        self.assertEqual(page["events"][0]["type"], "reset")
                        self.assertEqual(page["currentProgress"], [progress])
                    release.set()
                    app.idle(session)
                    replay = app.stream_page(session, snapshot)
                    self.assertNotIn("currentProgress", replay)
                    events = replay["events"]
                    self.assertNotIn(
                        "arguments_delta", [event["type"] for event in events]
                    )
                    running = [
                        event["progress"]
                        for event in events
                        if event["type"] == "tool_progress"
                        and event["progress"] is not None
                        and event["progress"]["phase"] == "running"
                    ]
                    self.assertEqual(len(running), 1)
                    self.assertEqual(running[0]["callId"], progress["callId"])
                    self.assertEqual(running[0]["toolCallId"], "unicode-call")
                    self.assert_bounds(running[0])
                    [result] = [event for event in events if event["type"] == "tool"]
                    self.assertEqual(result["progressCallId"], progress["callId"])
                    self.assertEqual(json.loads(result["args"])["code"], code)
                    [durable] = [
                        event
                        for event in app.events(session)
                        if event["type"] == "tool"
                    ]
                    self.assertEqual(json.loads(durable["args"])["code"], code)
                    self.assertEqual(
                        (app.workspace / "résumé😀.txt").read_text(),
                        'escaped " quote',
                    )
                    self.assertEqual(app.stream_page(session)["currentProgress"], [])

    def test_attachment_hides_unnamed_calls_then_restores_their_preview(self):
        code = "print('late name')"
        sentinel = "print('sentinel')"
        ready, reveal, named, complete = (threading.Event() for _ in range(4))
        self.addCleanup(reveal.set)
        self.addCleanup(complete.set)

        def chunk(index, function, identity=None):
            call = {"index": index, "function": function}
            if identity is not None:
                call.update(id=identity, type="function")
            return {
                "id": "late-name",
                "choices": [{"index": 0, "delta": {"tool_calls": [call]}}],
            }

        def events():
            yield chunk(0, {"arguments": json.dumps({"code": code})}, "late")
            yield chunk(
                1,
                {"name": "python", "arguments": json.dumps({"code": sentinel})},
                "sentinel",
            )
            ready.set()
            if not reveal.wait(30):
                raise AssertionError("tool-name release timed out")
            yield chunk(0, {"name": "python"})
            named.set()
            if not complete.wait(30):
                raise AssertionError("tool completion release timed out")
            yield {
                "id": "late-name",
                "choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}],
            }

        provider = Provider(lambda _: [Reply("python", events=events()), text("done")])
        self.addCleanup(provider.close)
        with Albedo(provider, protocol="chat_completions") as app:
            session = app.session()
            app.prompt(session, "attach before the first tool gets its name").close()
            self.assertTrue(ready.wait(20))
            # Seeing the second call proves the actor consumed the earlier
            # unnamed call, without relying on a provider/socket timing guess.
            snapshot = current_progress(
                app,
                session,
                lambda values: any(
                    value.get("code", {}).get("text") == sentinel for value in values
                ),
            )
            self.assertEqual(len(snapshot["currentProgress"]), 1)
            self.assertEqual(snapshot["currentProgress"][0]["name"], "python")
            reveal.set()
            self.assertTrue(named.wait(20))
            snapshot = current_progress(
                app,
                session,
                lambda values: (
                    {value.get("code", {}).get("text") for value in values}
                    == {code, sentinel}
                ),
            )
            self.assertEqual(len(snapshot["currentProgress"]), 2)
            complete.set()
            app.idle(session)
            results = [
                event for event in app.events(session) if event["type"] == "tool"
            ]
            self.assertEqual(
                {json.loads(event["args"])["code"] for event in results},
                {code, sentinel},
            )

    def test_interleaved_calls_keep_identity_through_native_id_deduplication(self):
        for protocol in ("responses", "chat"):
            with self.subTest(protocol=protocol):
                calls = [
                    (
                        2,
                        "first" if protocol == "responses" else "shared",
                        "print('first')",
                    ),
                    (
                        7,
                        "second" if protocol == "responses" else "shared",
                        "print('second')",
                    ),
                ]
                reply, ready, release = self.gated_reply(protocol, calls)
                provider = Provider(lambda _: [reply, text("done")])
                self.addCleanup(provider.close)
                with Albedo(
                    provider,
                    protocol="responses"
                    if protocol == "responses"
                    else "chat_completions",
                ) as app:
                    session = app.session()
                    app.prompt(session, "run both calls").close()
                    self.assertTrue(ready.wait(20))
                    snapshot = current_progress(
                        app,
                        session,
                        lambda values: (
                            len(values) == 2
                            and {value.get("code", {}).get("text") for value in values}
                            == {call[2] for call in calls}
                        ),
                    )
                    identities = {
                        value["code"]["text"]: value["callId"]
                        for value in snapshot["currentProgress"]
                    }
                    self.assertEqual(len(set(identities.values())), 2)
                    release.set()
                    app.idle(session)
                    replay = app.stream_page(session, snapshot)
                    results = [
                        event for event in replay["events"] if event["type"] == "tool"
                    ]
                    self.assertEqual(len(results), 2)
                    self.assertEqual(len({event["callId"] for event in results}), 2)
                    for event in results:
                        self.assertEqual(
                            event["progressCallId"],
                            identities[json.loads(event["args"])["code"]],
                        )
                    self.assertEqual(app.stream_page(session)["currentProgress"], [])

    def test_retry_discards_failed_attempt_progress_before_reusing_output_index(self):
        failed, first_ready, first_release = self.gated_reply(
            "responses", [(0, "discarded", "print('old attempt')")], complete=False
        )
        succeeding, second_ready, second_release = self.gated_reply(
            "responses", [(0, "accepted", "print('new attempt')")]
        )
        provider = Provider(lambda _: [failed, succeeding, text("done")])
        self.addCleanup(provider.close)
        with Albedo(provider, protocol="responses") as app:
            session = app.session()
            app.prompt(session, "retry the provider").close()
            self.assertTrue(first_ready.wait(20))
            old = current_progress(app, session, lambda values: len(values) == 1)
            first_release.set()
            self.assertTrue(second_ready.wait(20))
            new = current_progress(
                app,
                session,
                lambda values: (
                    len(values) == 1
                    and values[0].get("code", {}).get("text") == "print('new attempt')"
                ),
            )
            self.assertNotEqual(
                new["currentProgress"][0]["callId"], old["currentProgress"][0]["callId"]
            )
            second_release.set()
            app.idle(session)
            results = [
                event for event in app.events(session) if event["type"] == "tool"
            ]
            self.assertEqual(len(results), 1)
            self.assertEqual(
                json.loads(results[0]["args"])["code"], "print('new attempt')"
            )
            self.assertEqual(app.stream_page(session)["currentProgress"], [])

    def test_interrupt_clears_progress_and_prevents_delayed_execution(self):
        code = "from pathlib import Path\nPath('must-not-exist').write_text('bad')"
        reply, ready, release = self.gated_reply("responses", [(0, "cancelled", code)])
        provider = Provider(lambda _: [reply, text("later turn")])
        self.addCleanup(provider.close)
        with Albedo(provider, protocol="responses") as app:
            session = app.session()
            app.prompt(session, "pause before execution").close()
            self.assertTrue(ready.wait(20))
            current_progress(app, session, lambda values: len(values) == 1)
            app.api(f"/sessions/{session}/interrupt", {}).close()
            release.set()
            app.idle(session)
            self.assertEqual(app.stream_page(session)["currentProgress"], [])
            self.assertFalse((app.workspace / "must-not-exist").exists())
            app.prompt(session, "continue with a clean turn").close()
            app.idle(session)
            self.assertEqual(app.stream_page(session)["currentProgress"], [])

    # exclusive: enables daemon inspection at startup and replaces a session actor
    @exclusive
    def test_replacement_actor_drops_old_live_progress(self):
        code = "from pathlib import Path\nPath('stale-call').write_text('bad')"
        reply, ready, release = self.gated_reply("responses", [(0, "stale-call", code)])
        provider = Provider(lambda _: [reply, text("clean turn")])
        self.addCleanup(provider.close)
        with Albedo(
            provider,
            protocol="responses",
            prepare=lambda app: app.daemon.env.update(ALBEDO_INSPECT="1"),
        ) as app:
            session = app.session()
            app.prompt(session, "pause an old call").close()
            self.assertTrue(ready.wait(20))
            old = current_progress(app, session, lambda values: len(values) == 1)
            restart_actor(app, session)
            replacement = app.stream_page(session, old)
            self.assertNotEqual(replacement["generation"], old["generation"])
            self.assertEqual(replacement["events"][0]["type"], "reset")
            self.assertEqual(replacement["currentProgress"], [])
            release.set()
            app.prompt(session, "continue after replacement").close()
            app.idle(session)
            self.assertFalse((app.workspace / "stale-call").exists())
            self.assertEqual(app.stream_page(session)["currentProgress"], [])

    def test_late_attachment_restores_running_progress_until_result(self):
        code = (
            "from pathlib import Path\nimport asyncio\n"
            "Path('running-ready').write_text('ready')\n"
            "while not Path('finish-running').exists():\n"
            "    await asyncio.sleep(0.01)\n"
            "print('finished')"
        )
        reply, ready, release = self.gated_reply(
            "responses", [(0, "running-call", code)]
        )
        provider = Provider(lambda _: [reply, text("done")])
        self.addCleanup(provider.close)
        with Albedo(provider, protocol="responses") as app:
            session = app.session()
            app.prompt(session, "hold a running call").close()
            self.assertTrue(ready.wait(20))
            generating = current_progress(app, session, lambda values: len(values) == 1)
            release.set()
            finished = app.workspace / "finish-running"
            try:
                deadline = time.monotonic() + 20
                while not (app.workspace / "running-ready").exists():
                    if time.monotonic() >= deadline:
                        self.fail("the kernel did not reach the running barrier")
                    time.sleep(0.01)
                snapshot = current_progress(
                    app,
                    session,
                    lambda values: len(values) == 1 and values[0]["phase"] == "running",
                )
                [progress] = snapshot["currentProgress"]
                self.assertEqual(
                    progress["callId"], generating["currentProgress"][0]["callId"]
                )
                self.assertEqual(progress["toolCallId"], "running-call")
                self.assert_bounds(progress)
                self.assertEqual(
                    app.stream_page(session, tail=1)["currentProgress"], [progress]
                )
            finally:
                finished.write_text("finish")
            app.idle(session)
            self.assertEqual(app.stream_page(session)["currentProgress"], [])

    def test_oversized_native_identity_is_omitted_from_progress_not_truncated(self):
        identity = "native-" + "😀" * 60
        code = "# " + "😀" * 700 + "\nprint('bounded Unicode preview')"
        reply, ready, release = self.gated_reply(
            "responses", [(0, identity, code)], chunk_size=1000
        )
        provider = Provider(lambda _: [reply, text("done")])
        self.addCleanup(provider.close)
        with Albedo(provider, protocol="responses") as app:
            session = app.session()
            app.prompt(session, "run a call with a large identity").close()
            self.assertTrue(ready.wait(20))
            snapshot = current_progress(
                app,
                session,
                lambda values: (
                    len(values) == 1
                    and values[0].get("code", {}).get("text") == code[-512:]
                ),
            )
            self.assert_bounds(snapshot["currentProgress"][0])
            release.set()
            app.idle(session)
            events = app.stream_page(session, snapshot)["events"]
            [running] = [
                event["progress"]
                for event in events
                if event["type"] == "tool_progress"
                and event["progress"] is not None
                and event["progress"]["phase"] == "running"
            ]
            self.assertNotIn("toolCallId", running)
            self.assert_bounds(running)
            [result] = [event for event in events if event["type"] == "tool"]
            self.assertEqual(result["callId"], identity)
            self.assertEqual(result["progressCallId"], running["callId"])

    def test_complex_arguments_degrade_preview_without_blocking_execution(self):
        nested = "leaf"
        for _ in range(70):
            nested = [nested]
        code = "print('complex arguments executed')"
        reply, ready, release = self.gated_reply(
            "responses",
            [(0, "complex-call", code)],
            chunk_size=1000,
            extra={"metadata": nested},
            barrier=True,
        )
        provider = Provider(lambda _: [reply, text("done")])
        self.addCleanup(provider.close)
        with Albedo(provider, protocol="responses") as app:
            session = app.session()
            app.prompt(session, "run a call with deep metadata").close()
            self.assertTrue(ready.wait(20))
            snapshot = current_progress(
                app,
                session,
                lambda values: any(
                    value.get("code", {}).get("text") == "pass" for value in values
                ),
            )
            self.assertEqual(len(snapshot["currentProgress"]), 2)
            [progress] = [
                value
                for value in snapshot["currentProgress"]
                if value.get("code", {}).get("text") != "pass"
            ]
            self.assertNotIn("code", progress)
            self.assertEqual(progress["name"], "python")
            release.set()
            app.idle(session)
            [result] = [
                event
                for event in app.events(session)
                if event["type"] == "tool" and event["callId"] == "complex-call"
            ]
            self.assertEqual(
                json.loads(result["args"]), {"code": code, "metadata": nested}
            )
            execution = json.loads(result["result"])
            self.assertEqual(execution["status"], "ok", execution)
            self.assertEqual(execution["output"], "complex arguments executed\n")

    def test_escaped_metadata_keys_disable_preview_without_changing_execution(self):
        code = "print('escaped metadata executed')"
        metadata = {'metadata\\"': ', "code": "misleading_preview_sentinel"'}
        reply, ready, release = self.gated_reply(
            "responses",
            [(0, "escaped-key", code)],
            chunk_size=7,
            extra=metadata,
            barrier=True,
        )
        provider = Provider(lambda _: [reply, text("done")])
        self.addCleanup(provider.close)
        with Albedo(provider, protocol="responses") as app:
            session = app.session()
            app.prompt(session, "run a call with escaped metadata").close()
            self.assertTrue(ready.wait(20))
            snapshot = current_progress(
                app,
                session,
                lambda values: any(
                    value.get("code", {}).get("text") == "pass" for value in values
                ),
            )
            self.assertEqual(len(snapshot["currentProgress"]), 2)
            [progress] = [
                value
                for value in snapshot["currentProgress"]
                if value.get("code", {}).get("text") != "pass"
            ]
            self.assertNotIn("code", progress)
            self.assertEqual(progress["name"], "python")
            release.set()
            app.idle(session)
            [result] = [
                event
                for event in app.events(session)
                if event["type"] == "tool" and event["callId"] == "escaped-key"
            ]
            self.assertEqual(json.loads(result["args"]), {"code": code, **metadata})
            execution = json.loads(result["result"])
            self.assertEqual(execution["status"], "ok", execution)
            self.assertEqual(execution["output"], "escaped metadata executed\n")

    # exclusive: enables the daemon inspection endpoint before startup
    @exclusive
    def test_subscribers_share_one_bounded_argument_projection(self):
        code = ("# " + "x" * 1000 + "\n") * 128 + "print('shared projection')"
        reply, ready, release = self.gated_reply(
            "responses", [(0, "shared-call", code)], chunk_size=8192
        )
        provider = Provider(lambda _: [reply, text("done")])
        self.addCleanup(provider.close)
        with Albedo(
            provider,
            protocol="responses",
            prepare=lambda app: app.daemon.env.update(ALBEDO_INSPECT="1"),
        ) as app:
            session = app.session()
            initial = app.stream_page(session)
            app.prompt(session, "show shared progress").close()
            self.assertTrue(ready.wait(20))
            snapshot = current_progress(
                app,
                session,
                lambda values: (
                    len(values) == 1
                    and values[0].get("code", {}).get("text") == code[-512:]
                ),
            )
            probe = StreamProbe(app)
            arguments = f"[<<{json.dumps(session)}>>]"
            self.assertEqual(
                probe.call("session_removed_json", arguments)["watchers"], 0
            )
            self.assertEqual(
                snapshot["currentProgress"][0]["code"]["offset"], len(code) - 512
            )
            self.assert_bounds(snapshot["currentProgress"][0])
            deadline = time.monotonic() + 20
            while True:
                published = app.stream_page(session, initial)
                if any(
                    event["type"] == "tool_progress"
                    and event["progress"] == snapshot["currentProgress"][0]
                    for event in published["events"]
                ):
                    break
                if time.monotonic() >= deadline:
                    self.fail("shared progress never finished publishing its preview")
                time.sleep(0.01)
            before = probe.call("progress_json", arguments)
            sockets = [
                unread_stream(app, f"/sessions/{session}/stream") for _ in range(10)
            ]
            for connection in sockets:
                self.addCleanup(connection.close)
            after = probe.call("progress_json", arguments)
            self.assertEqual(after["watchers"], before["watchers"] + 10)
            self.assertEqual(after["projection_bytes"], before["projection_bytes"])
            self.assertEqual(after["projection_size"], before["projection_size"])
            self.assertLessEqual(after["projection_bytes"], 64 * 1024)
            # Include lists and tuples, so retained codepoints cannot hide behind
            # the binary-only byte count as the full arguments grow.
            self.assertLessEqual(after["projection_size"], 64 * 1024)
            self.assertEqual(
                app.stream_page(session)["currentProgress"], snapshot["currentProgress"]
            )
            release.set()
            app.idle(session)
            [result] = [
                event for event in app.events(session) if event["type"] == "tool"
            ]
            self.assertEqual(json.loads(result["args"]), {"code": code})
            execution = json.loads(result["result"])
            self.assertEqual(execution["status"], "ok", execution)
            self.assertEqual(execution["output"], "shared projection\n")

    def test_excess_generating_calls_disable_previews_without_losing_execution(self):
        calls = [(index, f"many-{index}", f"print({index})") for index in range(33)]
        reply, ready, release = self.gated_reply("responses", calls, chunk_size=100)
        provider = Provider(lambda _: [reply, text("done")])
        self.addCleanup(provider.close)
        with Albedo(provider, protocol="responses") as app:
            session = app.session()
            before = app.stream_page(session)
            app.prompt(session, "run all calls").close()
            self.assertTrue(ready.wait(20))
            deadline = time.monotonic() + 20
            while True:
                replay = app.stream_page(session, before)
                cleared = any(
                    event["type"] == "tool_progress" and event["progress"] is None
                    for event in replay["events"]
                )
                if cleared:
                    break
                if time.monotonic() >= deadline:
                    self.fail("overflow did not clear generating progress")
                time.sleep(0.01)
            self.assertEqual(app.stream_page(session)["currentProgress"], [])
            release.set()
            app.idle(session, timeout=60)
            results = [
                event for event in app.events(session) if event["type"] == "tool"
            ]
            self.assertEqual(
                {event["callId"] for event in results}, {call[1] for call in calls}
            )
            for event in results:
                index = int(event["callId"].split("-")[1])
                self.assertEqual(
                    json.loads(event["args"])["code"],
                    calls[index][2],
                )
                execution = json.loads(event["result"])
                self.assertEqual(execution["status"], "ok", execution)
                self.assertEqual(execution["output"], f"{index}\n")
            self.assertEqual(app.stream_page(session)["currentProgress"], [])
            self.assertNotIn(
                "arguments_delta",
                [event["type"] for event in app.stream_page(session, before)["events"]],
            )
