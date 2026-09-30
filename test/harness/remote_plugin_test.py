"""A loopback SSH transport checks remote relay, streaming jobs and degraded boot without live SSH credentials."""

import asyncio
import contextlib
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "priv" / "python"))
from albedo_api import PythonApi
from albedo_plugins import remote

sys.path.insert(0, str(ROOT / "test"))
import scratch  # noqa: E402

# Temporary workspaces and homes go under this run's scratch directory, which
# is removed at exit.
scratch.claim("harness")


class FakeHostError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code, self.message = code, message


class FakeCapture:
    """The retained channel a background job writes into."""

    def __init__(self, id):
        self.id, self.seen, self.tail_data = id, 0, bytearray()
        self.data = bytearray()

    def write(self, text):
        data = text.encode()
        self.data.extend(data)
        self.seen += len(data)
        self.tail_data.extend(data)
        del self.tail_data[:-65536]

    def read(self, offset=0, limit=4000):
        return bytes(self.data[offset : offset + limit]).decode(errors="ignore")


def fake_ssh_path() -> str:
    """A loopback ssh: option pairs, target, then run the command locally."""
    script = Path(tempfile.mkdtemp(prefix="albedo-fake-ssh-")) / "ssh"
    script.write_text(
        "#!/bin/sh\n"
        "while [ $# -gt 0 ]; do\n"
        '  case "$1" in\n'
        "    -*) shift 2 ;;\n"
        "    *) break ;;\n"
        "  esac\n"
        "done\n"
        "shift\n"
        'exec sh -c "$*"\n'
    )
    script.chmod(0o755)
    return str(script)


FAKE_SSH = fake_ssh_path()


async def daemon_host(method, args):
    if method == "work.list":
        return [
            {
                "id": 1,
                "title": "from-the-daemon",
                "notes": "",
                "status": "open",
                "parent": None,
                "session": None,
                "run": None,
                "revision": 1,
            }
        ]
    if method == "work.get":
        raise FakeHostError("missing", f"no work item {args['id']}")
    return {}


class RemotePluginTest(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        remote.configured.clear()
        remote.connections.clear()
        self.home = tempfile.mkdtemp(prefix="albedo-remote-home-")
        self.workspace = tempfile.mkdtemp(prefix="albedo-remote-ws-")
        os.chdir(self.workspace)
        self.environment = patch.dict(
            os.environ,
            {
                "HOME": self.home,
                "ALBEDO_HOME": os.path.join(self.home, ".albedo"),
                "ALBEDO_SSH": "loopback",
            },
        )
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.addCleanup(os.chdir, ROOT)
        self.fake_ssh = patch.object(remote, "ssh_base", lambda: [FAKE_SSH])
        self.fake_ssh.start()
        self.addCleanup(self.fake_ssh.stop)

    async def asyncSetUp(self):
        self.loop = asyncio.get_running_loop()
        self.api = PythonApi(
            self.loop,
            daemon_host,
            FakeHostError,
            FakeCapture,
            64 * 1024,
            lambda event: None,
            lambda close: None,
            lambda cls: None,
            2,
            ["run", "files", "work", "skills", "remote"],
        )
        self.namespace = {}
        self.remote = remote.setup(self.api)["remote"]

    async def connect(self, **kwargs):
        return await self.remote.connect(**kwargs)

    async def test_connect_boots_the_kernel_and_answers_every_tool(self):
        rem = await self.connect()
        self.addCleanup(rem.close)
        self.assertIn("kernel", repr(rem))
        self.assertIn("run", (await rem.tools())["names"])

        text = await rem.files.read("/etc/hosts")
        self.assertIsInstance(text, str)

        # The call is synchronous like local run; the reference settles on await.
        job = rem.run(
            sys.executable,
            "-c",
            "import time; print('loopback-echo', flush=True); time.sleep(0.2)",
        )
        self.assertIn("pending", repr(job))
        self.assertIsNone(job.poll())
        self.assertEqual(job.tail(), "")
        awaited = await job
        self.assertIs(awaited, job)
        self.assertEqual(job.poll(), 0)
        self.assertEqual(job.exit_code, 0)
        self.assertEqual(job.returncode, 0)  # subprocess's spelling answers too
        self.assertFalse(job.timed_out)
        self.assertIsNotNone(job.duration)
        self.assertGreaterEqual(job.duration, 0.2)
        self.assertEqual(job.tail(), "loopback-echo\n")
        self.assertIsNotNone(job.id)
        self.assertIn("tail", dir(job))  # dir() mixes local and mirrored names
        ending = await job.stop  # awaiting an uncalled method runs it
        self.assertTrue(ending.gone)

    async def test_session_tools_relay_to_this_daemon(self):
        rem = await self.connect()
        self.addCleanup(rem.close)
        items = await rem.work.list()
        self.assertEqual(items[0]["title"], "from-the-daemon")
        with self.assertRaises(remote.RemoteExecutionError) as raised:
            await rem.work.get(99)
        self.assertEqual(raised.exception.ename, "WorkError")

    async def test_remote_jobs_pipe_and_read_lines_like_local_ones(self):
        rem = await self.connect()
        self.addCleanup(rem.close)
        Path(self.workspace, "sub").mkdir()
        Path(self.workspace, "sub", "notes.txt").write_text("b\na\nb\n")
        job = (
            await rem.run("cat", "notes.txt", cwd="sub").pipe("sort").pipe("uniq", "-c")
        )
        self.assertEqual(job.exit_code, 0)
        self.assertEqual(job.tail(lines=1).split(), ["2", "b"])
        self.assertEqual((await job.head(lines=1)).split(), ["1", "a"])

    async def test_a_kernel_that_cannot_boot_degrades_with_a_warning(self):
        warning = io.StringIO()
        with contextlib.redirect_stdout(warning):
            rem = await self.connect(modules=["definitely-not-a-module"])
        self.addCleanup(rem.close)
        self.assertIn("degraded", repr(rem))
        self.assertIn(
            "for pipes or shell syntax use rem.shell('git log --oneline | rg fix')",
            warning.getvalue(),
        )
        Path(self.workspace, "sub").mkdir()
        parity = rem.run(
            sys.executable,
            "-c",
            "import os, sys; print(os.path.basename(os.getcwd()), os.environ['WHO'], sys.stdin.read())",
            cwd="sub",
            env={"WHO": "me"},
            stdin="fed",
        )
        await parity
        self.assertEqual(parity.tail(), "sub me fed\n")
        self.assertEqual(parity.head(lines=1), "sub me fed\n")
        piped = await rem.shell("printf 'b\\na\\nb\\n' | sort | uniq -c", cwd="sub")
        self.assertEqual(piped.exit_code, 0)
        self.assertEqual(piped.tail().split(), ["1", "a", "2", "b"])
        self.assertEqual(piped.command, "printf 'b\\na\\nb\\n' | sort | uniq -c")
        with self.assertRaisesRegex(TypeError, "stdin is text or bytes"):
            rem.shell("cat", stdin=piped)
        job = rem.run("echo", "degraded-echo")
        await job
        self.assertEqual(job.poll(), 0)
        self.assertEqual(job.returncode, 0)  # subprocess's spelling answers too
        self.assertIsNotNone(job.duration)
        self.assertFalse(job.timed_out)
        self.assertEqual(job.tail(), "degraded-echo\n")
        with self.assertRaises(AttributeError) as raised:
            rem.files
        self.assertIn("degraded to ssh command mode", str(raised.exception))
        tools = await rem.tools()
        self.assertIn("degraded", tools)


if __name__ == "__main__":
    unittest.main()
