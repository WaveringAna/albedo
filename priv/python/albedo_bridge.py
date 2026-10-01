"""Copy a detached kernel's frames between this process's stdio and its socket.

    albedo_bridge.py start <run_dir> <modules-json>
    albedo_bridge.py attach <run_dir>

The daemon talks to this process as it once talked to the kernel itself, over
4-byte-length-framed stdio, and writes the attach frame first. `start` reads
that frame to learn the kernel's token, starts the albedo_kernel.py beside this
file in its own session (the token travels over the kernel's stdin, never
argv), and waits for its socket; `attach` connects to a kernel that is already running. Either way this
process announces the bundle it runs from, then copies bytes both ways until
one side closes. Killing it never touches the kernel.

Exit status 3 means no kernel is there to attach to, so the daemon can tell a
kernel that is gone from a connection that merely dropped.
"""

from __future__ import annotations

import errno
import os
import socket
import subprocess
import sys
import threading
import time
from collections.abc import Callable

import albedo_bundle
import albedo_link

GONE = 3
START_TIMEOUT = 10.0  # seconds a starting kernel has to bind its socket


def connect(run_dir: str) -> socket.socket | None:
    """The kernel's socket, or None when nothing listens there."""
    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        os.chdir(run_dir)
        connection.connect(albedo_link.SOCKET)
        return connection
    except OSError as error:
        connection.close()
        if error.errno in (errno.ENOENT, errno.ECONNREFUSED, errno.ENOTDIR):
            return None
        raise


KERNEL = os.path.join(os.path.dirname(os.path.abspath(__file__)), "albedo_kernel.py")


def start(run_dir: str, modules: str, token: str) -> socket.socket:
    os.makedirs(run_dir, mode=0o700, exist_ok=True)
    with open(os.path.join(run_dir, "kernel.log"), "ab") as log:
        kernel = subprocess.Popen(
            [sys.executable, "-u", KERNEL, "--run", run_dir, modules],
            stdin=subprocess.PIPE,
            stdout=subprocess.DEVNULL,
            stderr=log,
            start_new_session=True,
            close_fds=True,
        )
    assert kernel.stdin is not None
    kernel.stdin.write(token.encode() + b"\n")
    kernel.stdin.close()
    deadline = time.monotonic() + START_TIMEOUT
    while time.monotonic() < deadline:
        connection = connect(run_dir)
        if connection is not None:
            return connection
        if kernel.poll() is not None:
            break
        time.sleep(0.02)
    sys.stderr.write(
        f"albedo_bridge: kernel did not start (see {run_dir}/kernel.log)\n"
    )
    sys.exit(GONE)


def stdin(size: int) -> bytes:
    return os.read(0, size)


def stdout(data: bytes) -> int:
    return os.write(1, data)


def pump(source: Callable[[int], bytes], sink: Callable[[bytes], int | None]) -> None:
    try:
        while data := source(65536):
            albedo_link.write_all(sink, data)
    except OSError:
        pass
    os._exit(0)


def main(argv: list[str]) -> None:
    mode, run_dir = argv[1], argv[2]
    if mode == "start":
        attach = albedo_link.read_frame(stdin)
        if not isinstance(attach, dict) or not isinstance(attach.get("attach"), dict):
            sys.exit(2)
        token = attach["attach"].get("token")
        if not isinstance(token, str):
            sys.exit(2)
        connection = start(run_dir, argv[3], token)
        first = albedo_link.encode(attach)
    else:
        found = connect(run_dir)
        if found is None:
            sys.exit(GONE)
        connection, first = found, None
    albedo_link.write_frame(
        stdout, albedo_link.encode({"bridge": {"bundle": albedo_bundle.digest()}})
    )
    if first is not None:
        albedo_link.write_frame(connection.send, first)
    threading.Thread(target=pump, args=(stdin, connection.send), daemon=True).start()
    pump(connection.recv, stdout)


if __name__ == "__main__":
    main(sys.argv)
