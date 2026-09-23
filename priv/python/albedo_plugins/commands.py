"""This session's slash commands as typed bindings, minted from the catalog.

Each model-callable command in the catalog at kernel boot becomes a typed
async method whose docstring and signature come from its declared arguments,
so help(commands.<method>) is the command's help text. catalog() and invoke()
read the live catalog, so a session /reload reaches them without a kernel
restart; a command whose method name is reserved, invalid, taken, or added
after boot stays callable through commands.invoke().
"""
from __future__ import annotations

import inspect
import keyword
from typing import TypedDict, cast

from albedo_api import Host, PythonApi

RESERVED = frozenset({"catalog", "invoke", "help", "__init__"})


class CommandArgument(TypedDict):
    name: str
    description: str
    required: bool


class CommandSummary(TypedDict):
    name: str
    description: str
    method: str
    usage: str
    arguments: list[CommandArgument]
    modelCallable: bool
    userTurn: bool


def _wire_value(value: object, name: str) -> str:
    return value if isinstance(value, str) else str(value)


def _bind(spec: list[CommandArgument], args: tuple[object, ...], kwargs: dict[str, object]) -> dict[str, str]:
    declared = [argument["name"] for argument in spec]
    if len(args) > len(declared):
        raise TypeError(f"expected at most {len(declared)} positional arguments, got {len(args)}")
    unknown = sorted(set(kwargs) - set(declared))
    if unknown:
        raise TypeError(f"unexpected arguments: {', '.join(unknown)}")
    supplied: dict[str, str] = {}
    for name, value in zip(declared, args):
        if value is not None:
            supplied[name] = _wire_value(value, name)
    for name, value in kwargs.items():
        if value is not None:
            supplied[name] = _wire_value(value, name)
    return supplied


def _docstring(summary: CommandSummary) -> str:
    lines = [summary["description"], "", "Usage: " + summary["usage"]]
    if summary["arguments"]:
        lines.append("")
        lines.append("Args:")
        for argument in summary["arguments"]:
            kind = "required" if argument["required"] else "optional"
            lines.append(f"    {argument['name']}: {argument['description']} ({kind})")
    lines.append("")
    lines.append("Returns the command's JSON result as a Python value; never submits a turn.")
    return "\n".join(lines)


def _signature(spec: list[CommandArgument]) -> inspect.Signature | None:
    """A real signature when declaration order is expressible in Python."""
    parameters: list[inspect.Parameter] = []
    defaulted = False
    for argument in spec:
        name = argument["name"]
        if not name.isidentifier() or keyword.iskeyword(name):
            return None
        if argument["required"]:
            if defaulted:
                return None
            default: object = inspect.Parameter.empty
        else:
            defaulted = True
            default = None
        parameters.append(inspect.Parameter(
            name, inspect.Parameter.POSITIONAL_OR_KEYWORD, default=default))
    return inspect.Signature(parameters)


def _method(host: Host, summary: CommandSummary) -> object:
    spec = summary["arguments"]

    async def run(*args: object, **kwargs: object) -> object:
        supplied = _bind(spec, args, kwargs)
        return await host("commands.run", {"name": summary["name"], "args": supplied})

    run.__name__ = summary["method"]
    run.__qualname__ = "Commands." + summary["method"]
    run.__doc__ = _docstring(summary)
    signature = _signature(spec)
    if signature is not None:
        run.__signature__ = signature  # type: ignore[attr-defined]
    return run


class Commands:
    """This session's slash commands. Every model-callable command at kernel
    boot is a typed async method; see the catalog for method names and
    help(commands.<method>) for one command's help."""

    def __init__(self, host: Host) -> None:
        self._host = host

    async def catalog(self) -> list[CommandSummary]:
        """This session's current command catalog, including reloaded ones."""
        return cast(list[CommandSummary], await self._host("commands.list", {}))

    async def invoke(self, name: str, arguments: str | dict[str, object] = "") -> object:
        """Run any model-callable command by slash name or method name.

        The arguments are either the raw invocation text or a dict of declared
        argument names to values. Returns the command's JSON result and never
        submits a turn.
        """
        target = name if name.startswith("/") else "/" + name
        for summary in await self.catalog():
            if summary["name"] == target or summary["method"] == name:
                break
        else:
            raise LookupError(f"unknown command {name!r}; commands.catalog() lists them")
        wire: dict[str, object]
        if isinstance(arguments, str):
            wire = {"name": summary["name"], "arguments": arguments}
        else:
            wire = {"name": summary["name"],
                    "args": {key: _wire_value(value, key) for key, value in arguments.items() if value is not None}}
        return await self._host("commands.run", wire)


async def setup(api: PythonApi) -> dict[str, object]:
    """Mint typed bindings from the boot catalog. A fast pure RPC: the route
    answers from the session's captured command list before any turn runs.
    The catalog's method names are unique and mintable by construction; the
    checks below keep a damaged catalog from breaking the kernel."""
    catalog = cast(list[CommandSummary], await api.host("commands.list", {}))
    bindings: dict[str, object] = {}
    for summary in catalog:
        method = summary["method"]
        if (not summary["modelCallable"] or method in RESERVED or method in bindings
                or not method.isidentifier() or keyword.iskeyword(method)):
            continue
        bindings[method] = staticmethod(_method(api.host, summary))
    session_commands = type("SessionCommands", (Commands,), bindings)
    return {"commands": session_commands(api.host), "CommandsError": api.HostError}
