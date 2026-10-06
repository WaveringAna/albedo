"""Checked JSON messages at the kernel and remote connection boundaries."""

from typing import Literal, NotRequired, TypedDict, cast


class Execute(TypedDict):
    type: Literal["execute"]
    id: str
    code: str
    durable: NotRequired[bool]
    max_edge: NotRequired[int]
    timeout_ms: NotRequired[int]


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
    # `memory` is the kernel's own, from its memory guard; the owner sends the others.
    reason: NotRequired[Literal["deadline", "cancelled", "memory"]]


class Shutdown(TypedDict):
    type: Literal["shutdown"]


Invoke = TypedDict(
    "Invoke",
    {
        "type": Literal["invoke"],
        "id": str,
        "name": NotRequired[str],
        "target": NotRequired[dict[str, str]],
        "args": NotRequired[list[object]],
        "kwargs": NotRequired[dict[str, object]],
        "await": NotRequired[bool],
    },
)


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


Incoming = (
    Execute | Reply | Interrupt | Shutdown | Invoke | Introspect | Release | State
)


class SavedCell(TypedDict):
    id: str
    source: str
    started: bool
    parent: str | None
    finished: bool


class Ready(TypedDict):
    type: Literal["ready"]
    pid: int
    pgid: int | None
    leader: str | None


class StartupError(TypedDict):
    type: Literal["startup_error"]
    message: str


class RemoteCall(TypedDict):
    type: Literal["call"]
    id: str
    method: str
    args: dict[str, object]


class InvocationError(TypedDict):
    ename: str
    evalue: str
    traceback: list[str]


class MirrorState(TypedDict, total=False):
    job: str | None
    seen: int
    tail: str
    exit_code: int | None
    timed_out: bool
    duration: float | None


class Invoked(TypedDict):
    type: Literal["invoked"]
    id: str
    ok: bool
    value: NotRequired[object]
    handle: NotRequired[str]
    state: NotRequired[MirrorState]
    error: NotRequired[InvocationError]
    cancelled: NotRequired[bool]


class RemoteHandle(TypedDict):
    id: str
    repr: str


class Introspected(TypedDict):
    type: Literal["introspected"]
    id: str
    names: list[str]
    handles: list[RemoteHandle]


class Mirror(MirrorState):
    type: Literal["mirror"]
    handle: str


class RemoteEvent(TypedDict):
    type: Literal["job_start", "job", "trace", "done"]
    id: str


class RemoteCleanup(TypedDict):
    type: Literal["cleanup"]
    module: str


RemoteMessage = (
    Ready
    | StartupError
    | RemoteCall
    | Invoked
    | Introspected
    | Mirror
    | RemoteEvent
    | RemoteCleanup
)


def _object(value: object, context: str) -> dict[str, object]:
    if not isinstance(value, dict) or not all(isinstance(key, str) for key in value):
        raise ValueError(f"{context}: expected an object")
    return cast(dict[str, object], value)


def _field(
    message: dict[str, object],
    field: str,
    expected: type | tuple[type, ...],
    context: str,
    *,
    optional: bool = False,
) -> None:
    if optional and field not in message:
        return
    if field not in message:
        raise ValueError(f"{context}.{field}: required field")
    value = message[field]
    if not isinstance(value, expected) or (
        isinstance(value, bool)
        and expected is not bool
        and (expected is int or isinstance(expected, tuple) and int in expected)
    ):
        raise ValueError(f"{context}.{field}: invalid field type")


def _envelope(value: object) -> tuple[dict[str, object], str]:
    message = _object(value, "message")
    _field(message, "type", str, "message")
    return message, cast(str, message["type"])


