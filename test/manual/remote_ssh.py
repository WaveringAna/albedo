"""Opt-in: a real ssh target end to end. Needs key auth and python3 remotely.

    python3 test/manual/remote_ssh.py [user@host]

Exercises staging, kernel boot, tool calls, relay, degradation is NOT tested
here (that needs a broken target), and control-master reuse across calls.
"""

import asyncio
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "priv" / "python"))
from albedo_api import PythonApi  # noqa: E402
from albedo_plugins import remote  # noqa: E402


class FakeCapture:
    def __init__(self, id):
        self.id, self.seen, self.tail_data = id, 0, bytearray()
        self.raw_data = bytearray()
        self.raw_seen = 0
        self.data = bytearray()

    def write(self, text):
        data = text.encode()
        self.data.extend(data)
        self.seen += len(data)
        self.tail_data.extend(data)

    def read(self, offset: int = 0, limit: int = 4000) -> str:
        return bytes(self.data[offset : offset + limit]).decode(errors="ignore")


async def main(host: str) -> int:
    loop = asyncio.get_running_loop()

    async def daemon_host(method, args):
        return [{"relay": True, "method": method}]

    api = PythonApi(
        loop,
        daemon_host,
        RuntimeError,
        FakeCapture,
        65536,
        lambda event: None,
        lambda close: None,
        lambda cls: None,
        2,
        ["run", "files", "work", "skills", "remote"],
    )
    remote.setup(api)
    rem_mod = remote.Remote()
    rem = await rem_mod.connect(host=host)
    print("connected:", repr(rem))
    tools = await rem.tools()
    print("remote tools:", tools["names"])

    # the local-run shape: sync call, sync state, one await for completion
    job = rem.run("uname", "-s")
    print("mid-run tail:", repr(job.tail()), "poll:", job.poll())
    await job
    print("run:", job.tail().strip(), "exit:", job.poll())

    listing = await rem.files.ls(".")
    print("files.ls entries:", len(listing))
    relay = await rem.work.list()
    print("relay answer:", relay[0])

    import time

    started = time.monotonic()
    again = rem.run("true")
    await again
    print(f"second call over the control socket: {time.monotonic() - started:.2f}s")

    await rem.close()
    print("closed:", rem.closed)
    return 0


if __name__ == "__main__":
    target = (
        sys.argv[1] if len(sys.argv) > 1 else os.environ.get("ALBEDO_SSH", "localhost")
    )
    raise SystemExit(asyncio.run(main(target)))
