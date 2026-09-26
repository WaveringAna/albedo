from __future__ import annotations

import ast
import albedo_api
import albedo_proc
from collections.abc import Awaitable, Callable, Iterable, Sequence
from typing import Any, cast
from types import CodeType, FrameType
import albedo_trace
import asyncio
import base64
import codecs
import collections
import contextvars
import dataclasses
import inspect
import io
import json
import os
import reprlib
import select
import signal
import pickle
import struct
import sys
import tempfile
import threading
import traceback
import uuid

MAX_FRAME = 8 * 1024 * 1024
CLEANUP_DEADLINE = 1.5  # seconds: plugins must finish cleanup inside the supervisor's patience
PREVIEW = 64 * 1024
RETAIN = 1024 * 1024
LIMITS = {"cell": 16, "job": 64, "native": 1}  # retained captures per kind
MAX_IMAGES = 4  # images one cell may return to the model
# Decoded bytes across one cell's images. Base64 grows this by 4/3, and the done
# frame must stay under the 8 MiB guard with its output preview alongside.
MAX_IMAGE_BYTES = 5 * 1024 * 1024
CELL: contextvars.ContextVar[Capture | None] = contextvars.ContextVar("cell", default=None)
CONTROL_IN = os.fdopen(os.dup(0), "rb", buffering=0)
CONTROL_OUT = os.fdopen(os.dup(1), "wb", buffering=0)
SEND_LOCK = threading.Lock()
LOOP = asyncio.new_event_loop()
asyncio.set_event_loop(LOOP)
QUEUE: asyncio.Queue[albedo_api.Execute | albedo_api.State] = asyncio.Queue()
PENDING: dict[str, asyncio.Future[albedo_api.HostReply]] = {}
JOB_SLOTS: dict[str, tuple[asyncio.Future[None], Callable[[], None]]] = {}
HOST_SLOTS = asyncio.Semaphore(32)
OWNER_CALLS = asyncio.Semaphore(32)  # concurrent tool calls from the connection owner
OWNER_TASKS: dict[str, asyncio.Task[object]] = {}  # interruptable by invoke id
LIVE: collections.OrderedDict[str, object] = collections.OrderedDict()  # remote references
LIVE_LIMIT = 64  # live references retained for the owner; LRU beyond that
PENDING_OBJECTS: collections.OrderedDict[str, asyncio.Future[object]] = collections.OrderedDict()
MIRROR_INTERVAL = 0.15  # seconds between output-tail mirror frames while data flows
MIRROR_TAIL = 16 * 1024  # bytes of tail a mirror frame carries
active: asyncio.Task[object] | None = None
active_capture: Capture | None = None
interrupt_capture: Capture | None = None
ARCHIVES: collections.OrderedDict[str, Capture] = collections.OrderedDict()
NAMESPACE: dict[str, object] = {"__name__": "__main__"}
CLEANUP: list[albedo_api.Cleanup] = []
HANDLES: list[type[object]] = [asyncio.Task]
REPR = reprlib.Repr()
REPR.maxstring = REPR.maxother = 4000
REPR.maxdict = REPR.maxlist = REPR.maxtuple = 50


def show(value: object) -> str:
    return REPR.repr(value).encode("utf-8", errors="replace")[:PREVIEW].decode("utf-8", errors="ignore")


def send(value: dict[str, object]) -> None:
    data = json.dumps(value, ensure_ascii=True).encode()
    with SEND_LOCK:
        remaining = memoryview(struct.pack(">I", len(data)) + data)
        while remaining:
            remaining = remaining[CONTROL_OUT.write(remaining):]


def read_exact(size: int) -> bytes:
    data = bytearray()
    while len(data) < size:
        chunk = CONTROL_IN.read(size - len(data))
        if not chunk:
            raise EOFError()
        data.extend(chunk)
    return bytes(data)


async def cleanup() -> None:
    """Run plugin cleanup; a callback may return an awaitable to clean up asynchronously."""
    for close in reversed(CLEANUP):
        try:
            result = close()
            if inspect.isawaitable(result):
                await result
        except BaseException as error:
            try:
                send({"type": "cleanup", "module": getattr(close, "__module__", "plugin"),
                      "failures": [f"{type(error).__name__}: {error}"]})
            except (OSError, ValueError):
                pass  # a disconnected owner must not prevent other cleanup callbacks


def die() -> None:
    """Leave the session: clean up while the loop can still run it, then kill our group.

    Called from the reader thread and from the main thread, never from a loop
    callback, so cleanup may await without deadlocking the interpreter.
    """
    try:
        if LOOP.is_running():
            asyncio.run_coroutine_threadsafe(cleanup(), LOOP).result(CLEANUP_DEADLINE)
        else:
            LOOP.run_until_complete(asyncio.wait_for(cleanup(), CLEANUP_DEADLINE))
    except BaseException as error:
        try:
            send({"type": "cleanup", "module": "kernel",
                  "failures": [f"cleanup incomplete: {type(error).__name__}: {error}"]})
        except (OSError, ValueError):
            pass  # the owner disconnected; it independently tracks our groups
    # The interpreter and its subprocesses own a separate process group.
    os.killpg(os.getpid(), signal.SIGKILL)


