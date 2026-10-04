"""The kernel's half of the durable session layer.

A detached kernel listens on a unix socket in its run directory. Whoever
attaches (a bridge the daemon runs, locally today and over ssh later) presents
the kernel's secret token; the newest attach wins and cuts the previous
connection off. Every frame after the handshake travels as
``{"seq": n, "ack": m, "frame": {...}}``: the kernel keeps what it sent until
the daemon acknowledges it and resends the rest on the next attach, and it
drops any daemon frame it has already seen, so a reconnect neither loses nor
repeats a message. A kernel run over plain stdio (the remote plugin's targets)
keeps the raw frames and ends with its pipe.
"""

from __future__ import annotations

import collections
import hmac
import json
import os
import socket
import struct
import threading
import time
from collections.abc import Callable
from typing import Any, BinaryIO

PROTOCOL = 1  # framing version; hello fields describe the current bundle
MAX_FRAME = 8 * 1024 * 1024
SOCKET = "kernel.sock"
ATTACH_TIMEOUT = 10.0  # seconds a fresh connection has to present its token
OUTBOX_FRAMES = 4096
OUTBOX_BYTES = 64 * 1024 * 1024
# Frames whose newest copy supersedes every older unacknowledged one, by the
# field naming what they describe. Everything else must be delivered.
COALESCE = {"mirror": "handle", "trace": "id", "jobs": None, "cells": None}


def encode(value: object) -> bytes:
    return json.dumps(value, ensure_ascii=True, separators=(",", ":")).encode()


def envelope(seq: int, ack: int, frame: bytes) -> bytes:
    return b'{"seq":%d,"ack":%d,"frame":%s}' % (seq, ack, frame)


def write_all(write: Callable[[Any], int | None], data: bytes) -> None:
    remaining = memoryview(data)
    while remaining:
        written = write(remaining)
        remaining = remaining[len(remaining) if written is None else written :]


def write_frame(write: Callable[[Any], int | None], data: bytes) -> None:
    write_all(write, struct.pack(">I", len(data)) + data)


def read_exact(read: Callable[[int], bytes], size: int) -> bytes:
    data = bytearray()
    while len(data) < size:
        chunk = read(size - len(data))
        if not chunk:
            raise EOFError()
        data.extend(chunk)
    return bytes(data)


def read_frame(read: Callable[[int], bytes]) -> object:
    size = struct.unpack(">I", read_exact(read, 4))[0]
    if size > MAX_FRAME:
        raise ValueError("control frame too large")
    return json.loads(read_exact(read, size))


class Outbox:
    """Frames sent and not yet acknowledged, oldest first.

    Coalescing frames replace their older unacknowledged copy, so a flood of
    output mirrors costs one entry. Past the bound, the oldest coalescing
    frames go first; a must-deliver frame is dropped only when nothing else is
    left, and `dropped` counts every such loss for the next hello.
    """

    def __init__(self, frames: int = OUTBOX_FRAMES, size: int = OUTBOX_BYTES):
        self.limit_frames = frames
        self.limit_bytes = size
        self.seq = 0
        self.size = 0
        self.dropped = 0
        self.entries: collections.OrderedDict[int, tuple[bytes, object]] = (
            collections.OrderedDict()
        )
        self.keys: dict[object, int] = {}

    def add(self, frame: dict[str, object]) -> tuple[int, bytes]:
        data = encode(frame)
        self.seq += 1
        kind = frame.get("type")
        key: object = None
        if isinstance(kind, str) and kind in COALESCE:
            field = COALESCE[kind]
            key = (kind, frame.get(field) if field else None)
            older = self.keys.pop(key, None)
            if older is not None:
                self._remove(older)
        self.entries[self.seq] = (data, key)
        self.size += len(data)
        if key is not None:
            self.keys[key] = self.seq
        self._bound()
        return self.seq, data

    def ack(self, upto: int) -> None:
        while self.entries:
            seq = next(iter(self.entries))
            if seq > upto:
                return
            self._remove(seq)

    def pending(self) -> list[tuple[int, bytes]]:
        return [(seq, data) for seq, (data, _) in self.entries.items()]

    def _remove(self, seq: int) -> None:
        entry = self.entries.pop(seq, None)
        if entry is None:
            return
        data, key = entry
        self.size -= len(data)
        if key is not None and self.keys.get(key) == seq:
            del self.keys[key]

    def _bound(self) -> None:
        def over() -> bool:
            return len(self.entries) > self.limit_frames or self.size > self.limit_bytes

        if not over():
            return
        # `keys` indexes every coalescing entry (one per live handle or cell),
        # so shedding them oldest first never walks the whole outbox.
        while over() and self.keys:
            self._remove(min(self.keys.values()))
        while over() and len(self.entries) > 1:
            self._remove(next(iter(self.entries)))
            self.dropped += 1


class Inbound:
    """The newest daemon frame applied; anything at or below it is a replay."""

    def __init__(self) -> None:
        self.last = 0

    def accept(self, seq: int) -> bool:
        if seq <= self.last:
            return False
        self.last = seq
        return True


class JobBook:
    """Job groups this kernel still owns, read from the frames it sends.

    The same bookkeeping the daemon keeps: a started job's group is owned
    until a job frame proves it gone. A reattaching daemon learns the groups
    from the hello. The kernel stays alive past its grace while a job is live.
    """

    def __init__(self) -> None:
        self.started: dict[str, dict[str, object]] = {}
        self.external = 0

    def observe(self, frame: dict[str, object]) -> None:
        kind, id = frame.get("type"), frame.get("id")
        if kind == "job_start" and isinstance(id, str):
            pgid = frame.get("pgid")
            if isinstance(pgid, int) and not isinstance(pgid, bool) and pgid > 1:
                self.started[id] = frame
        elif kind == "job" and isinstance(id, str):
            cleanup = frame.get("cleanup")
            if isinstance(cleanup, dict) and cleanup.get("gone") is True:
                self.started.pop(id, None)
        elif kind == "jobs":
            live = frame.get("live")
            if isinstance(live, int) and not isinstance(live, bool) and live >= 0:
                self.external = live

    def live(self) -> int:
        return len(self.started) + self.external


