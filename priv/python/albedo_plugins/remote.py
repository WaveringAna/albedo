"""Remote kernels over SSH: every harness tool, on another machine.

connect() stages albedo's python bundle on the target, boots the same kernel
over one long-lived ssh connection, and answers its host-route calls against
this session's daemon, so session tools (work, skills, cells) keep running
where the daemon runs while machine tools (run, files) run on the target.
Both kernels load the same content-hashed bundle, so a tool's remote shape
matches its local one and results cross as real objects.

Every call is one reference: the reply inlines the value when it can cross and
keeps the object live over there otherwise, so methods can be called on the
remote object either way. If the kernel cannot boot, the connection degrades
to command mode -- only rem.run() -- and says so at connect.
"""

from __future__ import annotations

import asyncio
import base64
import contextlib
import importlib
import io
import json
import os
import shlex
import struct
import tarfile
import tempfile
import uuid
from pathlib import Path
from typing import Any

from albedo_protocol import RemoteCall, RemoteMessage, parse_remote

from albedo_api import PythonApi, ReadyList, excerpt
import albedo_bundle
import albedo_shell

CONNECT_TIMEOUT = 60  # seconds before an unreachable target gives up
HANDSHAKE_TIMEOUT = 60  # seconds for the remote kernel to say ready
STAGE_TIMEOUT = 120  # seconds to move the bundle over one ssh stream
INVOKE_TIMEOUT = 3600  # anti-wedge bound; the cell deadline is the real limit
COMMAND_TIMEOUT = 120  # degraded-mode command default
MAX_FRAME = 8 * 1024 * 1024  # control-frame ceiling, as in the kernel
STDERR_TAIL = 65536  # bytes of ssh diagnostics kept for failures
IMAGE_READ = 5 * 1024 * 1024 + 1  # one past a cell's image bytes, as local reads

loop: asyncio.AbstractEventLoop
host_call: Any
HostErrorType: type[Exception]
capture_factory: Any
send_frame: Any
attach_image: Any
session_modules: list[str] = []
_fallback_live: set[str] = set()  # degraded-mode jobs still running over ssh


def _report_live() -> None:
    """Tell the local supervisor how many remote jobs are still live.

    Releasing the kernel would kill every ssh client and with them the remote
    kernels, so the idle sweep keeps a kernel alive while remote work runs.
    """
    try:
        live = len(_fallback_live) + sum(len(c._live) for c in connections)
        send_frame({"type": "jobs", "live": live})
    except Exception:
        pass  # no channel or shutdown; the supervisor keeps the last count


configured: dict[str, str | None] = {}
connections: list["RemoteConnection"] = []

_UNSET = object()  # a value result that has not settled yet


class RemoteError(RuntimeError):
    """A remote operation failed; the message names what happened."""


class RemoteBootError(RemoteError):
    """The remote kernel could not start; the connection degrades to commands."""


class RemoteLost(RemoteError):
    """The ssh channel is gone; every reference it held is invalid."""


class RemoteTimeout(RemoteError):
    """A remote call did not answer; an interrupt was sent."""


class RemoteCancelled(RemoteError):
    """The wait was cancelled; the remote effect may continue."""


class RemoteExecutionError(RemoteError):
    """A remote tool call raised; its traceback crossed the connection."""

    def __init__(self, ename: str, evalue: str, traceback: list[str]):
        lines = "\n".join(traceback[-4:])
        super().__init__(f"{ename}: {evalue}" + (f"\n{lines}" if lines else ""))
        self.ename = ename
        self.evalue = evalue
        self.traceback = tuple(traceback)


def parse_target(arg: str) -> dict[str, str | None]:
    """Split `user@host[:/path]`; a colon not followed by a path stays in the host."""
    head, separator, tail = arg.partition(":")
    remote_cwd = tail if separator and tail.startswith("/") else None
    return {"host": arg if remote_cwd is None else head, "remote_cwd": remote_cwd}


def _settings() -> dict[str, str]:
    """The `remote` section of extensions.json, falling back to `ssh`; errors raise."""
    home = os.environ.get("ALBEDO_HOME") or os.path.expanduser("~/.albedo")
    try:
        with open(os.path.join(home, "extensions.json"), "rb") as handle:
            sections = json.load(handle)
    except FileNotFoundError:
        return {}
    if not isinstance(sections, dict):
        raise RemoteError("extensions.json must hold an object")
    section = sections.get("remote", sections.get("ssh"))
    if section is None:
        return {}
    if not isinstance(section, dict):
        raise RemoteError("extensions.json remote section must be an object")
    keys = ("host", "remoteCwd", "python")
    for key in keys:
        if key in section and not isinstance(section[key], str):
            raise RemoteError(f"extensions.json remote.{key} must be a string")
    return {key: section[key] for key in keys if key in section}


def resolve(
    host: str | None = None, remote_cwd: str | None = None, python: str | None = None
) -> dict[str, str | None]:
    """The target a connection runs against, or a misuse error naming every source."""
    if host is None and configured:
        target = dict(configured)
    else:
        if host is None:
            host = os.environ.get("ALBEDO_SSH") or _settings().get("host")
        if host is None:
            raise RemoteError(
                "no remote target: pass host=, call remote.configure(), set $ALBEDO_SSH, "
                'or add a "remote" section to extensions.json'
            )
        target = parse_target(host)
        if target["remote_cwd"] is None:
            target["remote_cwd"] = _settings().get("remoteCwd")
    if remote_cwd is not None:
        target["remote_cwd"] = remote_cwd
    if python is None:
        python = _settings().get("python")
    target["python"] = python
    return target