def reader():
    global interrupt_capture
    try:
        while True:
            size = struct.unpack(">I", read_exact(4))[0]
            if size > MAX_FRAME:
                raise ValueError("control frame too large")
            message = cast(albedo_api.Incoming, json.loads(read_exact(size)))
            if message["type"] == "shutdown":
                die()
            elif message["type"] == "interrupt":
                capture = active_capture
                if capture is not None and capture.id == message["id"]:
                    interrupt_capture = capture
                    capture.interruption = message.get("reason", "cancelled")
                    os.kill(os.getpid(), signal.SIGINT)
                else:
                    task = OWNER_TASKS.get(message["id"])
                    if task is not None:
                        LOOP.call_soon_threadsafe(task.cancel)
            else:
                _ = LOOP.call_soon_threadsafe(deliver, message)
    except (EOFError, OSError, ValueError, KeyError):
        die()


def deliver(message: dict[str, object]) -> None:
    kind = message["type"]
    if kind == "job_slot":
        entry = JOB_SLOTS.get(cast(str, message["id"]))
        if entry is not None and not entry[0].done():
            slot, on_queued = entry
            if message.get("ok") is True:
                slot.set_result(None)
            elif message.get("queued") is True:
                on_queued()
            else:
                slot.set_exception(RuntimeError(str(message.get("message", "job admission failed"))))
    elif kind == "reply":
        future = PENDING.pop(message["id"], None)
        if future is not None and not future.done():
            future.set_result(message["value"])
    elif kind == "invoke":
        _ = LOOP.create_task(serve_invoke(cast(dict[str, object], message)))
    elif kind == "introspect":
        send({"type": "introspected", "id": message["id"],
              "names": sorted(name for name in NAMESPACE
                              if name.isidentifier() and not name.startswith("_")),
              "handles": [{"id": key, "repr": show(value)} for key, value in LIVE.items()]})
    elif kind == "release":
        LIVE.pop(message.get("handle", ""), None)
    else:
        QUEUE.put_nowait(cast(albedo_api.Execute | albedo_api.State, message))


class WorkError(Exception):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code: str = code


async def job_slot(id: str, on_queued: Callable[[], None]) -> None:
    """Wait for a heavy-job slot; `on_queued` runs at once if none is free, so
    the caller can pause the job. Independent of host RPC slots."""
    future: asyncio.Future[None] = LOOP.create_future()
    JOB_SLOTS[id] = (future, on_queued)
    send({"type": "job_acquire", "id": id})
    try:
        await future
    except BaseException:
        send({"type": "job_cancel", "id": id})
        raise
    finally:
        JOB_SLOTS.pop(id, None)


async def host(method: str, args: dict[str, object]) -> object:
    async with HOST_SLOTS:
        return await _host(method, args)


async def _host(method: str, args: dict[str, object]) -> object:
    key = uuid.uuid4().hex
    future: asyncio.Future[albedo_api.HostReply] = LOOP.create_future()
    PENDING[key] = future
    send({"type": "call", "id": key, "method": method, "args": args})
    try:
        answer = await future
    finally:
        _ = PENDING.pop(key, None)
    if answer["ok"] is True:
        return answer["value"]
    raise WorkError(answer["code"], answer["message"])




class Capture:
    def __init__(self, id: str, kind: str = "cell") -> None:
        self.id: str = id
        self.kind: str = kind
        self.data: bytearray = bytearray()
        self.tail_data: bytearray = bytearray()
        self.seen: int = 0
        self.trace: albedo_trace.Trace = albedo_trace.Trace()
        self.interruption: str = "cancelled"
        self.images: list[bytes] = []

    def write(self, text: str) -> None:
        data = text.encode("utf-8", errors="replace")
        remaining = max(0, RETAIN - len(self.data))
        self.data.extend(data[:remaining])
        self.seen += len(data)
        self.tail_data.extend(data[-PREVIEW:])
        del self.tail_data[:-PREVIEW]

    def read(self, offset: int = 0, limit: int = 4000) -> str:
        return bytes(self.data[max(0, offset):max(0, offset) + min(max(0, limit), PREVIEW)]).decode("utf-8", errors="ignore")

    def preview(self, status: str = "ok") -> str:
        if status == "ok":
            return self.read(0, PREVIEW)
        return bytes(self.tail_data).decode("utf-8", errors="ignore")

    def attach(self, data: bytes) -> str:
        """Queue one image for this cell's result; raises ValueError past the limits."""
        mime = image_type(data)
        if mime is None:
            raise ValueError("image must be PNG, JPEG, or WebP bytes")
        if len(self.images) >= MAX_IMAGES:
            raise ValueError(f"a cell returns at most {MAX_IMAGES} images")
        if sum(map(len, self.images)) + len(data) > MAX_IMAGE_BYTES:
            raise ValueError(f"a cell's images total at most {MAX_IMAGE_BYTES} bytes; "
                             f"this {len(data)}-byte image does not fit")
        self.images.append(data)
        return f"{mime}, {len(data)} bytes"

    def encoded_images(self) -> list[str]:
        return [base64.b64encode(image).decode("ascii") for image in self.images]


