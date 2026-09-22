"""Python plugin boundary; imported without starting a kernel."""
from __future__ import annotations

import asyncio
from collections.abc import Awaitable, Callable, Sequence
import importlib
import inspect
import keyword
from dataclasses import dataclass
from typing import Literal, NotRequired, Protocol, TypedDict, cast

Host = Callable[[str, dict[str, object]], Awaitable[object]]
Send = Callable[[dict[str, object]], None]
# Shutdown callbacks run while the loop can still run code; returning an
# awaitable lets a plugin clean up asynchronously.
Cleanup = Callable[[], object]


class OutputCapture(Protocol):
    tail_data: bytearray
    seen: int

    def write(self, text: str) -> None: ...


@dataclass(frozen=True)
class PythonApi:
    loop: asyncio.AbstractEventLoop
    host: Host
    HostError: type[Exception]
    # An output channel for one piece of background work, retained under that id
    # so the session can read it back through `output`.
    capture: Callable[[str], OutputCapture]
    preview: int
    send: Send
    on_shutdown: Callable[[Cleanup], None]
    background_handle: Callable[[type[object]], None]
    version: int = 1
    # The module list this kernel was started with, so a plugin can learn the
    # session's tool selection (remote boots the same set on another machine).
    modules: Sequence[str] = ()
    # Registers one callback for a retained output channel, fired when the
    # model reads it, so background work can withdraw a completion wake the
    # read already satisfied. Absent when the host pre-dates the hook.
    watch_output: Callable[[str, Callable[[], None]], None] | None = None


class Execute(TypedDict):
    type: Literal["execute"]
    id: str
    code: str
    durable: NotRequired[bool]


class HostSuccess(TypedDict):
    ok: Literal[True]
    value: object


class HostFailure(TypedDict):
    ok: Literal[False]
    code: str
    message: str


HostReply = HostSuccess | HostFailure


class Reply(TypedDict):
    type: Literal["reply"]
    id: str
    value: HostReply


class Interrupt(TypedDict):
    type: Literal["interrupt"]
    id: str
    reason: NotRequired[Literal["deadline", "cancelled"]]


class Shutdown(TypedDict):
    type: Literal["shutdown"]


class Invoke(TypedDict):
    """One owner tool call: a namespace path or live reference, never both.

    A `wait: true` frame (spelled "await" on the wire, a JSON key TypedDict
    cannot express) awaits the live reference instead of calling a method.
    """
    type: Literal["invoke"]
    id: str
    name: NotRequired[str]
    target: NotRequired[dict[str, str]]
    args: NotRequired[list[object]]
    kwargs: NotRequired[dict[str, object]]


class Introspect(TypedDict):
    type: Literal["introspect"]
    id: str


class Release(TypedDict):
    type: Literal["release"]
    handle: str


class State(TypedDict):
    """Save the namespace to disk, or revive it from an earlier save."""
    type: Literal["snapshot", "restore"]
    id: str
    path: str


Incoming = Execute | Reply | Interrupt | Shutdown | Invoke | Introspect | Release | State


class SavedCell(TypedDict):
    id: str
    source: str
    started: bool
    parent: str | None
    finished: bool


class PythonPlugin(Protocol):
    def setup(self, api: PythonApi) -> "dict[str, object] | Awaitable[dict[str, object]]": ...


async def load_plugins(names: Sequence[str], api: PythonApi, namespace: dict[str, object]) -> None:
    """Load explicitly trusted modules before the workspace enters sys.path.

    setup(api) returns public REPL bindings, or an awaitable that resolves them,
    so a plugin may call api.host while the kernel boots. Plugins use api.host
    for host RPC, api.on_shutdown for cleanup, and api.background_handle for
    nonblocking jobs. This is composition, not isolation: installed plugins
    execute trusted code.
    """
    modules: list[str] = []
    for name in names:
        if not isinstance(name, str) or not all(part.isidentifier() and not keyword.iskeyword(part) for part in name.split(".")):
            raise ValueError(f"invalid Python plugin module: {name!r}")
        module = name if "." in name else "albedo_plugins." + name
        if module in modules:
            raise ValueError(f"duplicate Python plugin module: {module}")
        modules.append(module)
    for module in modules:
        try:
            plugin = cast(PythonPlugin, cast(object, importlib.import_module(module)))
            exports = plugin.setup(api)
            if inspect.isawaitable(exports):
                exports = await cast(Awaitable[dict[str, object]], exports)
            if not isinstance(exports, dict) or not all(
                isinstance(name, str) and name.isidentifier() and not name.startswith("_")
                and not keyword.iskeyword(name) for name in exports
            ):
                raise ValueError("setup(api) must return a dict of public Python bindings")
            collisions = namespace.keys() & exports.keys()
            if collisions:
                raise ValueError(f"duplicate or reserved bindings: {', '.join(sorted(collisions))}")
            namespace.update(exports)
        except Exception as error:
            raise RuntimeError(f"Python plugin {module}: {error}") from error