def ssh_env() -> dict[str, str]:
    """The local environment for SSH client processes.

    If SSH_AUTH_SOCK was not inherited (or stripped by an outer layer),
    discover standard agent sockets if present so hardware keys, 1Password,
    and ssh-agent work out of the box.
    """
    env = dict(os.environ)
    if "SSH_AUTH_SOCK" not in env:
        for candidate in (
            os.path.expanduser("~/.ssh/agent.sock"),
            os.path.expanduser(
                "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
            ),
        ):
            if os.path.exists(candidate):
                env["SSH_AUTH_SOCK"] = candidate
                break
    return env


def in_login_shell(script: str) -> str:
    """Run a command under the remote user's login shell.

    Non-interactive SSH commands run under `$SHELL -c` without sourcing
    `/etc/profile` or user profiles, which leaves PATH minimal (missing
    Nix, Homebrew, or user tool paths) and environment variables unset.
    Running under a login shell ensures python3 and tooling are found.
    """
    return f'exec "${{SHELL:-/bin/sh}}" -l -c {shlex.quote(script)}'


def ssh_base() -> list[str]:
    """The ssh argv prefix: one multiplexed control connection per target.

    Control sockets live under /tmp when it fits, else the temp dir: unix
    socket paths are capped (~104 bytes on macOS) and %C hashes to 40 more,
    so neither ALBEDO_HOME nor macOS's deep $TMPDIR may be on the path.
    """
    control = os.path.join("/tmp", "albedo-ssh-cm")
    if len(control) + 42 > 104:
        control = os.path.join(tempfile.gettempdir(), "albedo-ssh-cm")
    os.makedirs(control, exist_ok=True)
    return [
        "ssh",
        "-o",
        "BatchMode=yes",
        "-o",
        "ConnectTimeout=10",
        "-o",
        "StrictHostKeyChecking=accept-new",
        "-o",
        "ControlMaster=auto",
        "-o",
        f"ControlPath={control}/%C",
        "-o",
        "ControlPersist=600",
    ]


async def ssh_run(
    target: str, script: str, *, timeout: float, stdin: bytes | None = None
) -> tuple[int | None, bytes, str]:
    """One command over the control connection; its exit code is data."""
    process = await asyncio.create_subprocess_exec(
        *ssh_base(),
        target,
        script,
        stdin=asyncio.subprocess.PIPE
        if stdin is not None
        else asyncio.subprocess.DEVNULL,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
        env=ssh_env(),
    )
    try:
        stdout, stderr = await asyncio.wait_for(process.communicate(stdin), timeout)
    except asyncio.TimeoutError:
        process.kill()
        raise RemoteTimeout(
            f"ssh command did not finish in {timeout:g}s: {script}"
        ) from None
    return process.returncode, stdout, stderr.decode(errors="replace")


_BUNDLE: dict[str, str] = {}


def bundle() -> dict[str, str]:
    """Content hash of the packaged python tree, so both sides run the same code."""
    if not _BUNDLE:
        root = albedo_bundle.ROOT
        digest = albedo_bundle.digest(root)
        _BUNDLE["id"] = digest
        _BUNDLE["root"] = str(root)
        _BUNDLE["remote"] = f"$HOME/.albedo-remote/{digest[:16]}"
    return _BUNDLE


async def stage(target: str) -> None:
    """Move the bundle over one ssh stream: candidate dir, then tar into it."""
    remote = bundle()["remote"]
    archive = io.BytesIO()
    with tarfile.open(fileobj=archive, mode="w") as tar:
        tar.add(bundle()["root"], arcname=".")
    script = f'mkdir -p "{remote}" && tar -C "{remote}" -xf -'
    code, _, stderr = await ssh_run(
        target, in_login_shell(script), timeout=STAGE_TIMEOUT, stdin=archive.getvalue()
    )
    if code != 0:
        raise RemoteBootError(f"staging failed ({code}): {stderr.strip()[:500]}")


def _load_class(marker: str) -> type:
    """The class a wire marker names; both bundles are identical, so it exists."""
    module, _, qualified = marker.rpartition(".")
    obj: Any = importlib.import_module(module)
    for part in qualified.split("."):
        obj = getattr(obj, part)
    return obj


def wire_decode(value: Any) -> Any:
    """Rebuild real objects from wire values, so remote results read like local ones."""
    if isinstance(value, dict):
        if set(value) == {"__bytes__"} and isinstance(value.get("__bytes__"), str):
            try:
                return base64.b64decode(value["__bytes__"], validate=True)
            except ValueError as error:
                raise RemoteError("invalid remote byte encoding") from error
        if set(value) == {"__class__", "fields"} and isinstance(
            value.get("__class__"), str
        ):
            try:
                return _load_class(value["__class__"])(
                    **{key: wire_decode(item) for key, item in value["fields"].items()}
                )
            except Exception:
                return {key: wire_decode(item) for key, item in value["fields"].items()}
        if set(value) == {"__record__", "fields"} and isinstance(
            value.get("__record__"), str
        ):
            fields = {key: wire_decode(item) for key, item in value["fields"].items()}
            try:
                return _load_class(value["__record__"])(fields)
            except Exception:
                return fields
        if set(value) == {"__list__", "items"} and isinstance(
            value.get("__list__"), str
        ):
            items = [wire_decode(item) for item in value["items"]]
            try:
                return _load_class(value["__list__"])(items)
            except Exception:
                return items
        return {key: wire_decode(item) for key, item in value.items()}
    if isinstance(value, list):
        return [wire_decode(item) for item in value]
    return value


def _revive(value: Any) -> Any:
    """Pickle hook target: a reference with a crossed value saves as its value."""
    return value