class StdioLink:
    """Raw frames over the inherited stdin/stdout; the pipe closing ends us."""

    def __init__(self) -> None:
        self.control_in: BinaryIO = os.fdopen(os.dup(0), "rb", buffering=0)
        self.control_out: BinaryIO = os.fdopen(os.dup(1), "wb", buffering=0)
        self.lock = threading.Lock()
        self.jobs = JobBook()

    def send(self, frame: dict[str, object]) -> None:
        data = encode(frame)
        with self.lock:
            self.jobs.observe(frame)
            write_frame(self.control_out.write, data)

    def serve(self, dispatch: Callable[[object], None]) -> None:
        """Deliver frames until the pipe closes; raises when it does."""
        while True:
            dispatch(read_frame(self.control_in.read))

    def attached(self) -> bool:
        return True


class SocketLink:
    """The session layer over a unix socket in the kernel's run directory."""

    def __init__(
        self,
        run_dir: str,
        token: str,
        hello: Callable[[], dict[str, object]],
        *,
        bundle: str,
        grace: float,
    ) -> None:
        self.run_dir = run_dir
        self.token = token
        self.hello = hello
        self.bundle = bundle
        self.grace = grace
        self.lock = threading.RLock()
        self.outbox = Outbox()
        self.inbound = Inbound()
        self.jobs = JobBook()
        self.epoch = 0
        self.connection: socket.socket | None = None
        self.detached_at = time.monotonic()
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        # Bound relative to the run directory: sun_path holds ~104 bytes and a
        # temporary ALBEDO_HOME alone can use most of that.
        previous = os.getcwd()
        os.chdir(run_dir)
        try:
            if os.path.exists(SOCKET):
                os.unlink(SOCKET)
            self.listener.bind(SOCKET)
            os.chmod(SOCKET, 0o600)
        finally:
            os.chdir(previous)
        self.listener.listen(4)

    def send(self, frame: dict[str, object]) -> None:
        with self.lock:
            self.jobs.observe(frame)
            seq, data = self.outbox.add(frame)
            self._write(envelope(seq, self.inbound.last, data))

    def attached(self) -> bool:
        return self.connection is not None

    def idle_for(self) -> float:
        """Seconds with nothing attached; zero while attached."""
        if self.connection is not None:
            return 0.0
        return time.monotonic() - self.detached_at

    def serve(self, dispatch: Callable[[object], None]) -> None:
        """Accept attaches forever; each connection reads on its own thread."""
        while True:
            connection, _ = self.listener.accept()
            threading.Thread(
                target=self._session, args=(connection, dispatch), daemon=True
            ).start()

    def _write(self, data: bytes) -> None:
        connection = self.connection
        if connection is None:
            return
        try:
            write_frame(connection.send, data)
        except OSError:
            self._detach(connection)

    def _detach(self, connection: socket.socket) -> None:
        with self.lock:
            if self.connection is connection:
                self.connection = None
                self.detached_at = time.monotonic()
        try:
            connection.close()
        except OSError:
            pass

    def _attach(self, connection: socket.socket) -> bool:
        connection.settimeout(ATTACH_TIMEOUT)
        message = read_frame(connection.recv)
        attach = message.get("attach") if isinstance(message, dict) else None
        token = attach.get("token") if isinstance(attach, dict) else None
        if not isinstance(attach, dict) or not isinstance(token, str):
            write_frame(connection.send, encode({"refused": "expected attach"}))
            return False
        if not hmac.compare_digest(token.encode(), self.token.encode()):
            write_frame(connection.send, encode({"refused": "wrong token"}))
            return False
        connection.settimeout(None)
        grace = attach.get("grace")
        ack = attach.get("ack")
        with self.lock:
            if isinstance(grace, int | float) and not isinstance(grace, bool):
                self.grace = max(float(grace), 0.0)
            previous, self.connection = self.connection, connection
            self.epoch += 1
            if previous is not None:
                try:
                    previous.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
            if isinstance(ack, int) and not isinstance(ack, bool):
                self.outbox.ack(ack)
            hello = {
                **self.hello(),
                "protocol": PROTOCOL,
                "bundle": self.bundle,
                "epoch": self.epoch,
                "ack": self.inbound.last,
                "jobs": list(self.jobs.started.values()),
                "external": self.jobs.external,
                "dropped": self.outbox.dropped,
            }
            write_frame(connection.send, encode({"hello": hello}))
            for seq, data in self.outbox.pending():
                write_frame(connection.send, envelope(seq, self.inbound.last, data))
        return True

    def _session(
        self, connection: socket.socket, dispatch: Callable[[object], None]
    ) -> None:
        try:
            if not self._attach(connection):
                return
            while True:
                message = read_frame(connection.recv)
                if not isinstance(message, dict):
                    raise ValueError("expected an envelope")
                ack = message.get("ack")
                seq = message.get("seq")
                with self.lock:
                    if isinstance(ack, int) and not isinstance(ack, bool):
                        self.outbox.ack(ack)
                    fresh = isinstance(seq, int) and self.inbound.accept(seq)
                if fresh:
                    dispatch(message.get("frame"))
                if isinstance(seq, int):
                    with self.lock:
                        if self.connection is connection:
                            self._write(encode({"ack": self.inbound.last}))
        except (OSError, EOFError, ValueError):
            pass
        finally:
            self._detach(connection)