def image_type(data: bytes) -> str | None:
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png"
    if data.startswith(b"\xff\xd8"):
        return "image/jpeg"
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "image/webp"
    return None


def attach_image(data: bytes) -> str:
    """Attach image bytes to the running cell; plugins reach this as api.attach_image."""
    capture = CELL.get()
    # A task spawned by a finished cell still carries that cell's context; only
    # the capture currently receiving output belongs to a result not yet sent.
    if capture is None or capture.kind != "cell" or capture is not sink:
        raise RuntimeError("images attach to a running cell; background work has no result to carry them")
    return capture.attach(bytes(data))


def show_image(source: bytes | bytearray | memoryview | str | os.PathLike[str]) -> albedo_api.Text:
    """Return an image to yourself with this cell's result. `source` is PNG,
    JPEG, or WebP bytes, or a path to such a file. At most 4 images and 5 MiB
    per cell; the image arrives after the cell finishes, not mid-cell."""
    if isinstance(source, (bytes, bytearray, memoryview)):
        data = bytes(source)
    elif isinstance(source, (str, os.PathLike)):
        with open(source, "rb") as file:
            data = file.read(MAX_IMAGE_BYTES + 1)
    else:
        raise TypeError(f"show_image takes image bytes or a path, not {type(source).__name__}")
    return albedo_api.Text("attached " + attach_image(data))


NATIVE = Capture("native", "native")
NATIVE_LOCK = threading.RLock()
NATIVE_FD = -1
DECODER = codecs.getincrementaldecoder("utf-8")("replace")
sink: Capture | None = None  # the cell whose code is running; native bytes join it


def retained(id: str) -> Capture:
    capture = ARCHIVES.get(id)
    if capture is None:
        raise LookupError(
            f"no retained output for {id!r}: only the 16 most recent cells and 64 most recent jobs "
            f"keep output, so it may have rolled out; output.list() names what is kept, and a "
            f"background job keeps its own output on its handle: jobs[{id!r}].tail()")
    return capture


READ_WATCHERS: dict[str, Callable[[], None]] = {}


def watch_output(id: str, notify: Callable[[], None]) -> None:
    """Register one read callback for a retained output channel (a background job)."""
    READ_WATCHERS[id] = notify


class Output:
    def read(self, id: str, *, offset: int = 0, limit: int = 4000) -> str:
        """Read retained output by cell or job id: up to 1 MiB each, for the 16
        most recent cells and 64 most recent jobs."""
        capture = retained(id)
        notify = READ_WATCHERS.pop(id, None)  # one read satisfies the watcher
        if notify is not None:
            try:
                notify()
            except Exception:
                pass  # a plugin's bookkeeping must not fail the read
        return albedo_api.Text(capture.read(offset, limit))

    def list(self):
        """Every retained channel: cells, background jobs, and 'native'.

        'native' holds bytes written to fd 1/2 while no cell was running; bytes a
        cell's subprocesses write land in that cell's own output instead.
        """
        return albedo_api.ReadyList(
            {"id": c.id, "kind": c.kind, "bytes": c.seen, "retained": len(c.data)} for c in ARCHIVES.values())


class Stream(io.TextIOBase):
    def writable(self) -> bool:
        return True

    def write(self, text: str) -> int:
        with NATIVE_LOCK:  # bytes already in the pipe were written first and stay first
            _ = drain()
            (CELL.get() or NATIVE).write(text)
        return len(text)

    def flush(self) -> None:
        pass

    def fileno(self) -> int:
        return 1


def drain() -> bool:
    """Fold whatever fd 1/2 already holds into the running cell; False once the pipe closes.

    Subprocesses and C extensions cannot be attributed through contextvars, so
    they are credited to the cell that is running, the way a terminal does.
    Both the pump thread and Python-level writes drain, so the two surfaces
    interleave in the order the bytes were produced.
    """
    with NATIVE_LOCK:
        while True:
            try:
                data = os.read(NATIVE_FD, 65536)
            except BlockingIOError:
                return True
            except OSError:
                return False
            if not data:
                return False
            text = DECODER.decode(data)
            if text:
                (sink or NATIVE).write(text)


def native_output(fd: int) -> None:
    """Wake on output produced while no cell is writing."""
    try:
        while select.select([fd], [], [])[0] and drain():
            pass
    except OSError:
        return




def interrupt(_signal: int, _frame: FrameType | None) -> None:
    if active_capture is not None and active_capture is interrupt_capture:
        raise KeyboardInterrupt()