class RemoteRef:
    """One remote reference: pending, live, or settled into its value.

    A call returns this immediately -- the invoke is already in flight, no
    round trip blocks the call -- and the reference settles on first await.
    Methods called before the reply lands target the pending call, so
    `rem.run(program, ...)` behaves like local run: the handle exists now, `await`
    waits for the object, and mirrored job state answers tail() and poll()
    locally, with no round trip. A result whose value crossed reads and
    iterates like that value; its local methods run locally, and attributes
    that only exist remotely are remote calls.
    """

    def __init__(
        self,
        connection: "RemoteConnection",
        handle: str | None = None,
        value: Any = None,
        task: "asyncio.Task[Any] | None" = None,
        call_id: str | None = None,
        label: str = "",
    ) -> None:
        self._connection = connection
        self._handle = handle
        self._value = value
        self._task = task
        self._call_id = call_id
        self._label = label
        self._settled: Any = _UNSET
        self._withdrawn: bool = False

    # --- mirrored job state: sync, like the local handle ---

    def tail(self, n: int = 4000, *, lines: int | None = None) -> str:
        """The recent output of the remote job this reference holds: the last
        n characters, or its last `lines` lines."""
        state = self._mirror()
        return excerpt(
            str(state.get("tail", "")) if state else "", min(n, 16384), lines, end=True
        )

    def poll(self) -> int | None:
        """The remote job's exit status so far, from the mirrored stream."""
        state = self._mirror()
        return state.get("exit_code") if state else None

    @property
    def exit_code(self) -> int | None:
        """The remote job's exit status; the mirror keeps it current."""
        return self.poll()

    @property
    def returncode(self) -> int | None:
        """`exit_code` under subprocess's name; both spellings answer."""
        return self.poll()

    @property
    def timed_out(self) -> bool:
        """Whether the remote job lost its deadline."""
        state = self._mirror()
        return bool(state.get("timed_out")) if state else False

    @property
    def duration(self) -> float | None:
        """The seconds the remote job ran, known once it ended."""
        state = self._mirror()
        return state.get("duration") if state else None

    @property
    def waited(self) -> float:
        """The seconds the remote job sat paused for a heavy slot."""
        state = self._mirror()
        return state.get("waited", 0.0) if state else 0.0

    @property
    def id(self) -> str | None:
        """The remote job's id, for output.read on the remote side."""
        state = self._mirror()
        return state.get("job") if state else None

    def _mirror(self) -> dict[str, Any] | None:
        if self._handle is None:
            return None
        state = self._connection._mirrors.get(self._handle)
        # A finished job read through its mirror is consumed on the remote side
        # too, or its kernel would keep retrying a wake this read satisfies.
        if (
            state is not None
            and state.get("exit_code") is not None
            and not self._withdrawn
        ):
            self._withdrawn = True
            try:
                _ = loop.create_task(self._connection.mark_read(self._handle))
            except RuntimeError:
                pass  # the loop is closing; the notice dies with the kernel
        return state

    # --- the value surface: identical output to the local tool ---

    def __repr__(self) -> str:
        if self._value is not None:
            return repr(self._value)
        if self._handle is not None:
            return f"<remote reference {self._handle[:8]} on {self._connection.host}>"
        return f"<pending remote {self._label or 'call'}; await it>"

    __str__ = __repr__

    def _wanted(self) -> Any:
        if self._value is None and self._handle is None:
            raise TypeError(
                f"the remote {self._label or 'result'} is still pending; await it first"
            )
        if self._value is None:
            raise TypeError(
                "a live remote reference is not a value; await it or call its methods"
            )
        return self._value

    def __iter__(self):
        return iter(self._wanted())

    def __len__(self) -> int:
        return len(self._wanted())

    def __getitem__(self, key: Any) -> Any:
        return self._wanted()[key]

    def __contains__(self, key: Any) -> bool:
        return key in self._wanted()

    def __eq__(self, other: object) -> bool:
        return self._value == other if self._value is not None else self is other

    def __dir__(self) -> list[str]:
        return sorted(
            set(dir(type(self)))
            | (set(dir(self._value)) if self._value is not None else set())
        )

    def __reduce__(self):
        if self._value is None:
            raise TypeError(
                "a live remote reference cannot be saved; await or release it first"
            )
        return _revive, (self._value,)

    # --- the remote surface ---

    def __getattr__(self, name: str) -> Any:
        if name.startswith("_"):
            raise AttributeError(name)
        if self._value is not None and hasattr(self._value, name):
            return getattr(self._value, name)
        if self._connection.closed:
            raise RemoteLost(
                f"the connection for reference {self._label or '?'} is closed"
            )
        if self._handle is not None:
            return _RemoteCall(self._connection, self._handle, name)
        return _RemoteCall(
            self._connection,
            None,
            name,
            pending=self._call_id,
            label=f"{self._label}.{name}" if self._label else name,
        )

    def __await__(self):
        return self._settle().__await__()

    async def _settle(self) -> Any:
        """Resolve the in-flight call; awaiting a live object awaits the object."""
        if self._task is not None:
            task, self._task = self._task, None
            result = await task
            if result is not self:
                self._settled = result
                return result
        if self._settled is not _UNSET:
            return self._settled
        if self._handle is not None and self._value is None:
            await self._connection.invoke(handle=self._handle, wait=True)
        return self

    async def release(self) -> None:
        """Drop the live reference; the object itself is the remote plugin's to keep."""
        if self._task is not None:
            self._task.cancel()
            self._task = None
            return
        if self._handle is not None:
            self._connection._refs.pop(self._handle, None)
            await self._connection.invoke_release(self._handle)
        self._value = None


