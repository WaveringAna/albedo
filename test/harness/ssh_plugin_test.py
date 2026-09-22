"""The ssh plugin resolves one target and moves bytes over quoted ssh scripts."""
import asyncio
import base64
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "priv" / "python"))
from albedo_api import PythonApi, load_plugins
from albedo_plugins import ssh as plugin


def done(returncode=0, stdout=b"", stderr=b""):
    return subprocess.CompletedProcess([], returncode, stdout, stderr)


class SshPluginTest(unittest.TestCase):
    def setUp(self):
        plugin.configured.clear()
        plugin.local_cwd = None
        self.loop = asyncio.new_event_loop()
        self.addCleanup(self.loop.close)
        self.api = PythonApi(self.loop, None, RuntimeError, None, 100,
                             lambda event: None, lambda close: None, lambda _: None)
        self.namespace = {"__name__": "__main__", "cells": object(), "output": object()}

    def scripted(self, returncode=0, stdout=b"", stderr=b""):
        calls = []

        def run(command, capture_output, timeout):
            calls.append(command)
            return done(returncode, stdout, stderr)

        self.calls = calls
        return patch.object(plugin.subprocess, "run", side_effect=run)

    def test_setup_binds_the_namespace_object(self):
        load_plugins(["ssh"], self.api, self.namespace)
        self.assertIs(self.namespace["ssh"], plugin.ssh)

    def test_run_resolves_env_target_and_wraps_the_remote_cwd(self):
        plugin.local_cwd = "/home/regent/app"
        with patch.dict("os.environ", {"ALBEDO_SSH": "deploy@box:/srv/app"}):
            with self.scripted(stdout=b"ok\n"):
                result = plugin.ssh.run("ls")
        self.assertEqual(self.calls[0][5], "deploy@box")
        self.assertEqual(self.calls[0][6], "cd /srv/app && ls")
        self.assertEqual(result, {"command": "ls", "host": "deploy@box",
                                  "exit_code": 0, "stdout": "ok\n", "stderr": ""})

    def test_configure_asks_the_remote_pwd_once_then_answers_every_later_call(self):
        with self.scripted(stdout=b"/srv/app\n"):
            resolved = plugin.ssh.configure("deploy@box")
        self.assertEqual(resolved, {"host": "deploy@box", "remoteCwd": "/srv/app"})
        self.assertEqual(self.calls[0][6], "pwd")
        with self.scripted():
            plugin.ssh.run("whoami")
        self.assertEqual(self.calls[0][6], "cd /srv/app && whoami")

    def test_read_raises_with_stderr_and_write_travels_base64(self):
        plugin.local_cwd = "/home/regent/app"
        target = patch.dict("os.environ", {"ALBEDO_SSH": "deploy@box:/srv/app"})
        with target, self.scripted(returncode=1, stderr=b"cat: nope: No such file"):
            with self.assertRaisesRegex(plugin.SshError, "nope: No such file"):
                plugin.ssh.read("/srv/missing")
        with target, self.scripted():
            plugin.ssh.write("/home/regent/app/notes dir/a.txt", "h\u00e9llo")
        script = self.calls[0][6]
        encoded = script.split("printf '%s' ", 1)[1].split(" | base64 -d >", 1)[0]
        self.assertEqual(base64.b64decode(encoded).decode(), "h\u00e9llo")
        self.assertIn("| base64 -d > '/srv/app/notes dir/a.txt'", script)

    def test_paths_outside_the_workspace_pass_through(self):
        with patch.dict("os.environ", {"ALBEDO_SSH": "deploy@box:/srv"}):
            with self.scripted():
                plugin.ssh.read("/etc/hosts")
        self.assertEqual(self.calls[0][6], "cat /etc/hosts")

    def test_target_parses_hosts_paths_and_bare_ipv6(self):
        self.assertEqual(plugin.parse_target("user@box"),
                         {"host": "user@box", "remote_cwd": None})
        self.assertEqual(plugin.parse_target("user@box:/a b/c"),
                         {"host": "user@box", "remote_cwd": "/a b/c"})
        self.assertEqual(plugin.parse_target("::1"),
                         {"host": "::1", "remote_cwd": None})

    def test_extensions_json_answers_when_env_is_silent(self):
        with tempfile.TemporaryDirectory() as home:
            Path(home, "extensions.json").write_text(
                '{"ssh": {"host": "ci@runner", "remoteCwd": "/build"}}'
            )
            with patch.dict("os.environ", {"ALBEDO_HOME": home}):
                with self.scripted():
                    plugin.ssh.run("true")
        self.assertEqual(self.calls[0][5], "ci@runner")
        self.assertEqual(self.calls[0][6], "cd /build && true")

    def test_a_misuse_error_names_every_resolution_source(self):
        with patch.dict("os.environ", {}, clear=True):
            with self.assertRaisesRegex(plugin.SshError, "extensions.json"):
                plugin.ssh.run("true")


if __name__ == "__main__":
    unittest.main()