def compile_cell(source: str, filename: str) -> tuple[CodeType, CodeType | None]:
    """Every part compiles before anything runs; a trailing expression yields the cell value."""
    tree = ast.parse(source, filename=filename)
    last = tree.body[-1] if tree.body else None
    trailing = None
    if isinstance(last, ast.Expr):
        _ = tree.body.pop()
        trailing = ast.Expression(last.value)
    prefix = cast(CodeType, compile(tree, filename, "exec", ast.PyCF_ALLOW_TOP_LEVEL_AWAIT))
    suffix = cast(CodeType, compile(trailing, filename, "eval", ast.PyCF_ALLOW_TOP_LEVEL_AWAIT)) if trailing else None
    return prefix, suffix


async def evaluate(source: str, cell_id: str, durable: bool = False) -> object:
    started = False
    try:
        prefix, suffix = compile_cell(source, "<albedo:" + cell_id + ">")
        if durable:
            _ = await host("cells.started", {"id": cell_id})
        started = True
        value = cast(object, eval(prefix, NAMESPACE))
        if inspect.isawaitable(value):
            _ = await cast(Awaitable[object], value)
        if suffix is not None:
            value = cast(object, eval(suffix, NAMESPACE))
            if inspect.isawaitable(value) and not isinstance(value, tuple(HANDLES)):
                value = await cast(Awaitable[object], value)
            NAMESPACE["_"] = value
            return value
    except BaseException as error:
        if not hasattr(error, "_albedo_cell_id"):
            setattr(error, "_albedo_cell_id", cell_id)
            setattr(error, "_albedo_started", started)
        raise


class Cells:
    """Immutable saved source. Repairs never automatically repeat side effects."""
    last_id: str | None = None

    async def read(self, id: str, *, start_line: object = 1, end_line: object = None, limit: object = 8000) -> str:
        """Return source lines, capped at `limit` bytes. Narrow with start_line/end_line."""
        if not isinstance(start_line, int) or start_line < 1 or (end_line is not None and (not isinstance(end_line, int) or end_line < start_line)):
            raise ValueError("expected positive inclusive line numbers")
        if not isinstance(limit, int) or limit < 1:
            raise ValueError("limit must be a positive byte count")
        cell = cast(albedo_api.SavedCell, await host("cells.read", {"id": id}))
        lines = cell["source"].splitlines(keepends=True)
        data = "".join(lines[start_line - 1:end_line]).encode("utf-8", errors="replace")
        if len(data) <= limit:
            return data.decode("utf-8", errors="ignore")
        return data[:limit].decode("utf-8", errors="ignore") + (
            f"\n[{limit} of {len(data)} bytes; the cell has {len(lines)} lines; "
            f"narrow with start_line/end_line or raise limit]")

    async def info(self, id: str) -> albedo_api.Record:
        """Status (ok, error, interrupted, started, saved, lost, unavailable),
        parentage and whether the cell started, without its source."""
        cell = cast(albedo_api.SavedCell, await host("cells.read", {"id": id}))
        return albedo_api.Record((key, value) for key, value in cell.items() if key != "source")

    async def list(self, limit: int = 20) -> albedo_api.ReadyList:
        """This session's cells, newest first: id, status, parent, and first line.
        Unlike output.list(), it reaches cells whose output has rolled out."""
        cells = cast(list[dict[str, object]], await host("cells.list", {"limit": limit}))
        return albedo_api.ReadyList(albedo_api.Record(cell) for cell in cells)

    async def trace(self, id: str) -> dict[str, object]:
        """What the cell read, ran and changed: activities plus diffs of files it wrote.

        Diffs can be large; inspect the fields rather than printing the whole trace.
        """
        return cast(dict[str, object], await host("cells.trace", {"id": id}))

    async def run(self, id: str, replacements: Iterable[Sequence[object]] = (), *, allow_partial: bool = False, check: bool = False) -> object:
        """Repair exact unique text and execute a new saved copy.

        check=True compiles the rewrite and returns its compile error, or None when
        it compiles; nothing is saved and nothing runs.
        A cell that started needs allow_partial=True after inspecting its effects.
        Syntax/compile failures are safe to repair without that override.
        """
        pairs = [tuple(pair) for pair in replacements]
        for pair in pairs:
            if len(pair) != 2 or not all(isinstance(s, str) for s in pair):
                raise ValueError("replacements must be (old, new) string pairs")
        if check:
            source = cast(str, await host("cells.draft", {"id": id, "replacements": pairs}))
            try:
                _ = compile_cell(source, "<albedo:" + id + ":check>")
            except (SyntaxError, ValueError) as error:
                return "".join(traceback.format_exception_only(type(error), error)).strip()
            return None
        cell = cast(albedo_api.SavedCell, await host("cells.prepare", {"id": id, "replacements": pairs, "allow_partial": allow_partial}))
        self.last_id = cell["id"]
        capture = Capture(cell["id"])
        remember(capture)
        outer = CELL.get()
        token = CELL.set(capture)
        outer_sink = swap_sink(capture)
        value: object = None
        error: BaseException | None = None
        status = "ok"
        try:
            value = await evaluate(cell["source"], cell["id"], True)
            text = "" if value is None else show(value)
        except BaseException as failure:
            error = failure
            status = "interrupted" if isinstance(failure, (KeyboardInterrupt, asyncio.CancelledError)) else "error"
            capture.write(traceback.format_exc())
            text = ""
        finally:
            _ = drain()
            _ = swap_sink(outer_sink)
            CELL.reset(token)
            if outer is not None:
                outer.write("[cell " + cell["id"] + "]\n" + capture.read(0, PREVIEW))
                for image in capture.images:
                    try:
                        _ = outer.attach(image)
                    except ValueError as dropped:
                        outer.write(f"[image from cell {cell['id']} dropped: {dropped}]\n")
        _ = await host("cells.finish", {"id": cell["id"], "outcome": {
            "id": cell["id"], "status": status, "output": capture.preview(status),
            "value": text, "truncated": capture.seen > PREVIEW,
            "images": capture.encoded_images()}})
        if error is not None:
            raise error
        return value


