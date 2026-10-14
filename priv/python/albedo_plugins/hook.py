"""Tool calls made inside a cell, reported to the session's hooks
(robot-docs/hooks.md): before one runs, when a hook may refuse it or rewrite
its arguments, and once it has finished."""

from __future__ import annotations

import functools
import inspect
import json
import time
import uuid
from collections.abc import Callable
from typing import Any, TypeVar, cast

import albedo_trace

from albedo_api import PythonApi

Method = TypeVar("Method", bound=Callable[..., Any])

# Set when the session has hooks: the kernel loads this module only then, so
# a session without them never pays the round trip.
host_now: Callable[[str, dict[str, object]], object] | None = None


def setup(api: PythonApi) -> dict[str, object]:
    global host_now
    host_now = api.host_now
    return {}


def now_ms() -> int:
    return time.time_ns() // 1_000_000


class Call:
    """Asks the hooks before `name` runs on `arguments`, printing what they
    say; `arguments` is then what to run it with. Raises PermissionError when
    a hook refuses the call. Hooks that cannot be reached fail open."""

    def __init__(self, name: str, arguments: dict[str, object]) -> None:
        cell = getattr(albedo_trace.current(), "id", None)
        self.started = now_ms()
        self.call: dict[str, object] = {
            "id": uuid.uuid4().hex,
            "name": name,
            "arguments": json.dumps(arguments),
            "within": cell.rsplit("/", 1)[-1] if isinstance(cell, str) else None,
        }
        answer, said = self._ask("hook.call", self.call)
        for line in said:
            print(line)
        if answer.get("block"):
            raise PermissionError(f"blocked by a hook: {answer['block']}")
        if isinstance(answer.get("arguments"), str):
            self.call["arguments"] = answer["arguments"]
        self.arguments: dict[str, object] = json.loads(str(self.call["arguments"]))

    def finished(self, output: str) -> list[str]:
        """Reports the outcome; answers the lines the hooks said about it."""
        answer, said = self._ask(
            "hook.called",
            {
                "call": self.call,
                "output": output,
                "started_ms": self.started,
                "finished_ms": now_ms(),
            },
        )
        block = answer.get("block")
        return said if not block else [*said, f"a hook objected: {block}"]

    def _ask(
        self, method: str, args: dict[str, object]
    ) -> tuple[dict[str, object], list[str]]:
        if host_now is None:
            return {}, []
        try:
            answer = host_now(method, args)
        except Exception as error:
            return {}, [f"hooks failed open: {error}"]
        if not isinstance(answer, dict):
            return {}, []
        said = [
            str(text) for key in ("notes", "context") for text in answer.get(key) or []
        ]
        return answer, said


def reported(name: str, fields: dict[str, str]) -> Callable[[Method], Method]:
    """Reports each call of a method as `name`,
    its parameters renamed by `fields` into the hook arguments, and runs it
    with the arguments the hooks left."""

    def wrap(method: Method) -> Method:
        signature = inspect.signature(method)

        @functools.wraps(method)
        def call(self: Any, *args: object, **kwargs: object) -> object:
            bound = signature.bind(self, *args, **kwargs)
            given = bound.arguments
            hooked = Call(
                name,
                {field: given[key] for key, field in fields.items() if key in given},
            )
            for key, field in fields.items():
                if field in hooked.arguments:
                    given[key] = hooked.arguments[field]
            try:
                result = method(*bound.args, **bound.kwargs)
            except Exception as error:
                hooked.finished(f"{type(error).__name__}: {error}")
                raise
            for line in hooked.finished(str(result)):
                print(line)
            return result

        return cast(Method, call)

    return wrap
