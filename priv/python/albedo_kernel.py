from __future__ import annotations

import ast
import albedo_api
import albedo_proc
from collections.abc import Awaitable, Callable, Iterable, Sequence
from typing import Any, cast
from types import CodeType, FrameType
import albedo_trace
import importlib
import asyncio
import codecs
import collections
import contextvars
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
CELL: contextvars.ContextVar[Capture | None] = contextvars.ContextVar("cell", default=None)
CONTROL_IN = os.fdopen(os.dup(0), "rb", buffering=0)
CONTROL_OUT = os.fdopen(os.dup(1), "wb", buffering=0)
SEND_LOCK = threading.Lock()
LOOP = asyncio.new_event_loop()
asyncio.set_event_loop(LOOP)
QUEUE: asyncio.Queue[albedo_api.Execute | albedo_api.State] = asyncio.Queue()
PENDING: dict[str, asyncio.Future[albedo_api.HostReply]] = {}
HOST_SLOTS = asyncio.Semaphore(32)
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
                _ = LOOP.call_soon_threadsafe(deliver, message)
    except (EOFError, OSError, ValueError, KeyError):
        die()


def deliver(message: albedo_api.Reply | albedo_api.Execute | albedo_api.State) -> None:
    if message["type"] == "reply":
        future = PENDING.pop(message["id"], None)
        if future is not None and not future.done():
            future.set_result(message["value"])
    else:
        QUEUE.put_nowait(message)


class WorkError(Exception):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code: str = code


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


NATIVE = Capture("native", "native")
NATIVE_LOCK = threading.RLock()
NATIVE_FD = -1
DECODER = codecs.getincrementaldecoder("utf-8")("replace")
sink: Capture | None = None  # the cell whose code is running; native bytes join it


def retained(id: str) -> Capture:
    capture = ARCHIVES.get(id)
    if capture is None:
        raise LookupError(
            f"no retained output for {id!r}; output.list() names what is kept, and a background "
            f"job keeps its own output on its handle: jobs[{id!r}].tail()")
    return capture


class Output:
    def read(self, id: str, *, offset: int = 0, limit: int = 4000) -> str:
        """Read retained output by cell or job id. At most 1 MiB each, 16 recent cells."""
        return retained(id).read(offset, limit)

    def list(self):
        """Every retained channel: cells, background jobs, and 'native'.

        'native' holds bytes written to fd 1/2 while no cell was running; bytes a
        cell's subprocesses write land in that cell's own output instead.
        """
        return [{"id": c.id, "kind": c.kind, "bytes": c.seen, "retained": len(c.data)} for c in ARCHIVES.values()]


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

    async def info(self, id: str) -> dict[str, object]:
        """Status, parentage and whether the cell started, without its source."""
        cell = cast(albedo_api.SavedCell, await host("cells.read", {"id": id}))
        return {key: value for key, value in cell.items() if key != "source"}

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
        _ = await host("cells.finish", {"id": cell["id"], "outcome": {
            "id": cell["id"], "status": status, "output": capture.preview(status),
            "value": text, "truncated": capture.seen > PREVIEW}})
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
              "truncated": capture.seen > PREVIEW})


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
    api = albedo_api.PythonApi(version=1, loop=LOOP, host=host, HostError=WorkError,
        capture=background_capture, preview=PREVIEW, send=send, on_shutdown=CLEANUP.append,
        background_handle=HANDLES.append)
    for name in cast(list[str], json.loads(sys.argv[1])):
        if not name.isidentifier():
            raise ValueError("invalid Python plugin module")
        plugin = cast(albedo_api.PythonPlugin, cast(object, importlib.import_module("albedo_plugins." + name)))
        exports = plugin.setup(api)
        if NAMESPACE.keys() & exports.keys():
            raise ValueError("duplicate Python plugin binding")
        NAMESPACE.update(exports)
    # Match an interactive Python session: imports follow the current workspace,
    # not the directory containing this launcher script.
    sys.path[0] = ""
    NAMESPACE.update(cells=Cells(), output=Output())
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