# Saved state is the session's own namespace, written by this kernel into the
# daemon's home. Loading it runs pickle: the same trust domain as the transcript.
STATE_MAX = 256 * 1024 * 1024
STATE_MAX_VALUE = 16 * 1024 * 1024
INJECTED: set[str] = {"__name__", "__builtins__", "_"}


def engine() -> tuple[object, str]:
    """dill when it is installed; pickle keeps plain data working without it."""
    try:
        import dill
        dill.settings["recurse"] = True
        return dill, "dill"
    except ImportError:
        return pickle, "pickle"


def save_state(path: str) -> dict[str, object]:
    """Serialise each name on its own, so one unpicklable object costs only itself."""
    serialiser, kind = cast("Any", engine())
    payload: dict[str, bytes] = {}
    skipped: list[dict[str, str]] = []
    total = 0
    for name in list(NAMESPACE.keys()):
        if name.startswith("_") or name in INJECTED:
            continue
        value = NAMESPACE.get(name, INJECTED)  # a background thread may delete it mid-walk
        if value is INJECTED:
            continue
        try:
            blob = cast(bytes, serialiser.dumps(value))
        except BaseException as error:
            skipped.append({"name": name, "reason": f"{type(error).__name__}: {error}"[:200]})
            continue
        if len(blob) > STATE_MAX_VALUE:
            skipped.append({"name": name, "reason": f"{len(blob)} bytes exceeds the per-variable cap"})
        elif total + len(blob) > STATE_MAX:
            skipped.append({"name": name, "reason": "saved state is full"})
        else:
            payload[name] = blob
            total += len(blob)
    try:
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        handle, temporary = tempfile.mkstemp(dir=os.path.dirname(path) or ".", prefix=os.path.basename(path) + ".")
        try:
            with os.fdopen(handle, "wb") as file:
                pickle.dump({"cwd": os.getcwd(), "names": payload}, file)
            os.replace(temporary, path)  # a crash leaves the previous state intact
        except BaseException:
            os.unlink(temporary)
            raise
    except OSError as error:
        return {"error": f"could not write saved state: {error}"}
    return {"saved": sorted(payload), "skipped": skipped, "bytes": total, "engine": kind}


def load_state(path: str) -> dict[str, object]:
    """Revive every name that survives; a name that fails is reported, not fatal."""
    try:
        with open(path, "rb") as file:
            saved = cast(dict[str, object], pickle.load(file))
    except FileNotFoundError:
        return {"restored": [], "failed": [], "error": "no saved state"}
    except BaseException as error:
        return {"restored": [], "failed": [], "error": f"unreadable saved state: {type(error).__name__}"}
    serialiser, kind = cast("Any", engine())
    restored: list[str] = []
    failed: list[dict[str, str]] = []
    for name, blob in cast(dict[str, bytes], saved.get("names", {})).items():
        try:
            NAMESPACE[name] = cast(object, serialiser.loads(blob))
        except BaseException as error:
            failed.append({"name": name, "reason": f"{type(error).__name__}: {error}"[:200]})
        else:
            restored.append(name)
    directory = saved.get("cwd")
    if isinstance(directory, str) and os.path.isdir(directory):
        os.chdir(directory)
    return {"restored": sorted(restored), "failed": failed, "engine": kind}


def swap_sink(capture: Capture | None) -> Capture | None:
    global sink
    previous, sink = sink, capture
    return previous


def background_capture(id: str) -> Capture:
    """A retained channel for a plugin's background work, addressable through `output`."""
    capture = Capture(id, "job")
    remember(capture)
    return capture


def remember(capture: Capture) -> None:
    """Keep the newest captures of each kind, so a flood of jobs never evicts cell output."""
    ARCHIVES[capture.id] = capture
    ARCHIVES.move_to_end(capture.id)
    counts = collections.Counter(held.kind for held in ARCHIVES.values())
    for key, held in list(ARCHIVES.items()):
        if counts[held.kind] > LIMITS[held.kind]:
            del ARCHIVES[key]
            counts[held.kind] -= 1