class _RemoteCall:
    """A method of the remote namespace, of one live reference, or of a pending call."""

    def __init__(
        self,
        connection: "RemoteConnection",
        handle: str | None,
        name: str,
        pending: str | None = None,
        label: str | None = None,
    ) -> None:
        self._connection = connection
        self._handle = handle
        self._name = name
        self._pending = pending
        self._label = label or name

    def __call__(self, *args: Any, **kwargs: Any) -> RemoteRef:
        """Start the call now; the reference it produces settles on first await."""
        return self._connection.start(self, args, kwargs)

    def __await__(self):
        """Awaiting an uncalled method runs it with no arguments, like a property."""
        return self().__await__()

    def __getattr__(self, name: str) -> Any:
        if name.startswith("_"):
            raise AttributeError(name)
        return _RemoteCall(
            self._connection,
            self._handle,
            f"{self._name}.{name}",
            pending=self._pending,
        )

    def __repr__(self) -> str:
        where = (
            self._handle[:8]
            if self._handle
            else (self._pending[:8] if self._pending else "namespace")
        )
        return f"<remote call {self._name} on {where}>"


SHELL_ONLY_DEGRADED = "rem.shell is only available in degraded SSH command mode; use rem.run(...).pipe(...) instead"


class RemoteConnection:
    """One ssh channel owning one remote kernel, or degraded to plain commands."""

    def __init__(self, target: dict[str, str | None]) -> None:
        self.target = target
        self._process: asyncio.subprocess.Process | None = None
        self._stdin = None
        self._stdout = None
        self._write_lock = asyncio.Lock()
        self._pending: dict[str, asyncio.Future[dict[str, Any]]] = {}
        self._refs: dict[str, RemoteRef] = {}
        self._mirrors: dict[str, dict[str, Any]] = {}
        self._handshake: asyncio.Future[dict[str, Any]] | None = None
        self._live: set[str] = set()
        self._stderr_tail = bytearray()
        self._reader: asyncio.Task[None] | None = None
        self._drain: asyncio.Task[None] | None = None
        self.closed = False
        self.degraded: RemoteBootError | None = None

    # --- boot ---

    async def boot(
        self, modules: list[str] | None = None, timeout: float = HANDSHAKE_TIMEOUT
    ) -> None:
        """Stage, spawn, and wait for ready; a failure raises RemoteBootError."""
        remote_root = bundle()["remote"]
        script_path = f"{remote_root}/albedo_kernel.py"
        code, _, _ = await ssh_run(
            self.host,
            in_login_shell(f'test -f "{script_path}"'),
            timeout=CONNECT_TIMEOUT,
        )
        if code != 0:
            await stage(self.host)
        python = self.target.get("python") or "python3"
        # The stamp reaches the remote kernel's plugins, so a finished remote
        # job's wake notice names the machine it ran on.
        inner = (
            f"ALBEDO_REMOTE_TARGET={shlex.quote(self.host)} exec "
            + f'{shlex.quote(python)} -u "{script_path}" '
            + shlex.quote(
                json.dumps(modules if modules is not None else default_modules())
            )
        )
        remote_cwd = self.target.get("remote_cwd")
        if remote_cwd:
            inner = f"cd {shlex.quote(remote_cwd)} && {inner}"
        script = in_login_shell(inner)
        self._handshake = loop.create_future()
        self._process = await asyncio.create_subprocess_exec(
            *ssh_base(),
            self.host,
            script,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            env=ssh_env(),
        )
        self._stdin, self._stdout = self._process.stdin, self._process.stdout
        self._drain = loop.create_task(self._drain_stderr())
        self._reader = loop.create_task(self._read_frames())
        try:
            frame = await asyncio.wait_for(asyncio.shield(self._handshake), timeout)
        except asyncio.TimeoutError:
            raise RemoteBootError(f"kernel did not say ready in {timeout:g}s") from None
        if frame.get("type") != "ready":
            raise RemoteBootError(str(frame.get("message", "invalid kernel handshake")))
        self._handshake = None

    async def _drain_stderr(self) -> None:
        """Keep a bounded tail of ssh diagnostics; a banner must not wedge the pipe."""
        assert self._process is not None and self._process.stderr is not None
        while True:
            chunk = await self._process.stderr.read(4096)
            if not chunk:
                return
            self._stderr_tail.extend(chunk)
            del self._stderr_tail[:-STDERR_TAIL]

    # --- frames ---

    async def _read_frames(self) -> None:
        try:
            while True:
                assert self._stdout is not None
                header = await self._stdout.readexactly(4)
                size = struct.unpack(">I", header)[0]
                if size > MAX_FRAME:
                    raise RemoteLost("remote control frame exceeds the ceiling")
                frame = parse_remote(json.loads(await self._stdout.readexactly(size)))
                self._dispatch(frame)
        except asyncio.CancelledError:
            raise
        except Exception:
            pass  # Every reader failure invalidates its outstanding work below.
        finally:
            self._lost()

    def _dispatch(self, frame: RemoteMessage) -> None:
        if frame["type"] == "invoked" or frame["type"] == "introspected":
            future = self._pending.get(frame["id"])
            if future is not None and not future.done():
                future.set_result(dict(frame))
        elif frame["type"] in ("ready", "startup_error"):
            if self._handshake is not None and not self._handshake.done():
                self._handshake.set_result(dict(frame))
        elif frame["type"] == "call":
            _ = loop.create_task(self._relay(frame))
        elif frame["type"] == "mirror":
            self._mirrors[frame["handle"]] = dict(frame)
        elif frame["type"] == "job_start":
            self._live.add(frame["id"])
            _report_live()
        elif frame["type"] == "job":
            self._live.discard(frame["id"])
            _report_live()
        # trace, done, cleanup describe remote cells; those are addressed
        # through references, not events on this side.

    async def _relay(self, frame: RemoteCall) -> None:
        """Answer one remote host-route call against this session's daemon."""
        try:
            value = await host_call(frame["method"], frame["args"])
            reply: dict[str, Any] = {"ok": True, "value": value}
        except HostErrorType as error:
            reply = {
                "ok": False,
                "code": getattr(error, "code", "host"),
                "message": str(getattr(error, "message", error)),
            }
        except Exception as error:  # the daemon's answer must always be a reply
            reply = {
                "ok": False,
                "code": "host",
                "message": f"{type(error).__name__}: {error}",
            }
        await self._send({"type": "reply", "id": frame["id"], "value": reply})

    async def _send(self, frame: dict[str, Any]) -> None:
        if self.closed or self._stdin is None:
            raise RemoteLost(f"the connection to {self.host} is closed")
        data = json.dumps(frame).encode()
        if len(data) > MAX_FRAME:
            raise RemoteError(
                f"remote call payload is {len(data)} bytes, over the {MAX_FRAME}-byte ceiling"
            )
        async with self._write_lock:
            self._stdin.write(struct.pack(">I", len(data)) + data)
            await self._stdin.drain()

    def _lost(self) -> None:
        """The channel died: every pending call and reference learns it once."""
        if self._handshake is not None and not self._handshake.done():
            self._handshake.set_exception(
                RemoteBootError(
                    "the ssh channel closed at startup: "
                    + bytes(self._stderr_tail).decode(errors="replace").strip()[:500]
                )
            )
        for future in self._pending.values():
            if not future.done():
                future.set_exception(
                    RemoteLost(f"the connection to {self.host} was lost")
                )
        self.closed = True

    # --- calls ---

    def start(
        self, call: "_RemoteCall", args: tuple[Any, ...], kwargs: dict[str, Any]
    ) -> RemoteRef:
        """Fire one call and return its reference immediately; it settles on await."""
        call_id = uuid.uuid4().hex
        reference = RemoteRef(self, call_id=call_id, label=call._label)
        reference._task = loop.create_task(
            self.invoke(
                name=call._name,
                handle=call._handle,
                pending=call._pending,
                args=args,
                kwargs=kwargs,
                call_id=call_id,
                placeholder=reference,
            )
        )
        return reference

    async def invoke(
        self,
        name: str = "",
        *,
        handle: str | None = None,
        pending: str | None = None,
        args: tuple[Any, ...] = (),
        kwargs: dict[str, Any] | None = None,
        wait: bool = False,
        timeout: float = INVOKE_TIMEOUT,
        call_id: str | None = None,
        placeholder: RemoteRef | None = None,
    ) -> Any:
        """One remote call; the answer is a value, or a reference to the live object.

        A `pending` target names an earlier call whose result this one uses, so
        method calls raced ahead of their own reply still resolve in order. The
        `placeholder` is the reference the caller already holds; a handle reply
        adopts into it rather than minting a second object.
        """
        if self.degraded is not None:
            raise RemoteError(
                f"degraded to ssh command mode ({self.degraded}); only rem.run() is available"
            )
        call_id = call_id or uuid.uuid4().hex
        frame: dict[str, Any] = {
            "type": "invoke",
            "id": call_id,
            "args": [_encode_arg(item) for item in args],
            "kwargs": {key: _encode_arg(item) for key, item in (kwargs or {}).items()},
        }
        if name:
            frame["name"] = name
        if handle is not None:
            frame["target"] = {"handle": handle}
        elif pending is not None:
            frame["target"] = {"pending": pending}
        if wait:
            frame["await"] = True
        future: asyncio.Future[dict[str, Any]] = loop.create_future()
        self._pending[call_id] = future
        await self._send(frame)
        try:
            reply = await asyncio.wait_for(future, timeout)
        except asyncio.TimeoutError:
            await self._interrupt(call_id)
            raise RemoteTimeout(
                f"remote call {name or ('await ' + str(handle))!r} did not answer "
                f"in {timeout:g}s; an interrupt was sent"
            ) from None
        except asyncio.CancelledError:
            await self._interrupt(call_id)
            raise
        finally:
            self._pending.pop(call_id, None)
        return self._result(reply, placeholder)

    def _result(
        self, reply: dict[str, Any], placeholder: RemoteRef | None = None
    ) -> Any:
        """One reply into a value or a reference, or the error it names."""
        if reply.get("ok") is not True:
            error = reply.get("error") or {}
            if reply.get("cancelled"):
                raise RemoteCancelled(str(error.get("evalue", "cancelled remotely")))
            raise RemoteExecutionError(
                str(error.get("ename", "RemoteError")),
                str(error.get("evalue", "")),
                [str(line) for line in error.get("traceback", [])],
            )
        if "handle" in reply:
            handle = str(reply["handle"])
            state = reply.get("state")
            if state is not None:
                self._mirrors[handle] = state
            value = wire_decode(reply["value"]) if "value" in reply else None
            reference = (
                placeholder if placeholder is not None else self._refs.get(handle)
            )
            if reference is None:
                reference = RemoteRef(self, handle, value)
            else:
                reference._handle = handle
                reference._value = value
            self._refs[handle] = reference
            return reference
        return wire_decode(reply.get("value"))

    async def _interrupt(self, call_id: str) -> None:
        """Best-effort: tell the remote kernel this wait is over."""
        try:
            await self._send({"type": "interrupt", "id": call_id})
        except Exception:
            pass  # the channel is already gone; the caller has that error

    async def invoke_release(self, handle: str) -> None:
        """Drop a live reference; no reply waits for it."""
        self._refs.pop(handle, None)
        await self._send({"type": "release", "handle": handle})

    async def mark_read(self, handle: str) -> None:
        """Tell the remote object its result was read, retiring its wake.

        A local mirror read never crosses the channel on its own, so this one
        round trip (a poll, which the job counts as a read) is the only way a
        finished remote job learns the model already has its output.
        """
        try:
            await self.invoke(handle=handle, name="poll", timeout=30)
        except Exception:
            pass  # the channel is gone; the notice fails its own way

    async def tools(self) -> dict[str, Any]:
        """What the remote namespace holds, and the live references it kept."""
        if self.degraded is not None:
            return {"names": ["run"], "handles": [], "degraded": str(self.degraded)}
        call_id = uuid.uuid4().hex
        future: asyncio.Future[dict[str, Any]] = loop.create_future()
        self._pending[call_id] = future
        await self._send({"type": "introspect", "id": call_id})
        try:
            frame = await asyncio.wait_for(future, CONNECT_TIMEOUT)
        finally:
            self._pending.pop(call_id, None)
        return {"names": frame.get("names", []), "handles": frame.get("handles", [])}

    # --- ssh conveniences, both modes ---

    async def read(self, path: str, *, timeout: float = COMMAND_TIMEOUT) -> str:
        """A remote file's text over the control connection, not the kernel."""
        remote = _remote_path(self, path)
        data = await self._ssh(f"cat {shlex.quote(remote)}", timeout)
        return data.decode(errors="replace")

    async def show_image(
        self,
        source: bytes | str | os.PathLike[str],
        *,
        timeout: float = COMMAND_TIMEOUT,
    ) -> str:
        """Return a remote image to yourself with this cell's result, under the
        same limits as local show_image. The remote kernel has no cell of its
        own to carry one, so the bytes come here over the control connection."""
        if attach_image is None:
            raise RemoteError("this kernel cannot attach images")
        if isinstance(source, (bytes, bytearray, memoryview)):
            data = bytes(source)
        elif isinstance(source, (str, os.PathLike)):
            remote = shlex.quote(_remote_path(self, os.fspath(source)))
            data = await self._ssh(f"head -c {IMAGE_READ} {remote}", timeout)
        else:
            raise TypeError(
                f"show_image takes image bytes or a remote path, not {type(source).__name__}"
            )
        return "attached " + attach_image(data)

    async def _ssh(self, script: str, timeout: float) -> bytes:
        code, stdout, stderr = await ssh_run(
            self.host, in_login_shell(script), timeout=timeout
        )
        if code != 0:
            raise RemoteError(f"SSH failed ({code}): {stderr.strip()}")
        return stdout

    async def write(
        self, path: str, content: str, *, timeout: float = COMMAND_TIMEOUT
    ) -> None:
        """Replace a remote file; bytes travel base64, never as shell text."""
        remote = _remote_path(self, path)
        encoded = base64.b64encode(content.encode()).decode()
        await self._ssh(
            f"printf %s {shlex.quote(encoded)} | base64 -d > {shlex.quote(remote)}",
            timeout,
        )

    # --- degraded mode ---

    @property
    def run(self) -> Any:
        """rem.run: the remote binding in kernel mode, command mode otherwise."""
        if self.degraded is None:
            if self.closed:
                raise RemoteLost(f"the connection to {self.host} is closed")
            return _RemoteCall(self, None, "run")

        def run(
            program: object,
            *args: object,
            cwd: str | None = None,
            env: dict[str, object] | None = None,
            stdin: str | bytes | None = None,
            timeout: float = 300,
        ) -> FallbackJob:
            if not 0 < timeout <= 3600:
                raise ValueError("0 < timeout <= 3600 required")
            if not (stdin is None or isinstance(stdin, (str, bytes))):
                raise TypeError("in ssh command mode stdin is text or bytes")
            argv = albedo_shell.words((program, *args))
            script = albedo_shell.shell_script(argv)
            if script is not None:
                raise albedo_shell.refusal(
                    f"`{os.path.basename(argv[0])} -c`", script=script
                )
            return FallbackJob(self, argv, timeout, cwd=cwd, env=env, stdin=stdin)

        return run

    @property
    def shell(self) -> Any:
        """A shell escape hatch only when the remote kernel could not boot."""
        if self.degraded is None:
            raise AttributeError(SHELL_ONLY_DEGRADED)
        if self.closed:
            raise RemoteLost(f"the connection to {self.host} is closed")

        def shell(
            script: str,
            *,
            cwd: str | None = None,
            env: dict[str, object] | None = None,
            stdin: str | bytes | None = None,
            timeout: float = 300,
        ) -> FallbackJob:
            if not isinstance(script, str) or not 0 < timeout <= 3600:
                raise ValueError(
                    "shell script must be text; 0 < timeout <= 3600 required"
                )
            if not (stdin is None or isinstance(stdin, (str, bytes))):
                raise TypeError("in ssh command mode stdin is text or bytes")
            return FallbackJob(
                self,
                ["bash", "-c", script],
                timeout,
                cwd=cwd,
                env=env,
                stdin=stdin,
                shell=script,
            )

        return shell

    # --- surface ---

    def __getattr__(self, name: str) -> Any:
        if name.startswith("_"):
            raise AttributeError(name)
        if name == "shell" and self.degraded is None:
            raise AttributeError(SHELL_ONLY_DEGRADED)
        if self.degraded is not None:
            raise AttributeError(
                f"{name!r} is unavailable: this connection is degraded to ssh command "
                f"mode ({self.degraded}); only rem.run(), rem.shell(), rem.read, and rem.write work"
            )
        if self.closed:
            raise RemoteLost(f"the connection to {self.host} is closed")
        return _RemoteCall(self, None, name)

    def __repr__(self) -> str:
        state = (
            "degraded"
            if self.degraded is not None
            else ("closed" if self.closed else "kernel")
        )
        return f"<remote {self.host} ({state})>"

    async def close(self) -> None:
        """End the kernel and its channel: shutdown frame, then the signal ladder."""
        if self.closed and self._process is None:
            return
        if self._process is not None and self._process.returncode is None:
            try:
                await self._send({"type": "shutdown"})
            except Exception:
                pass
            try:
                await asyncio.wait_for(self._process.wait(), 1.0)
            except asyncio.TimeoutError:
                self._process.terminate()
                try:
                    await asyncio.wait_for(self._process.wait(), 1.0)
                except asyncio.TimeoutError:
                    self._process.kill()
        self.closed = True
        self._live.clear()
        _report_live()
        for future in self._pending.values():
            if not future.done():
                future.set_exception(
                    RemoteLost(f"the connection to {self.host} closed")
                )
        self._pending.clear()
        for task in (self._reader, self._drain):
            if task is not None:
                task.cancel()
        if self in connections:
            connections.remove(self)

    async def __aenter__(self) -> "RemoteConnection":
        return self

    async def __aexit__(self, *_: Any) -> None:
        await self.close()

    @property
    def host(self) -> str:
        return str(self.target["host"])


