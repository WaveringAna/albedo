"""Colab protocol tests: local refusals and interrupted downloads need no live GPU.

The daemon cannot deterministically reproduce an occupied Colab ssh slot or a
proxy that ignores Range; these tests exercise those responses locally.
"""

from __future__ import annotations

import asyncio
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import urllib.parse
import unittest
from unittest.mock import AsyncMock, patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "priv" / "python"))
sys.path.insert(0, str(ROOT / "test"))

import albedo_ssh  # noqa: E402
from albedo_api import PythonApi  # noqa: E402
from albedo_capture import Capture  # noqa: E402
from albedo_plugins import colab  # noqa: E402
import scratch  # noqa: E402

scratch.claim("harness")

REAL_ACCOUNT = colab._account
ACCOUNT = {"access": "test-token", "email": "user@example.com"}


def instance(**fields) -> colab.ColabInstance:
    return colab.ColabInstance(
        {
            "id": "gpu-t4-1",
            "endpoint": "gpu-t4-1",
            "name": "dev-t4",
            "variant": "GPU",
            "accelerator": "T4",
            "shape": "standard",
            "status": "active",
            "url": None,
            "token": None,
            "token_expires_in": None,
            "raw": {},
            **fields,
        }
    )


@contextmanager
def runtime_proxy(status, body, headers=None):
    requests = []

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            requests.append((self.path, self.headers))
            self.send_response(status)
            for key, value in (headers or {}).items():
                self.send_header(key, value)
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, format, *args):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(
        target=server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True
    )
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}", requests
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