def state_reply(message: albedo_api.State) -> dict[str, object]:
    state = save_state(message["path"]) if message["type"] == "snapshot" else load_state(message["path"])
    return {"type": "done", "id": message["id"], "status": "error" if "error" in state else "ok",
            "output": "", "value": "", "truncated": False, "state": state}


MAX_RESULT_BYTES = 4 * 1024 * 1024  # one invoke reply ceiling, below the 8 MiB frame guard


class Unencodable(Exception):
    """The value cannot cross the connection; it stays a live remote reference."""


def _wire_encode(value: object, depth: int = 0) -> object:
    """One value as connection-crossable JSON; Unencodable means a live reference.

    Dataclasses and list subclasses carry their class so the owner rebuilds the
    real object and remote results read exactly like local ones.
    """
    if depth > 32:
        raise Unencodable
    if value is None or isinstance(value, (bool, int, float, str)):
        return value
    if isinstance(value, (bytes, bytearray, memoryview)):
        return {"__bytes__": base64.b64encode(bytes(value)).decode("ascii")}
    if isinstance(value, dict) and type(value) is dict:
        return {str(key): _wire_encode(item, depth + 1) for key, item in value.items()}
    if isinstance(value, albedo_api.Record):
        cls = type(value)
        return {"__record__": cls.__module__ + "." + cls.__qualname__,
                "fields": {str(key): _wire_encode(item, depth + 1) for key, item in value.items()}}
    if isinstance(value, (list, tuple)):
        try:
            if type(value) is not list:
                cls = type(value)
                return {"__list__": cls.__module__ + "." + cls.__qualname__,
                        "items": [_wire_encode(item, depth + 1) for item in value]}
        except Unencodable:
            raise
        except (TypeError, ValueError):
            raise Unencodable from None
        return [_wire_encode(item, depth + 1) for item in value]
    if dataclasses.is_dataclass(value) and not isinstance(value, type):
        cls = type(value)
        try:
            return {"__class__": cls.__module__ + "." + cls.__qualname__,
                    "fields": {field.name: _wire_encode(getattr(value, field.name), depth + 1)
                               for field in dataclasses.fields(value)}}
        except (TypeError, ValueError, AttributeError):
            raise Unencodable from None
    raise Unencodable


def retain(value: object) -> str:
    """Keep one live object addressable by the owner; identity-stable, oldest rolls out."""
    for key, held in LIVE.items():
        if held is value:
            LIVE.move_to_end(key)
            return key
    key = uuid.uuid4().hex
    LIVE[key] = value
    LIVE.move_to_end(key)
    while len(LIVE) > LIVE_LIMIT:
        LIVE.popitem(last=False)
    capture = getattr(value, "capture", None)
    if isinstance(capture, Capture):
        _ = LOOP.create_task(_mirror(key, value, capture))
    return key


def _mirror_state(obj: object) -> dict[str, object]:
    """One snapshot of a captured object: what the owner's tail() and poll() answer from."""
    capture = cast(Capture, getattr(obj, "capture"))
    return {"job": getattr(obj, "id", None), "seen": capture.seen,
            "tail": bytes(capture.tail_data[-MIRROR_TAIL:]).decode("utf-8", errors="replace"),
            "exit_code": getattr(obj, "exit_code", None),
            "timed_out": getattr(obj, "timed_out", False),
            "duration": getattr(obj, "duration", None)}


async def _mirror(key: str, obj: object, capture: Capture) -> None:
    """Stream one live reference's output tail, so the owner reads it without a round trip.

    Frames are coalesced to the mirror interval; the final frame carries the
    completion state, and the pump ends once the object has settled and quieted.
    """
    seen, quiet = -1, 0
    while LIVE.get(key) is obj:
        await asyncio.sleep(MIRROR_INTERVAL)
        changed = capture.seen != seen
        if changed:
            seen, quiet = capture.seen, 0
        else:
            quiet += 1
        finished = getattr(obj, "exit_code", None)
        if changed or (finished is not None and quiet <= 1):
            send({"type": "mirror", "handle": key, **_mirror_state(obj)})
        if finished is not None and quiet >= 3:
            return