def _encode_arg(value: Any) -> Any:
    """References pass as references; everything else must already be wire data."""
    if isinstance(value, RemoteRef):
        if value._connection.closed:
            raise RemoteLost("cannot pass a reference from a closed connection")
        if value._handle is not None:
            return {"__ref__": value._handle}
        if value._task is not None:
            return {"pending": value._call_id}
        if value._settled is not _UNSET:
            return _encode_arg(value._settled)
        raise RemoteError("cannot pass an unusable remote reference")
    if isinstance(value, (str, int, float, bool)) or value is None:
        return value
    if isinstance(value, (bytes, bytearray)):
        return {"__bytes__": base64.b64encode(bytes(value)).decode("ascii")}
    if isinstance(value, list):
        return [_encode_arg(item) for item in value]
    if isinstance(value, dict) and type(value) is dict:
        return {key: _encode_arg(item) for key, item in value.items()}
    try:
        json.dumps(value)
        return value
    except (TypeError, ValueError) as error:
        raise RemoteError(
            f"cannot pass {type(value).__name__} to a remote call: only wire data "
            "and remote references cross"
        ) from error


def _remote_path(connection: RemoteConnection, path: str) -> str:
    """The remote spelling of a workspace path; anything else passes through."""
    remote_cwd = connection.target.get("remote_cwd")
    if remote_cwd and path.startswith(str(Path.cwd())):
        return str(Path(remote_cwd) / Path(path).relative_to(Path.cwd()))
    return path


