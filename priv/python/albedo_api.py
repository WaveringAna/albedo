"""Python plugin boundary; imported without starting a kernel."""

from __future__ import annotations

import asyncio
from collections.abc import Awaitable, Callable, Sequence
import importlib
import inspect
import keyword
from dataclasses import dataclass
from typing import Protocol, cast

from albedo_protocol import (
    Execute as Execute,
    HostSuccess as HostSuccess,
    HostFailure as HostFailure,
    HostReply as HostReply,
    Reply as Reply,
    Interrupt as Interrupt,
    Shutdown as Shutdown,
    Invoke as Invoke,
    Introspect as Introspect,
    Release as Release,
    State as State,
    Incoming as Incoming,
    SavedCell as SavedCell,
)

RETAIN = 1024 * 1024  # output bytes kept per channel; a late pipe reads them

Host = Callable[[str, dict[str, object]], Awaitable[object]]
Send = Callable[[dict[str, object]], None]
# Shutdown callbacks run while the loop can still run code; returning an
# awaitable lets a plugin clean up asynchronously.
Cleanup = Callable[[], object]


def _ready(value):
    """`await` on a value that is already here: returns it without suspending."""
    yield from ()
    return value


class Text(str):
    """A result that is ready now. Awaiting it is harmless, so a synchronous
    call reads the same with or without `await`. `.content` and `.text` are the
    text itself, for code written against a response object."""

    def __await__(self):
        return _ready(self)

    @property
    def content(self) -> str:
        return str(self)

    @property
    def text(self) -> str:
        return str(self)


class ReadyList(list):
    """A list result that is ready now; like Text, it may be awaited."""

    def __await__(self):
        return _ready(self)


class Record(dict):
    """A result record: `item["id"]` and `item.id` both work, it prints and
    serializes as the plain dict it is, and it may be awaited like Text."""

    __slots__ = ()

    def __getattr__(self, name: str) -> object:
        try:
            return self[name]
        except KeyError:
            raise AttributeError(
                f"{type(self).__name__} has no field {name!r}; its fields are {', '.join(self) or 'none'}"
            ) from None

    def __await__(self):
        return _ready(self)


def excerpt(text: str, chars: int, lines: int | None, *, end: bool) -> str:
    """Output's first or last `lines` lines, else its first or last `chars`
    characters: what a job handle's head() and tail() answer."""
    if lines is not None:
        kept = text.splitlines(keepends=True)
        return "".join(kept[-lines:] if end else kept[:lines]) if lines > 0 else ""
    chars = max(1, chars)
    return text[-chars:] if end else text[:chars]


class OutputCapture(Protocol):
    data: bytearray  # the retained start of the output, as written
    seen: int  # bytes written, retained or not

    def write(self, text: str) -> None: ...

    def write_bytes(self, data: bytes | bytearray | memoryview) -> None: ...

    def tail(self, limit: int = 65536) -> bytes: ...

    def read(self, offset: int = 0, limit: int = 4000) -> str: ...


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
    # Drops one retained output channel, so work a plugin runs for itself (a
    # search job, say) never crowds the model's own output out of retention.
    forget_output: Callable[[str], None] | None = None
    # Attaches PNG, JPEG, or WebP bytes to the running cell's result, so the
    # model sees the image; returns a short description, raises ValueError
    # past the per-cell limits. Absent when the host pre-dates images.
    attach_image: Callable[[bytes], str] | None = None
    # A host call that blocks until its answer, for synchronous APIs over
    # routes that answer at once. Absent when the host pre-dates it.
    host_now: Callable[[str, dict[str, object]], object] | None = None


class PythonPlugin(Protocol):
    def setup(
        self, api: PythonApi
    ) -> "dict[str, object] | Awaitable[dict[str, object]]": ...


async def load_plugins(
    names: Sequence[str], api: PythonApi, namespace: dict[str, object]
) -> None:
    """Load explicitly trusted modules before the workspace enters sys.path.

    setup(api) returns public REPL bindings, or an awaitable that resolves them,
    so a plugin may call api.host while the kernel boots. Plugins use api.host
    for host RPC, api.on_shutdown for cleanup, and api.background_handle for
    nonblocking jobs. This is composition, not isolation: installed plugins
    execute trusted code.
    """
    modules: list[str] = []
    for name in names:
        if not isinstance(name, str) or not all(
            part.isidentifier() and not keyword.iskeyword(part)
            for part in name.split(".")
        ):
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
                isinstance(name, str)
                and name.isidentifier()
                and not name.startswith("_")
                and not keyword.iskeyword(name)
                for name in exports
            ):
                raise ValueError(
                    "setup(api) must return a dict of public Python bindings"
                )
            collisions = namespace.keys() & exports.keys()
            if collisions:
                raise ValueError(
                    f"duplicate or reserved bindings: {', '.join(sorted(collisions))}"
                )
            namespace.update(exports)
        except Exception as error:
            raise RuntimeError(f"Python plugin {module}: {error}") from error