def _invoke_reply(call_id: str, result: object,
                  state: dict[str, object] | None = None) -> dict[str, object]:
    """One reference per result: inline the value when it can cross, retain it live.

    Typed composites (dataclasses, list subclasses) get both, so the owner can
    read them as values and still call methods on the live remote object. Plain
    data crosses raw: its methods are pure and its state already crossed, so a
    remote call would be the same computation plus a network fee, and retaining
    it would evict live references worth keeping.
    """
    try:
        wire = _wire_encode(result)
        encoded = json.dumps(wire, ensure_ascii=True)
    except (Unencodable, TypeError, ValueError, RecursionError):
        reply: dict[str, object] = {"type": "invoked", "id": call_id, "ok": True,
                                    "handle": retain(result)}
        if state is not None:
            reply["state"] = state
        return reply
    if len(encoded) > MAX_RESULT_BYTES:
        return {"type": "invoked", "id": call_id, "ok": False,
                "error": {"ename": "RemoteValueError",
                          "evalue": f"result is {len(encoded)} bytes, over the "
                                    f"{MAX_RESULT_BYTES}-byte ceiling",
                          "traceback": []}}
    typed = isinstance(result, list) and type(result) is not list \
        or dataclasses.is_dataclass(result) and not isinstance(result, type)
    if typed:
        return {"type": "invoked", "id": call_id, "ok": True,
                "handle": retain(result), "value": wire}
    if state is not None:
        return {"type": "invoked", "id": call_id, "ok": True,
                "handle": retain(result), "state": state}
    return {"type": "invoked", "id": call_id, "ok": True, "value": wire}


def _owner_args(value: object) -> object:
    """Resolve `{"__ref__": id}` markers in owner arguments back to live objects."""
    if isinstance(value, dict):
        if set(value) == {"__ref__"} and isinstance(value.get("__ref__"), str):
            obj = LIVE.get(value["__ref__"])
            if obj is None:
                raise LookupError(f"live reference {value['__ref__']!r} is gone")
            return obj
        return {key: _owner_args(item) for key, item in value.items()}
    if isinstance(value, list):
        return [_owner_args(item) for item in value]
    return value


def _resolve(name: str) -> object:
    """The callable a namespace-path invoke addresses; handles resolve before this."""
    parts = name.split(".") if name else []
    if not all(part.isidentifier() and not part.startswith("_") for part in parts):
        raise ValueError(f"unaddressable owner invoke: {name!r}")
    obj = NAMESPACE.get(parts[0]) if parts else None
    if obj is None:
        raise LookupError("no remote binding " + repr(parts[0] if parts else name)
                          + "; rem.tools() lists what exists")
    for part in parts[1:]:
        obj = getattr(obj, part)
    return obj


async def _target_object(target: object) -> object | None:
    """The object a target names: a live reference, a pending call's result, or nothing.

    A `{"pending": id}` target waits for the call that produced the object, so
    method calls raced ahead of their own reply still resolve in order.
    """
    if not isinstance(target, dict):
        return None
    key = target.get("handle")
    if isinstance(key, str):
        obj = LIVE.get(key)
        if obj is None:
            raise LookupError(f"live reference {key!r} is gone")
        return obj
    pending = target.get("pending")
    if isinstance(pending, str):
        future = PENDING_OBJECTS.get(pending)
        if future is None:
            raise LookupError(f"pending call {pending!r} is gone")
        ok, value = await cast(Awaitable[tuple[bool, object]], future)
        if not ok:
            raise cast(BaseException, value)
        return value
    return None


async def serve_invoke(message: dict[str, object]) -> None:
    """One owner tool call: resolve, call, await by the cell rule, answer one reference.

    The reply inlines the value when it can cross and otherwise retains the
    object as a live reference; `value` and `handle` are one concept. Awaitables
    run to completion unless their class is a registered handle, the same rule
    the local evaluator applies, so a tool's remote shape matches its local one.
    An awaited object's reply carries its final state, so the owner's poll() is
    never racy, and every call's result object is retained briefly as a pending
    target for method calls that raced ahead of the reply.
    """
    call_id = cast(str, message["id"])
    OWNER_TASKS[call_id] = cast(asyncio.Task[object], asyncio.current_task())
    future: asyncio.Future[tuple[bool, object]] = LOOP.create_future()
    PENDING_OBJECTS[call_id] = future
    PENDING_OBJECTS.move_to_end(call_id)
    while len(PENDING_OBJECTS) > LIVE_LIMIT:
        PENDING_OBJECTS.popitem(last=False)
    reply: dict[str, object]
    result: object = None
    state: dict[str, object] | None = None
    failure: BaseException | None = None
    try:
        async with OWNER_CALLS:
            base = await _target_object(message.get("target"))
            if message.get("await") is True:
                if base is None:
                    raise ValueError("await needs a live or pending reference target")
                result = await cast(Awaitable[object], base)
                state = _mirror_state(result) if getattr(result, "capture", None) else None
            else:
                name = cast(str, message.get("name", ""))
                if base is None:
                    call = _resolve(name)
                else:
                    parts = name.split(".") if name else []
                    if not all(part.isidentifier() and not part.startswith("_") for part in parts):
                        raise ValueError(f"unaddressable owner invoke: {name!r}")
                    call = base
                    for part in parts:
                        call = getattr(call, part)
                args = [_owner_args(item) for item in message.get("args", ())]
                kwargs = {key: _owner_args(item)
                          for key, item in cast(dict[str, object], message.get("kwargs", {})).items()}
                result = call(*args, **kwargs)
                if inspect.isawaitable(result) and not isinstance(result, tuple(HANDLES)):
                    result = await cast(Awaitable[object], result)
    except asyncio.CancelledError as error:
        failure = error
        # The owner cancelled its wait; the remote effect may continue, and the
        # live reference (a running job, for instance) stays addressable.
        reply = {"type": "invoked", "id": call_id, "ok": False, "cancelled": True,
                 "error": {"ename": "CancelledError",
                           "evalue": "the owner cancelled this wait; the remote effect "
                                     "may continue and its reference stays addressable",
                           "traceback": []}}
    except BaseException as error:
        failure = error
        reply = {"type": "invoked", "id": call_id, "ok": False,
                 "error": {"ename": type(error).__name__, "evalue": str(error)[:8192],
                           "traceback": traceback.format_exc().splitlines()[-8:]}}
    else:
        reply = _invoke_reply(call_id, result, state)
    finally:
        OWNER_TASKS.pop(call_id, None)
        if not future.done():
            future.set_result((failure is None, failure if failure is not None else result))
    send(reply)