class FallbackJob:
    """One command over the control connection when no kernel could boot.

    The same shape as a run job: await it, tail() it, stop() it. Killing the
    ssh client cannot stop the remote side, so a deadline reports timed_out
    and says the remote effect is unknown rather than ended.
    """

    def __init__(
        self,
        connection: RemoteConnection,
        argv: list[str],
        timeout: float,
        *,
        cwd: str | None = None,
        env: dict[str, object] | None = None,
        stdin: str | bytes | None = None,
        shell: str | None = None,
    ) -> None:
        self.id = uuid.uuid4().hex
        self.argv = argv
        self.command = shell if shell is not None else shlex.join(argv)
        self.timed_out = False
        self.exit_code: int | None = None
        self.started: float = loop.time()
        self.duration: float | None = None
        self.capture = capture_factory(self.id)
        self._awaited = False
        self._read = False
        self._connection = connection
        _fallback_live.add(self.id)
        _report_live()
        # the remote login shell reads this line; everything in it is quoted
        steps = [
            f"cd {shlex.quote(str(where))}"
            for where in (connection.target.get("remote_cwd"), cwd)
            if where
        ]
        assignments = [f"{name}={value}" for name, value in (env or {}).items()]
        steps.append(
            shlex.join(["exec", *(["env", *assignments] if assignments else []), *argv])
        )
        data = stdin.encode() if isinstance(stdin, str) else stdin
        self._task = loop.create_task(
            self._run(
                connection.host, in_login_shell(" && ".join(steps)), timeout, data
            )
        )

    async def _run(
        self, host: str, script: str, timeout: float, stdin: bytes | None
    ) -> "FallbackJob":
        process = await asyncio.create_subprocess_exec(
            *ssh_base(),
            host,
            script,
            stdin=asyncio.subprocess.DEVNULL
            if stdin is None
            else asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
            env=ssh_env(),
        )
        self._process = process
        if stdin is not None and process.stdin is not None:
            process.stdin.write(stdin)
            process.stdin.close()
        copying = loop.create_task(self._copy(process.stdout))
        try:
            self.exit_code = await asyncio.wait_for(process.wait(), timeout)
            with contextlib.suppress(asyncio.TimeoutError):
                await asyncio.wait_for(copying, timeout=1.0)
        except asyncio.TimeoutError:
            self.timed_out = True
            process.kill()
            self.exit_code = await process.wait()
            self.capture.write(
                f"\n[deadline exceeded after {timeout:g}s; the ssh client was killed; "
                f"the remote command may still be running]"
            )
        finally:
            copying.cancel()
            self.duration = loop.time() - self.started
            _fallback_live.discard(self.id)
            _report_live()
            if host_call is not None and not self._awaited:
                _ = loop.create_task(self._announce())
        return self

    async def _announce(self) -> None:
        """Wake the session for this command, retrying while it runs."""
        while not self._read and not self._awaited:
            try:
                await host_call("jobs.completed", self._notice())
                return
            except HostErrorType as error:
                if getattr(error, "code", "") != "busy":
                    self.capture.write(f"\n[completion notice not delivered: {error}\n")
                    return
            except Exception:
                return  # the kernel is going away; the result stays on the handle
            await asyncio.sleep(2.0)

    def _notice(self) -> dict[str, object]:
        """The wake turn's display text, model text, and the facts behind both."""
        command = self.command[:200] + ("..." if len(self.command) > 200 else "")
        outcome = (
            "timed out"
            if self.timed_out
            else f"exit_code={self.exit_code}"
            if self.exit_code is not None
            else "exit status unknown"
        )
        seconds = (
            f"{self.duration:.1f}s" if self.duration is not None else "unknown duration"
        )
        display = (
            f"job finished on {self._connection.host} ({outcome}, {seconds}): {command}"
        )
        text = (
            "<system-note>a background command finished with its result unread on"
            f" {self._connection.host} (ssh command mode): {outcome}, {seconds},"
            f" command: {command}."
            f" its handle is jobs[{self.id!r}] in python; jobs[{self.id!r}].tail() or"
            f" output.read({self.id!r}) reads its output."
            " no user sent this message; use the result if the session's work needs"
            " it, otherwise acknowledge briefly and stay idle.</system-note>"
        )
        return {
            "display": display,
            "text": text,
            "id": self.id,
            "exit_code": self.exit_code,
            "timed_out": self.timed_out,
            "duration": self.duration,
            "host": self._connection.host,
        }

    async def _copy(self, stream: Any) -> None:
        while chunk := await stream.read(8192):
            self.capture.write(chunk.decode("utf-8", errors="replace"))

    def __await__(self):
        self._awaited = True
        return asyncio.shield(self._task).__await__()

    def poll(self) -> int | None:
        if self.exit_code is not None:
            self._read = True
        return self.exit_code

    @property
    def returncode(self) -> int | None:
        """`exit_code` under subprocess's name; both spellings answer."""
        return self.poll()

    def tail(self, n: int = 4000, *, lines: int | None = None) -> str:
        if self.exit_code is not None:
            self._read = True
        return excerpt(
            bytes(self.capture.tail_data).decode("utf-8", errors="replace"),
            min(n, 65536),
            lines,
            end=True,
        )

    def head(self, n: int = 4000, *, lines: int | None = None) -> str:
        if self.exit_code is not None:
            self._read = True
        return excerpt(self.capture.read(0, 65536), min(n, 65536), lines, end=False)

    async def stop(self) -> None:
        """End the ssh client; the remote command's fate is reported, not assumed."""
        self._read = True  # an explicit stop is its own report; no wake is owed
        process = getattr(self, "_process", None)
        if process is not None and process.returncode is None:
            process.terminate()
            try:
                await asyncio.wait_for(process.wait(), 2.0)
            except asyncio.TimeoutError:
                process.kill()
            self.capture.write(
                "\n[stopped locally; the remote command may still be running]"
            )

    def __repr__(self) -> str:
        return (
            f"FallbackJob(id={self.id!r}, exit_code={self.exit_code!r}, "
            f"timed_out={self.timed_out!r}, duration={self.duration!r}, "
            f"bytes={self.capture.seen})"
        )