class ColabPluginTest(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp(prefix="albedo-colab-home-")
        (Path(self.home) / ".ssh").mkdir()
        env = patch.dict(os.environ, {"HOME": self.home})
        env.start()
        self.addCleanup(env.stop)
        account = patch.object(colab, "_account", AsyncMock(return_value=ACCOUNT))
        account.start()
        self.addCleanup(account.stop)
        self.addCleanup(albedo_ssh.ALIASES.clear)

    async def test_account_comes_from_the_daemon_and_its_refusal_is_a_colab_error(self):
        class Refused(Exception):
            pass

        calls = []

        async def host(method, args):
            calls.append(method)
            raise Refused("Google Colab is not authenticated; run /login")

        with (
            patch.object(colab, "_account", REAL_ACCOUNT),
            patch.multiple(colab, host_call=host, HostErrorType=Refused),
        ):
            with self.assertRaises(colab.ColabError) as cm:
                await colab._account()
        self.assertEqual(calls, ["colab.account"])
        self.assertIn("not authenticated", str(cm.exception))

    async def test_instances_query(self):
        body = (
            b")]}'\n"
            + json.dumps(
                {
                    "assignments": [
                        {
                            "endpoint": "gpu-t4-s-12345",
                            "name": "colab-t4",
                            "variant": "GPU",
                            "accelerator": "T4",
                            "shape": "standard",
                            "status": "active",
                            "runtimeProxyInfo": {
                                "url": "https://vm1.colab.googleusercontent.com",
                                "token": "proxy-tok-123",
                                "tokenExpiresInSeconds": 3600,
                            },
                        }
                    ]
                }
            ).encode()
        )
        with patch.object(colab, "_send", return_value=(200, body)) as send:
            found = await colab.instances()
        self.assertEqual(len(found), 1)
        inst = found[0]
        self.assertEqual(inst.id, "gpu-t4-s-12345")
        self.assertEqual(inst.gpu, "T4")
        self.assertEqual(inst.url, "https://vm1.colab.googleusercontent.com")
        self.assertEqual(inst.token, "proxy-tok-123")
        method, url, headers, _, _ = send.call_args[0]
        self.assertEqual(method, "GET")
        self.assertIn("/tun/m/assignments?authuser=0", url)
        self.assertEqual(headers["Authorization"], "Bearer test-token")
        self.assertEqual(headers["X-Colab-Tunnel"], "Google")

    async def test_status_summary_and_single_lookup(self):
        with patch.object(colab, "instances", AsyncMock(return_value=[instance()])):
            overall = await colab.status()
            self.assertTrue(overall.authenticated)
            self.assertEqual(overall.email, "user@example.com")
            self.assertEqual(overall.active, 1)
            self.assertIn("gpu-t4-1", str(overall))
            self.assertEqual((await colab.status("gpu-t4-1")).id, "gpu-t4-1")
            self.assertEqual((await colab.status("dev-t4")).id, "gpu-t4-1")
            with self.assertRaises(colab.ColabError):
                await colab.status("missing-instance")

    def test_notebook_hash(self):
        nbh = colab._notebook_hash()
        self.assertEqual(len(nbh), 44)
        self.assertNotIn("-", nbh)
        self.assertTrue(nbh.endswith("."))

    async def test_launch_provisions_with_the_xsrf_token(self):
        xsrf = b')]}\'\n{"token": "xsrf-token-123"}'
        assigned = json.dumps(
            {
                "assignment": {
                    "endpoint": "gpu-t4-assigned-999",
                    "variant": "GPU",
                    "accelerator": "T4",
                    "shape": "highmem",
                    "runtimeProxyInfo": {"url": "https://vm", "token": "tok-t4"},
                }
            }
        ).encode()
        with patch.object(
            colab, "_send", side_effect=[(200, xsrf), (200, assigned)]
        ) as send:
            inst = await colab.launch(gpu="T4", mem="high")
        self.assertEqual(inst.id, "gpu-t4-assigned-999")
        self.assertEqual(inst.mem, "high")
        (m1, u1, _, b1, _), (m2, u2, h2, b2, _) = (c[0] for c in send.call_args_list)
        self.assertEqual(m1, "GET")
        for part in (
            "/tun/m/assign",
            "authuser=0",
            "variant=GPU",
            "accelerator=T4",
            "shape=hm",
        ):
            self.assertIn(part, u1)
        self.assertIsNone(b1)
        self.assertEqual(m2, "POST")
        self.assertIn("/tun/m/assign", u2)
        self.assertEqual(h2["X-Goog-Colab-Token"], "xsrf-token-123")
        self.assertIsNone(b2)

    async def test_launch_returns_an_existing_assignment(self):
        existing = json.dumps(
            {
                "endpoint": "gpu-t4-existing-111",
                "variant": "GPU",
                "accelerator": "T4",
                "runtimeProxyInfo": {"url": "https://vm", "token": "tok"},
            }
        ).encode()
        with patch.object(colab, "_send", return_value=(200, existing)) as send:
            inst = await colab.launch(gpu="T4")
        self.assertEqual(inst.id, "gpu-t4-existing-111")
        self.assertEqual(send.call_count, 1)

    async def test_launch_capacity_exhausted(self):
        with patch.object(colab, "_send", return_value=(503, b"Resource exhausted")):
            with self.assertRaises(colab.ColabError) as cm:
                await colab.launch(gpu="A100")
        self.assertIn("capacity exhausted", str(cm.exception))
        self.assertEqual(cm.exception.status, 503)

    async def test_stop_instance_and_already_stopped(self):
        xsrf = b')]}\'\n{"token": "unassign-xsrf-456"}'
        with patch.object(
            colab, "_send", side_effect=[(200, xsrf), (204, b"")]
        ) as send:
            result = await colab.stop("gpu-t4-s-12345")
        self.assertTrue(result.success)
        (m1, u1, _, _, _), (m2, u2, h2, _, _) = (c[0] for c in send.call_args_list)
        self.assertEqual((m1, m2), ("GET", "POST"))
        for url in (u1, u2):
            self.assertIn("/tun/m/unassign/gpu-t4-s-12345", url)
        self.assertEqual(h2["X-Goog-Colab-Token"], "unassign-xsrf-456")

        with patch.object(colab, "_send", return_value=(404, b"Not Found")):
            result = await colab.stop("already-stopped")
        self.assertFalse(result.success)
        self.assertIn("not found or already stopped", str(result.message))

    async def test_connect_names_the_host_in_memory_and_leaves_ssh_config_alone(self):
        ssh = Path(self.home) / ".ssh"
        (ssh / "id_ed25519.pub").write_text("ssh-ed25519 AAAA test@box\n")
        live = instance(
            url="https://vm.colab.googleusercontent.com", token="proxy tok/1"
        )
        reached = AsyncMock(return_value="connection")
        with (
            patch.object(colab, "instances", AsyncMock(return_value=[live])),
            patch.object(colab.remote, "connect", reached),
        ):
            result = await live.connect(remote_cwd="/content/project")

        self.assertEqual(result, "connection")
        reached.assert_awaited_once_with(
            "colab-gpu-t4-1",
            remote_cwd="/content/project",
            python="/usr/bin/python3",
            modules=None,
            timeout=60.0,
        )
        self.assertEqual(list(ssh.iterdir()), [ssh / "id_ed25519.pub"])

        argv = albedo_ssh.base("colab-gpu-t4-1")
        options = [argv[i + 1] for i, arg in enumerate(argv) if arg == "-o"]
        self.assertTrue(options[0].startswith("ProxyCommand="))
        self.assertIn("-m albedo_plugins.ws", options[0])
        self.assertLess(
            options.index("StrictHostKeyChecking=no"),
            options.index("StrictHostKeyChecking=accept-new"),
        )
        self.assertIn("User=root", options)

        environment = albedo_ssh.env("colab-gpu-t4-1")
        self.assertEqual(
            environment["ALBEDO_WS_URL"],
            "wss://vm.colab.googleusercontent.com/colab/ssh?colab-runtime-proxy-token=proxy+tok%2F1",
        )
        self.assertEqual(
            json.loads(environment["ALBEDO_WS_HEADERS"]),
            {"X-Colab-Ssh-Pubkey": "ssh-ed25519 AAAA test@box"},
        )
        self.assertNotIn("wss://", " ".join(argv))
        self.assertNotIn("proxy+tok", " ".join(argv))
        self.assertNotIn("ALBEDO_WS_URL", albedo_ssh.env("other-host"))

        with patch.object(colab, "_send", return_value=(404, b"")):
            await colab.stop(live)
        self.assertNotIn("colab-gpu-t4-1", albedo_ssh.ALIASES)

    async def test_connect_needs_a_runtime_proxy_and_a_public_key(self):
        waiting = instance()
        with patch.object(colab, "instances", AsyncMock(return_value=[waiting])):
            with self.assertRaises(colab.ColabError) as cm:
                await colab.connect("gpu-t4-1")
        self.assertIn("no runtime proxy", str(cm.exception))

        ready = instance(url="https://vm", token="t")
        with patch.object(colab, "instances", AsyncMock(return_value=[ready])):
            with self.assertRaises(colab.ColabError) as cm:
                await colab.connect("gpu-t4-1")
        self.assertIn("no ssh public key", str(cm.exception))
        self.assertEqual(albedo_ssh.ALIASES, {})

    def test_setup_exports(self):
        loop = asyncio.new_event_loop()
        api = PythonApi(
            loop,
            lambda m, a: asyncio.sleep(0),
            RuntimeError,
            Capture,
            64 * 1024,
            lambda e: None,
            lambda c: None,
            lambda cls: None,
        )
        with patch.multiple(
            colab, host_call=colab.host_call, HostErrorType=colab.HostErrorType
        ):
            exports = colab.setup(api)
            self.assertIs(colab.HostErrorType, RuntimeError)
        loop.close()
        self.assertEqual(
            sorted(exports),
            [
                "ColabError",
                "ColabInstance",
                "ColabSshSessionError",
                "ColabStatus",
                "colab",
            ],
        )
        self.assertIs(exports["colab"], colab.colab)

    async def test_failed_connect_classifies_only_the_specific_refusal(self):
        (Path(self.home) / ".ssh" / "id_ed25519.pub").write_text(
            "ssh-ed25519 AAAA test"
        )
        for status, body, occupied in (
            (429, b'{"error":"already-active-session"}', True),
            (429, b'{"error":"rate-limit"}', False),
            (502, b"already-active-session", False),
            (101, b"", False),
        ):
            with (
                self.subTest(status=status, body=body),
                runtime_proxy(status, body) as (url, requests),
            ):
                live = instance(url=url, token="secret/never-log")
                original = colab.RemoteError("original failure")
                with (
                    patch.object(colab, "instances", AsyncMock(return_value=[live])),
                    patch.object(
                        colab.remote, "connect", AsyncMock(side_effect=original)
                    ),
                ):
                    with self.assertRaises(
                        colab.ColabSshSessionError if occupied else colab.RemoteError
                    ) as caught:
                        await colab.connect(live)
                if occupied:
                    assert isinstance(caught.exception, colab.ColabSshSessionError)
                    self.assertEqual(caught.exception.status, 429)
                    self.assertNotIn(live.token, str(caught.exception))
                    self.assertIn("destroys the VM", str(caught.exception))
                else:
                    self.assertIs(caught.exception, original)
                path, headers = requests[0]
                self.assertIn("/colab/ssh?", path)
                self.assertEqual(headers["Upgrade"], "websocket")
                self.assertEqual(headers["X-Colab-Ssh-Pubkey"], "ssh-ed25519 AAAA test")
                self.assertEqual(headers["Sec-WebSocket-Version"], "13")

    async def test_probe_network_failure_preserves_original_error(self):
        (Path(self.home) / ".ssh" / "id_ed25519.pub").write_text(
            "ssh-ed25519 AAAA test"
        )
        live = instance(url="https://vm", token="secret")
        original = colab.RemoteError("original")
        with (
            patch.object(colab, "instances", AsyncMock(return_value=[live])),
            patch.object(colab.remote, "connect", AsyncMock(side_effect=original)),
            patch.object(
                colab, "_ssh_session_occupied", side_effect=OSError("probe failure")
            ),
        ):
            with self.assertRaises(colab.RemoteError) as caught:
                await colab.connect(live)
        self.assertIs(caught.exception, original)

    async def test_success_does_not_probe(self):
        (Path(self.home) / ".ssh" / "id_ed25519.pub").write_text(
            "ssh-ed25519 AAAA test"
        )
        live = instance(url="https://vm", token="secret")
        with (
            patch.object(colab, "instances", AsyncMock(return_value=[live])),
            patch.object(colab.remote, "connect", AsyncMock(return_value="connection")),
            patch.object(colab, "_ssh_session_occupied") as probe,
        ):
            self.assertEqual(await colab.connect(live), "connection")
        probe.assert_not_called()

    async def test_runtime_helpers_refresh_and_quote_paths_without_ssh(self):
        response = {"type": "file", "content": "hello"}
        for name, path, route in (
            ("status", "", "/api/status"),
            ("contents", "a ?#%/b", "/api/contents/a%20%3F%23%25/b"),
            ("read", "text", "/api/contents/text"),
        ):
            with runtime_proxy(200, json.dumps(response).encode()) as (url, requests):
                live = instance(url=url, token="secret")
                with (
                    patch.object(
                        colab, "instances", AsyncMock(return_value=[live])
                    ) as listing,
                    patch.object(colab.remote, "connect", AsyncMock()) as ssh,
                ):
                    if name == "status":
                        result = await colab.runtime_status(live)
                    elif name == "contents":
                        result = await colab.contents(live, path)
                    else:
                        result = await colab.read(live, path)
                self.assertEqual(result, "hello" if name == "read" else response)
                listing.assert_awaited_once()
                ssh.assert_not_called()
                self.assertEqual(urllib.parse.urlsplit(requests[0][0]).path, route)

    async def test_pull_resume_and_ignored_range(self):
        for status, body, headers in (
            (206, b"def", {"Content-Range": "bytes 3-5/6"}),
            (200, b"abcdef", {"Content-Length": "6"}),
        ):
            with (
                self.subTest(status=status),
                runtime_proxy(status, body, headers) as (url, requests),
            ):
                live = instance(url=url, token="secret")
                local = Path(self.home) / "download"
                local.write_bytes(b"abc")
                with patch.object(colab, "instances", AsyncMock(return_value=[live])):
                    result = await colab.pull(live, "remote ?#", local)
                self.assertEqual(result, local)
                self.assertEqual(local.read_bytes(), b"abcdef")
                self.assertEqual(requests[0][1]["Range"], "bytes=3-")
                self.assertIn("/files/remote%20%3F%23?", requests[0][0])

    async def test_pull_rejects_bad_ranges_and_http_errors_without_overwriting(self):
        for status, headers in (
            (206, {"Content-Range": "bytes 0-2/3"}),
            (206, {"Content-Range": "garbage"}),
            (416, {}),
            (403, {}),
        ):
            with (
                self.subTest(status=status),
                runtime_proxy(status, b"xyz", headers) as (url, _),
            ):
                local = Path(self.home) / "download"
                local.write_bytes(b"abc")
                with self.assertRaises(colab.ColabError) as caught:
                    await asyncio.to_thread(
                        colab._pull, url + "?token=secret", local, True
                    )
                self.assertEqual(local.read_bytes(), b"abc")
                self.assertNotIn("secret", str(caught.exception))

    async def test_pull_detects_truncation_and_keeps_partial_file(self):
        with runtime_proxy(206, b"d", {"Content-Range": "bytes 3-5/6"}) as (url, _):
            local = Path(self.home) / "download"
            local.write_bytes(b"abc")
            with self.assertRaisesRegex(colab.ColabError, "incomplete"):
                await asyncio.to_thread(colab._pull, url, local, True)
            self.assertEqual(local.read_bytes(), b"abcd")

    async def test_pull_fresh_multichunk_file_replaces_local_when_resume_disabled(self):
        body = b"x" * ((2 << 20) + 17)
        with runtime_proxy(200, body, {"Content-Length": str(len(body))}) as (
            url,
            requests,
        ):
            local = Path(self.home) / "nested" / "download"
            local.parent.mkdir()
            local.write_bytes(b"old")
            await asyncio.to_thread(colab._pull, url, local, False)
            self.assertEqual(local.read_bytes(), body)
            self.assertNotIn("Range", requests[0][1])
