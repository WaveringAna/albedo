"""Calls made inside a cell, reported to the session's hooks
(robot-docs/hooks.md): before one runs, when a hook may refuse it or rewrite
its arguments, and once it has finished. The kernel loads this module only
while some extension hooks the session."""

from __future__ import annotations

import functools
import inspect
import json
import time
import uuid
from collections.abc import Awaitable, Callable
from typing import Any, TypeVar, cast

from albedo_api import Host, PythonApi
import albedo_trace

Method = TypeVar("Method", bound=Callable[..., Any])
Result = TypeVar("Result")

host: Host | None = None
host_now: Callable[[str, dict[str, object]], object] | None = None


def setup(api: PythonApi) -> dict[str, object]:
    global host, host_now
    host, host_now = api.host, api.host_now
    return {}


def now_ms() -> int:
    return time.time_ns() // 1_000_000


def as_json(value: object) -> str:
    return json.dumps(value, default=str)


class Call:
    """One reported call. `arguments` are what to run it with once the hooks
    answered; a refusal raises PermissionError. Hooks that cannot be reached
    fail open."""

    def __init__(self, name: str, arguments: dict[str, object]) -> None:
        cell = getattr(albedo_trace.current(), "id", None)
        self.started = now_ms()
        self.arguments = arguments
        self.call: dict[str, object] = {
            "id": uuid.uuid4().hex,
            "name": name,
            "arguments": as_json(arguments),
            "within": cell.rsplit("/", 1)[-1] if isinstance(cell, str) else None,
        }

    def asked(self, answer: dict[str, object]) -> Call:
        for line in said(answer):
            print(line)
        if answer.get("block"):
            raise PermissionError(f"blocked by a hook: {answer['block']}")
        if isinstance(answer.get("arguments"), str):
            self.call["arguments"] = answer["arguments"]
            self.arguments = json.loads(str(answer["arguments"]))
        return self

    def outcome(self, output: str) -> dict[str, object]:
        return {
            "call": self.call,
            "output": output,
            "started_ms": self.started,
            "finished_ms": now_ms(),
        }

    def changed(self, given: dict[str, object]) -> dict[str, object]:
        """`given` with each value a hook rewrote, so an unchanged argument
        keeps its own type (a page node, say) rather than its JSON."""
        return {
            key: self.arguments[key]
            if key in self.arguments and as_json(self.arguments[key]) != as_json(value)
            else value
            for key, value in given.items()
        }


def said(answer: dict[str, object], after: bool = False) -> list[str]:
    lines = [
        str(text)
        for key in ("notes", "context")
        for text in cast(list[object], answer.get(key) or [])
    ]
    if after and answer.get("block"):
        lines.append(f"a hook objected: {answer['block']}")
    return lines


def ask_now(method: str, args: dict[str, object]) -> dict[str, object]:
    if host_now is None:
        return {}
    try:
        answer = host_now(method, args)
    except Exception as error:
        return {"notes": [f"hooks failed open: {error}"]}
    return answer if isinstance(answer, dict) else {}


async def ask(method: str, args: dict[str, object]) -> dict[str, object]:
    if host is None:
        return {}
    try:
        answer = await host(method, args)
    except Exception as error:
        return {"notes": [f"hooks failed open: {error}"]}
    return answer if isinstance(answer, dict) else {}


def before(name: str, arguments: dict[str, object]) -> Call:
    """Asks the hooks before `name` runs, from synchronous code."""
    call = Call(name, arguments)
    return call.asked(ask_now("hook.call", call.call))


def after(call: Call, output: str) -> list[str]:
    """Reports the outcome; answers the lines the hooks said about it."""
    return said(ask_now("hook.called", call.outcome(output)), after=True)


async def after_async(call: Call, output: str) -> list[str]:
    """`after`, for async code."""
    return said(await ask("hook.called", call.outcome(output)), after=True)


async def job_ended(call: Call, exit_code: int | None, timed_out: bool) -> str:
    """Reports a finished job; answers what the hooks said, for its output."""
    outcome = as_json({"exit_code": exit_code, "timed_out": timed_out})
    return "".join(f"{line}\n" for line in await after_async(call, outcome))


async def around(
    name: str,
    arguments: dict[str, object],
    run: Callable[[dict[str, object]], Awaitable[Result]],
) -> Result:
    """Runs `run` on the arguments the hooks left, reporting it before and
    after; for async calls."""
    call = Call(name, arguments)
    call.asked(await ask("hook.call", call.call))
    try:
        result = await run(call.changed(arguments))
    except Exception as error:
        await after_async(call, f"{type(error).__name__}: {error}")
        raise
    for line in await after_async(call, str(result)):
        print(line)
    return result


def reported(name: str, fields: dict[str, str]) -> Callable[[Method], Method]:
    """Reports each call of a method, sync or async, as `name`: its
    parameters renamed by `fields` are the hook arguments, and it runs with
    the values the hooks left."""

    def wrap(method: Method) -> Method:
        signature = inspect.signature(method)

        def bind(
            args: tuple[object, ...], kwargs: dict[str, object]
        ) -> tuple[inspect.BoundArguments, dict[str, object]]:
            bound = signature.bind(*args, **kwargs)
            bound.apply_defaults()
            given = {field: bound.arguments[key] for key, field in fields.items()}
            return bound, given

        def rebind(bound: inspect.BoundArguments, kept: dict[str, object]) -> None:
            for key, field in fields.items():
                bound.arguments[key] = kept[field]

        if inspect.iscoroutinefunction(method):

            @functools.wraps(method)
            async def call_async(*args: object, **kwargs: object) -> object:
                arguments, given = bind(args, kwargs)

                async def run(kept: dict[str, object]) -> object:
                    rebind(arguments, kept)
                    return await method(*arguments.args, **arguments.kwargs)

                return await around(name, given, run)

            return cast(Method, call_async)

        @functools.wraps(method)
        def call(*args: object, **kwargs: object) -> object:
            arguments, given = bind(args, kwargs)
            hooked = before(name, given)
            rebind(arguments, hooked.changed(given))
            try:
                result = method(*arguments.args, **arguments.kwargs)
            except Exception as error:
                after(hooked, f"{type(error).__name__}: {error}")
                raise
            for line in after(hooked, str(result)):
                print(line)
            return result

        return cast(Method, call)

    return wrap
