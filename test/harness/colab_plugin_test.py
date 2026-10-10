"""Unit tests for the Google Colab tool plugin (albedo_plugins.colab)."""

from __future__ import annotations

import asyncio
import io
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

from albedo_api import PythonApi  # noqa: E402
from albedo_capture import Capture  # noqa: E402
from albedo_plugins import colab  # noqa: E402
import scratch  # noqa: E402

scratch.claim("harness")


class FakeResponse:
    def __init__(self, status: int, body: bytes, headers: dict[str, str] | None = None):
        self.status = status
        self._body = body
        self.headers = headers or {}

    def read(self) -> bytes:
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        pass


class ColabPluginTest(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        colab.reset_configuration()
        self.home = tempfile.mkdtemp(prefix="albedo-colab-home-")
        self.albedo_home = Path(self.home) / ".albedo"
        self.albedo_home.mkdir(parents=True, exist_ok=True)
        self.ssh_dir = Path(self.home) / ".ssh"
        self.ssh_dir.mkdir(parents=True, exist_ok=True)
        self.ssh_config = self.ssh_dir / "config"

        self.env_patch = patch.dict(
            os.environ,
            {
                "HOME": self.home,
                "ALBEDO_HOME": str(self.albedo_home),
            },
        )
        self.env_patch.start()
        self.addCleanup(self.env_patch.stop)
        self.addCleanup(colab.reset_configuration)

    def write_creds(self, data: dict):
        (self.albedo_home / "creds.json").write_text(json.dumps(data), encoding="utf-8")

    def test_read_colab_credentials_oauth_list(self):
        self.write_creds(
            {
                "accounts": {
                    "google-colab": [
                        {
                            "type": "oauth",
                            "access": "token-1",
                            "email": "user1@example.com",
                            "selected": False,
                        },
                        {
                            "type": "oauth",
                            "access": "token-2",
                            "email": "user2@example.com",
                            "selected": True,
                        },
                    ]
                }
            }
        )
        cred = colab.read_colab_credentials()
        self.assertEqual(cred.get("access"), "token-2")
        self.assertEqual(cred.get("email"), "user2@example.com")
        self.assertEqual(colab.get_token(), "token-2")

    def test_read_colab_credentials_single_dict(self):
        self.write_creds(
            {
                "accounts": {
                    "google-colab": {
                        "type": "oauth",
                        "accessToken": "tok-single",
                        "email": "single@example.com",
                    }
                }
            }
        )
        cred = colab.read_colab_credentials()
        self.assertEqual(cred.get("accessToken"), "tok-single")
        self.assertEqual(colab.get_token(), "tok-single")

    def test_read_colab_credentials_string(self):
        self.write_creds(
            {
                "accounts": {
                    "google-colab": "raw-token-str",
                }
            }
        )
        self.assertEqual(colab.get_token(), "raw-token-str")

    def test_read_colab_credentials_missing_file(self):
        with self.assertRaises(colab.ColabError) as cm:
            colab.read_colab_credentials()
        self.assertIn("no creds.json found", str(cm.exception))

    def test_read_colab_credentials_missing_account(self):
        self.write_creds({"accounts": {"other-service": "tok"}})
        with self.assertRaises(colab.ColabError) as cm:
            colab.read_colab_credentials()
        self.assertIn("no 'google-colab' account found", str(cm.exception))

    def test_read_colab_credentials_empty_token(self):
        self.write_creds({"accounts": {"google-colab": {"type": "oauth"}}})
        with self.assertRaises(colab.ColabError) as cm:
            colab.get_token()
        self.assertIn("has no access token", str(cm.exception))

    def test_configure_and_environment_token_override(self):
        colab.configure(token="in-memory-token")
        self.assertEqual(colab.get_token(), "in-memory-token")

        colab.reset_configuration()
        with patch.dict(os.environ, {"COLAB_TOKEN": "env-token"}):
            self.assertEqual(colab.get_token(), "env-token")

    async def test_instances_query(self):
        colab.configure(token="test-token")

        response_body = b")]}'\n" + json.dumps(
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
        ).encode("utf-8")

        with patch(
            "albedo_plugins.colab._sync_http_request",
            return_value=(200, response_body),
        ) as mock_req:
            insts = await colab.instances()
            self.assertEqual(len(insts), 1)
            inst = insts[0]
            self.assertEqual(inst.id, "gpu-t4-s-12345")
            self.assertEqual(inst.endpoint, "gpu-t4-s-12345")
            self.assertEqual(inst.gpu, "T4")
            self.assertEqual(inst.variant, "GPU")
            self.assertEqual(inst.shape, "standard")
            self.assertEqual(inst.status, "active")
            self.assertEqual(inst.url, "https://vm1.colab.googleusercontent.com")
            self.assertEqual(inst.token, "proxy-tok-123")

            # Check request headers
            method, url, headers, body, _ = mock_req.call_args[0]
            self.assertEqual(method, "GET")
            self.assertIn("/tun/m/assignments", url)
            self.assertEqual(headers["Authorization"], "Bearer test-token")
            self.assertEqual(headers["X-Colab-Tunnel"], "Google")

    async def test_status_summary_and_single_lookup(self):
        self.write_creds(
            {
                "accounts": {
                    "google-colab": {
                        "access": "test-tok",
                        "email": "user@example.com",
                    }
                }
            }
        )

        inst_data = [
            colab.ColabInstance(
                id="gpu-t4-1",
                endpoint="gpu-t4-1",
                name="dev-t4",
                variant="GPU",
                accelerator="T4",
                shape="standard",
                status="active",
                url=None,
                token=None,
                token_expires_in=None,
                raw={},
            )
        ]

        with patch("albedo_plugins.colab.instances", AsyncMock(return_value=inst_data)):
            overall = await colab.status()
            self.assertTrue(overall.authenticated)
            self.assertEqual(overall.email, "user@example.com")
            self.assertEqual(overall.active, 1)
            self.assertIn("gpu-t4-1", str(overall))

            # Query specific instance by id
            inst = await colab.status("gpu-t4-1")
            self.assertEqual(inst.id, "gpu-t4-1")

            # Query by name
            inst_by_name = await colab.status("dev-t4")
            self.assertEqual(inst_by_name.id, "gpu-t4-1")

            # Non-existent instance raises ColabError
            with self.assertRaises(colab.ColabError):
                await colab.status("missing-instance")

    def test_format_notebook_hash(self):
        nbh = colab._format_notebook_hash()
        self.assertEqual(len(nbh), 44)
        self.assertNotIn("-", nbh)
        self.assertTrue(nbh.endswith("."))

    async def test_launch_gpu_instance(self):
        colab.configure(token="test-token")

        token_body = b')]}\'\n{"token": "xsrf-token-123"}'
        assign_body = json.dumps(
            {
                "assignment": {
                    "endpoint": "gpu-t4-assigned-999",
                    "variant": "GPU",
                    "accelerator": "T4",
                    "shape": "highmem",
                    "status": "active",
                    "runtimeProxyInfo": {
                        "url": "https://vm-t4.colab.googleusercontent.com",
                        "token": "tok-t4",
                    },
                }
            }
        ).encode("utf-8")

        with patch(
            "albedo_plugins.colab._sync_http_request",
            side_effect=[(200, token_body), (200, assign_body)],
        ) as mock_req:
            inst = await colab.launch(gpu="T4", mem="high")
            self.assertEqual(inst.id, "gpu-t4-assigned-999")
            self.assertEqual(inst.accelerator, "T4")
            self.assertEqual(inst.gpu, "T4")
            self.assertEqual(inst.mem, "high")
            self.assertEqual(mock_req.call_count, 2)

            # Step 1: GET assignment/XSRF
            m1, u1, h1, b1, _ = mock_req.call_args_list[0][0]
            self.assertEqual(m1, "GET")
            self.assertIn("/tun/m/assign", u1)
            self.assertIn("authuser=0", u1)
            self.assertIn("variant=GPU", u1)
            self.assertIn("accelerator=T4", u1)
            self.assertIn("shape=hm", u1)
            self.assertIsNone(b1)

            # Step 2: POST with X-Goog-Colab-Token header
            m2, u2, h2, b2, _ = mock_req.call_args_list[1][0]
            self.assertEqual(m2, "POST")
            self.assertIn("/tun/m/assign", u2)
            self.assertEqual(h2.get("X-Goog-Colab-Token"), "xsrf-token-123")
            self.assertIsNone(b2)

    async def test_launch_existing_assignment(self):
        colab.configure(token="test-token")

        existing_body = json.dumps(
            {
                "endpoint": "gpu-t4-existing-111",
                "variant": "GPU",
                "accelerator": "T4",
                "runtimeProxyInfo": {
                    "url": "https://vm-existing.colab.googleusercontent.com",
                    "token": "tok-existing",
                },
            }
        ).encode("utf-8")

        with patch(
            "albedo_plugins.colab._sync_http_request",
            return_value=(200, existing_body),
        ) as mock_req:
            inst = await colab.launch(gpu="T4")
            self.assertEqual(inst.id, "gpu-t4-existing-111")
            self.assertEqual(mock_req.call_count, 1)

    async def test_launch_capacity_exhausted_503(self):
        colab.configure(token="test-token")
        with patch(
            "albedo_plugins.colab._sync_http_request",
            return_value=(503, b"Resource exhausted"),
        ):
            with self.assertRaises(colab.ColabError) as cm:
                await colab.launch(gpu="A100")
            self.assertIn("capacity exhausted", str(cm.exception))

    async def test_stop_instance(self):
        colab.configure(token="test-token")

        token_body = b')]}\'\n{"token": "unassign-xsrf-456"}'
        with patch(
            "albedo_plugins.colab._sync_http_request",
            side_effect=[(200, token_body), (204, b"")],
        ) as mock_req:
            result = await colab.stop("gpu-t4-s-12345")
            self.assertTrue(result.success)
            self.assertEqual(result.id, "gpu-t4-s-12345")
            self.assertEqual(mock_req.call_count, 2)

            # Step 1: GET XSRF token
            m1, u1, _, _, _ = mock_req.call_args_list[0][0]
            self.assertEqual(m1, "GET")
            self.assertIn("/tun/m/unassign/gpu-t4-s-12345", u1)
            self.assertIn("authuser=0", u1)

            # Step 2: POST with token
            m2, u2, h2, _, _ = mock_req.call_args_list[1][0]
            self.assertEqual(m2, "POST")
            self.assertIn("/tun/m/unassign/gpu-t4-s-12345", u2)
            self.assertEqual(h2.get("X-Goog-Colab-Token"), "unassign-xsrf-456")

        # 404 handled gracefully
        with patch(
            "albedo_plugins.colab._sync_http_request",
            return_value=(404, b"Not Found"),
        ):
            result = await colab.stop("already-stopped")
            self.assertFalse(result.success)
            self.assertIn("not found or already stopped", str(result.message))

    def test_configure_and_remove_ssh_config(self):
        proxy_cmd = "colab ssh --proxy-mode -s dev-gpu"
        alias = colab.configure_ssh(
            "dev-gpu",
            proxy_cmd,
            ssh_config_path=self.ssh_config,
        )
        self.assertEqual(alias, "colab-dev-gpu")
        self.assertTrue(self.ssh_config.is_file())
        content = self.ssh_config.read_text(encoding="utf-8")
        self.assertIn("Host colab-dev-gpu", content)
        self.assertIn(f"ProxyCommand {proxy_cmd}", content)
        self.assertIn("User root", content)

        # Updating the same alias should replace the block without duplicate Hosts
        new_proxy_cmd = "colab ssh --proxy-mode -s dev-gpu --rm"
        colab.configure_ssh(
            "dev-gpu",
            new_proxy_cmd,
            ssh_config_path=self.ssh_config,
        )
        updated = self.ssh_config.read_text(encoding="utf-8")
        self.assertEqual(updated.count("Host colab-dev-gpu"), 1)
        self.assertIn(new_proxy_cmd, updated)

        # Remove ssh config
        removed = colab.remove_ssh_config(
            "colab-dev-gpu", ssh_config_path=self.ssh_config
        )
        self.assertTrue(removed)
        final_content = self.ssh_config.read_text(encoding="utf-8")
        self.assertNotIn("Host colab-dev-gpu", final_content)

    async def test_connect_delegates_to_remote(self):
        mock_remote_connect = AsyncMock()
        mock_remote_connect.return_value = {"type": "mock_remote_connection"}

        inst = colab.ColabInstance(
            id="gpu-t4-s-777",
            endpoint="gpu-t4-s-777",
            name="test-gpu",
            variant="GPU",
            accelerator="T4",
            shape="standard",
            status="active",
            url=None,
            token=None,
            token_expires_in=None,
            raw={},
        )

        conn = await colab.connect(
            inst,
            remote_cwd="/content/myproject",
            python="/opt/conda/bin/python",
            ssh_config_path=self.ssh_config,
            remote_connect=mock_remote_connect,
        )

        self.assertEqual(conn, {"type": "mock_remote_connection"})
        mock_remote_connect.assert_called_once_with(
            "colab-gpu-t4-s-777",
            remote_cwd="/content/myproject",
            python="/opt/conda/bin/python",
            modules=None,
            timeout=60.0,
        )

        # Verify ssh config block was created
        content = self.ssh_config.read_text(encoding="utf-8")
        self.assertIn("Host colab-gpu-t4-s-777", content)

    def test_ws_framing_roundtrip(self):
        data = b"Testing colab websocket stdio tunneling"
        frame = colab._encode_ws_frame(data, opcode=0x2, mask=True)

        class SockMock:
            def __init__(self, raw):
                self._stream = io.BytesIO(raw)

            def recv(self, n):
                return self._stream.read(n)

        frame_res = colab._read_ws_frame(SockMock(frame))
        self.assertIsNotNone(frame_res)
        assert frame_res is not None
        opcode, payload = frame_res
        self.assertEqual(opcode, 0x2)
        self.assertEqual(payload, data)

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
        exports = colab.setup(api)
        loop.close()

        self.assertIn("colab", exports)
        self.assertIn("Colab", exports)
        self.assertIn("ColabError", exports)
        self.assertIn("ColabInstance", exports)
        self.assertIn("ColabStatus", exports)
        self.assertIs(exports["colab"], colab.colab)
        self.assertIs(exports["ColabError"], colab.ColabError)