async def serve():
    global active, active_capture
    while True:
        message = await QUEUE.get()
        if message["type"] != "execute":
            send(state_reply(message))
            continue
        capture = Capture(message["id"])
        remember(capture)
        token = CELL.set(capture)
        _ = swap_sink(capture)
        status, value = "ok", ""
        task = active = LOOP.create_task(evaluate(message["code"], capture.id, message.get("durable", False)))
        try:
            active_capture = capture
            result = await task
            if result is not None:
                value = show(result)
        except (KeyboardInterrupt, asyncio.CancelledError):
            status = "interrupted"
            if capture.interruption == "deadline":
                capture.write("\n[cell deadline exceeded; execution interrupted]\n")
            if not task.done():
                _ = task.cancel()
        except BaseException as error:
            status = "error"
            failed_id = cast(str, getattr(error, "_albedo_cell_id", capture.id))
            capture.write(traceback.format_exc())
            if message.get("durable", False):
                capture.write(f"\n[cell {failed_id} retained; inspect with await cells.read({failed_id!r}); repair with await cells.run({failed_id!r}, replacements=[(old, new)])]\n")
        finally:
            _ = drain()  # a subprocess that already wrote belongs to this cell, not the next
            _ = swap_sink(None)
            active = None
            active_capture = None
            CELL.reset(token)
        send({"type": "trace", "id": capture.id, "trace": capture.trace.finish()})
        send({"type": "done", "id": capture.id, "status": status,
              "output": capture.preview(status), "value": value,
              "truncated": capture.seen > PREVIEW, "images": capture.encoded_images()})


def main():
    global NATIVE_FD
    if os.getpgrp() != os.getpid():
        os.setsid()
    _ = os.dup2(os.open(os.devnull, os.O_RDONLY), 0)
    read_fd, write_fd = os.pipe()
    _ = os.dup2(write_fd, 1)
    _ = os.dup2(write_fd, 2)
    os.close(write_fd)
    os.set_blocking(read_fd, False)
    NATIVE_FD = read_fd
    remember(NATIVE)
    sys.stdin = open(os.devnull)
    sys.stdout = sys.stderr = Stream()
    threading.Thread(target=native_output, args=(read_fd,), daemon=True).start()
    threading.Thread(target=reader, daemon=True).start()
    _ = signal.signal(signal.SIGINT, interrupt)
    albedo_trace.install(CELL.get)
    modules = cast(list[str], json.loads(sys.argv[1]))
    api = albedo_api.PythonApi(version=2, loop=LOOP, host=host, HostError=WorkError,
        forget_output=lambda id: ARCHIVES.pop(id, None) and None,
        capture=background_capture, preview=PREVIEW, send=send, on_shutdown=CLEANUP.append,
        background_handle=HANDLES.append, modules=modules, watch_output=watch_output,
        attach_image=attach_image,
        job_slot=job_slot if os.environ.get("ALBEDO_JOB_ADMISSION") == "1"
                 and not os.environ.get("ALBEDO_REMOTE_TARGET") else None)
    NAMESPACE.update(cells=Cells(), output=Output(), show_image=show_image)
    try:
        LOOP.run_until_complete(albedo_api.load_plugins(modules, api, NAMESPACE))
    except Exception as error:
        send({"type": "startup_error", "message": str(error)})
        die()
        return
    # Match an interactive Python session only after loading trusted plugins.
    sys.path[0] = ""
    # Plugin bindings and session objects are rebuilt on every start, never saved.
    INJECTED.update(NAMESPACE)
    # Declare our own process group; a group we do not lead is never the supervisor's target.
    pgid = os.getpgid(0)
    send({"type": "ready", "pid": os.getpid(), "pgid": pgid if pgid == os.getpid() else None,
          "leader": albedo_proc.leader_token(os.getpid())})
    task = LOOP.create_task(serve())
    while not task.done():
        try:
            LOOP.run_until_complete(task)
        except KeyboardInterrupt:
            if active is not None:
                _ = active.cancel()
    die()


if __name__ == "__main__":
    main()
