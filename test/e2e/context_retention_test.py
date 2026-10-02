"""Snapshots survive real actor eviction without retaining opaque replay binaries."""

import json
import os
from pathlib import Path
import socket
import subprocess
import unittest

from harness import Albedo, Provider, Reply, ROOT, exclusive


# exclusive: enables daemon inspection and global rolling settings
@exclusive
class ContextRetentionTest(unittest.TestCase):
    def test_eviction_releases_replay_while_inspection_survives(self):
        payload = "REPLAY_SENTINEL:" + "x" * (256 * 1024)
        reply = Reply(
            "raw",
            events=[
                {
                    "type": "response.completed",
                    "response": {
                        "id": "retention-response",
                        "status": "completed",
                        "output": [
                            {
                                "type": "reasoning",
                                "id": "retention-reasoning",
                                "summary": [],
                                "encrypted_content": payload,
                            },
                            {
                                "type": "message",
                                "role": "assistant",
                                "content": [{"type": "output_text", "text": "done"}],
                            },
                        ],
                        "usage": {"input_tokens": 31, "output_tokens": 2},
                    },
                }
            ],
        )
        provider = Provider(lambda _: reply)
        self.addCleanup(provider.close)

        def prepare(app):
            app.daemon.env["ALBEDO_INSPECT"] = "1"
            app.write_extensions({"rolling": {"contextWindowTokens": 2_000_000}})

        with Albedo(provider, protocol="responses", prepare=prepare) as app:
            session = app.session()
            for prompt in ("first", "second"):
                app.prompt(session, prompt).close()
                app.idle(session)
            self.assertEqual(len(provider.requests), 2)
            self.assertTrue(
                any(
                    item.get("encrypted_content") == payload
                    for item in provider.requests[1]["request"]["input"]
                ),
                "second request lost opaque replay: "
                + json.dumps(
                    [
                        (item.get("type") or item.get("role"), len(json.dumps(item)))
                        for item in provider.requests[1]["request"]["input"]
                    ]
                )
                + " events="
                + json.dumps([e.get("type") for e in app.events(session)]),
            )
            route = f"/sessions/{session}/context"

            def read(path):
                with app.api(path) as response:
                    return json.load(response)

            self.assertEqual(read(route)["state"], "ready")
            support = ROOT / "test/daemon/albedo_context_snapshot_probe.erl"
            subprocess.run(
                ["erlc", "-o", str(app.root), str(support)], check=True, timeout=30
            )
            cookie = (app.home / "inspect.cookie").read_text().strip()
            node = f"albedo_{app.daemon._pid}@{socket.gethostname().split('.')[0]}"
            beam = Path(app.root) / "albedo_context_snapshot_probe"
            expression = (
                f"Node = '{node}', "
                f"{{ok, Binary}} = file:read_file({json.dumps(str(beam) + '.beam')}), "
                "{module, albedo_context_snapshot_probe} = "
                "rpc:call(Node, code, load_binary, "
                '[albedo_context_snapshot_probe, "probe.erl", Binary]), '
                "io:put_chars(rpc:call(Node, albedo_context_snapshot_probe, "
                f"actor_json, [<<{json.dumps(session)}>>])), halt()."
            )
            result = subprocess.run(
                [
                    "erl",
                    "+S",
                    "2:2",
                    "-sname",
                    "retention_probe",
                    "-setcookie",
                    cookie,
                    "-noshell",
                    "-eval",
                    expression,
                ],
                capture_output=True,
                text=True,
                check=False,
                timeout=30,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            measured = json.loads(result.stdout)
            artifact = os.environ.get("ALBEDO_INSPECTOR_ARTIFACT")
            if artifact:
                Path(artifact).write_text(json.dumps(measured, indent=2) + "\n")
            self.assertTrue(measured["history_unloaded"])
            self.assertFalse(measured["replay_reachable"])
            self.assertLess(measured["actor_binary_bytes"], len(payload))
            for key in (
                "history_readable",
                "kernel_released",
                "context_cleared",
                "actor_stopped",
                "workers_terminated",
            ):
                self.assertTrue(measured[key], key)
            self.assertEqual(measured["replay_backing_binary_bytes"], 0)
            self.assertEqual(len(provider.requests), 2)