def parse_incoming(value: object) -> Incoming:
    """Validate a kernel request before it reaches the event loop."""
    message, kind = _envelope(value)
    if kind not in {
        "execute",
        "reply",
        "interrupt",
        "shutdown",
        "invoke",
        "introspect",
        "release",
        "snapshot",
        "restore",
    }:
        raise ValueError(f"{kind}.type: unknown message type")
    if kind not in {"shutdown", "release"}:
        _field(message, "id", str, kind)
    if kind == "execute":
        _field(message, "code", str, kind)
        _field(message, "durable", bool, kind, optional=True)
        _field(message, "max_edge", int, kind, optional=True)
        _field(message, "timeout_ms", int, kind, optional=True)
    elif kind == "reply":
        reply = _object(message.get("value"), "reply.value")
        _field(reply, "ok", bool, "reply.value")
        if reply["ok"]:
            _field(reply, "value", object, "reply.value")
        else:
            _field(reply, "code", str, "reply.value")
            _field(reply, "message", str, "reply.value")
    elif kind == "interrupt":
        _field(message, "reason", str, kind, optional=True)
        if "reason" in message and message["reason"] not in (
            "deadline",
            "cancelled",
            "memory",
        ):
            raise ValueError("interrupt.reason: expected deadline, cancelled or memory")
    elif kind == "invoke":
        for field, expected in (
            ("name", str),
            ("args", list),
            ("kwargs", dict),
            ("await", bool),
        ):
            _field(message, field, expected, kind, optional=True)
        if "kwargs" in message:
            _object(message["kwargs"], "invoke.kwargs")
        if "target" in message:
            target = _object(message["target"], "invoke.target")
            if set(target) not in ({"handle"}, {"pending"}):
                raise ValueError(
                    "invoke.target: expected exactly one handle or pending"
                )
            _field(target, next(iter(target)), str, "invoke.target")
    elif kind == "release":
        _field(message, "handle", str, kind)
    elif kind in {"snapshot", "restore"}:
        _field(message, "path", str, kind)
    return cast(Incoming, message)


def _mirror(value: object, context: str) -> None:
    state = _object(value, context)
    for field, expected in (
        ("job", (str, type(None))),
        ("seen", int),
        ("tail", str),
        ("exit_code", (int, type(None))),
        ("timed_out", bool),
        ("duration", (int, float, type(None))),
    ):
        _field(state, field, expected, context, optional=True)


def parse_remote(value: object) -> RemoteMessage:
    """Validate remote replies and the event fields the owner consumes."""
    message, kind = _envelope(value)
    if kind in {"invoked", "introspected", "call", "job_start", "job", "trace", "done"}:
        _field(message, "id", str, kind)
    if kind == "ready":
        _field(message, "pid", int, kind)
        _field(message, "pgid", (int, type(None)), kind)
        _field(message, "leader", (str, type(None)), kind)
    elif kind == "startup_error":
        _field(message, "message", str, kind)
    elif kind == "call":
        _field(message, "method", str, kind)
        _object(message.get("args"), "call.args")
    elif kind == "invoked":
        _field(message, "ok", bool, kind)
        _field(message, "handle", str, kind, optional=True)
        _field(message, "cancelled", bool, kind, optional=True)
        if "state" in message:
            _mirror(message["state"], "invoked.state")
        if "error" in message or not message["ok"]:
            error = _object(message.get("error"), "invoked.error")
            _field(error, "ename", str, "invoked.error")
            _field(error, "evalue", str, "invoked.error")
            _field(error, "traceback", list, "invoked.error")
            if not all(
                isinstance(line, str) for line in cast(list[object], error["traceback"])
            ):
                raise ValueError("invoked.error.traceback: expected strings")
        if message["ok"] and "handle" not in message and "value" not in message:
            raise ValueError("invoked.value: required without handle")
    elif kind == "introspected":
        _field(message, "names", list, kind)
        if not all(
            isinstance(name, str) for name in cast(list[object], message["names"])
        ):
            raise ValueError("introspected.names: expected strings")
        _field(message, "handles", list, kind)
        for item in cast(list[object], message["handles"]):
            handle = _object(item, "introspected.handles")
            _field(handle, "id", str, "introspected.handles")
            _field(handle, "repr", str, "introspected.handles")
    elif kind == "mirror":
        _field(message, "handle", str, kind)
        _mirror(message, kind)
    elif kind == "cleanup":
        _field(message, "module", str, kind)
    elif kind not in {"job_start", "job", "trace", "done"}:
        raise ValueError(f"{kind}.type: unknown message type")
    return cast(RemoteMessage, message)