def default_modules() -> list[str]:
    """The session's tool selection, minus this plugin: what boots remotely."""
    return [name for name in session_modules if name != "remote"]


class Remote:
    """The namespace bound into the kernel as `remote`."""

    @staticmethod
    def configure(host: str, remote_cwd: str | None = None) -> dict[str, str | None]:
        """Resolve `user@host[:/path]` once and keep it for later connections."""
        target = parse_target(host)
        if remote_cwd is not None:
            target["remote_cwd"] = remote_cwd
        configured.clear()
        configured.update(target)
        return dict(target)

    @staticmethod
    async def connect(
        host: str | None = None,
        *,
        remote_cwd: str | None = None,
        python: str | None = None,
        modules: list[str] | None = None,
        timeout: float = HANDSHAKE_TIMEOUT,
    ) -> RemoteConnection:
        """Boot this session's kernel on a remote host, or degrade to commands.

        The target resolves per call: an explicit `host=`, then the value
        `remote.configure` stored, then `$ALBEDO_SSH`, then the `remote`
        section of extensions.json. If the host is reachable but the kernel
        cannot boot, the connection still returns, prints a warning, and
        answers `rem.run()`, degraded-only `rem.shell()`, `rem.read`, `rem.write`,
        and `rem.show_image`.
        """
        target = resolve(host, remote_cwd, python)
        code, _, stderr = await ssh_run(
            str(target["host"]), "true", timeout=CONNECT_TIMEOUT
        )
        if code != 0:
            raise RemoteError(
                f"ssh target {target['host']!r} is unreachable: {stderr.strip()[:300]}"
            )
        if target["remote_cwd"] is None:
            code, stdout, _ = await ssh_run(
                str(target["host"]), "pwd", timeout=CONNECT_TIMEOUT
            )
            if code == 0:
                target["remote_cwd"] = stdout.decode(errors="replace").strip() or None
        connection = RemoteConnection(target)
        try:
            await connection.boot(modules, timeout)
        except RemoteBootError as error:
            connection.degraded = error
            if connection._process is not None:
                if connection._reader is not None:
                    connection._reader.cancel()
                    with contextlib.suppress(asyncio.CancelledError):
                        await connection._reader
                if connection._drain is not None:
                    connection._drain.cancel()
                if connection._process.returncode is None:
                    connection._process.terminate()
            connection._process = None
            connection._stdin = connection._stdout = None
            connection.closed = False
            print(
                f"[remote] kernel boot failed on {target['host']}: {error}; "
                "degraded to ssh command mode: rem.run(program, *args) still works; "
                "for pipes or shell syntax use rem.shell('git log --oneline | rg fix') "
                "(bash on the host; no remote process supervision)"
            )
        connections.append(connection)
        return connection

    @staticmethod
    def connections() -> ReadyList:
        """Every open connection, kernel or degraded."""
        return ReadyList(connections)

    @staticmethod
    async def close_all() -> None:
        """Kernel shutdown: end every connection inside the cleanup deadline."""
        for connection in list(connections):
            await connection.close()


remote = Remote()


def setup(api: PythonApi) -> dict[str, object]:
    global loop, host_call, HostErrorType, capture_factory, send_frame
    global attach_image, session_modules
    loop, host_call = api.loop, api.host
    HostErrorType, capture_factory = api.HostError, api.capture
    send_frame = api.send
    attach_image = api.attach_image
    session_modules = list(api.modules)
    api.on_shutdown(Remote.close_all)
    return {"remote": remote, "RemoteError": RemoteError}
