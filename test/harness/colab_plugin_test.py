"""Unit tests for the Google Colab tool plugin (albedo_plugins.colab)."""

from __future__ import annotations

import asyncio
import json
import os
from pathlib import Path
import sys
import tempfile
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
            sorted(exports), ["ColabError", "ColabInstance", "ColabStatus", "colab"]
        )
        self.assertIs(exports["colab"], colab.colab)
