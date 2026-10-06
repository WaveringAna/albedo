"""MCP operations as Python bindings, so a cell composes, batches and filters
MCP calls without each result passing through the model's context.

`mcp.tools()`, `mcp.describe()` and `mcp.call()` read the live catalogue;
`mcp.<server>.<tool>(**arguments)` methods are minted from the catalogue at
kernel boot, so an operation a server adds later is reached through `call`.
"""

from __future__ import annotations

from collections.abc import Callable, Coroutine
from typing import Any, cast
import keyword
import re

from albedo_api import Host, PythonApi, Record
import albedo_trace

Operation = dict[str, object]


def _record(value: object) -> object:
    """A result as nested records, so `r.content[0].text` reads."""
    if isinstance(value, dict):
        return Record({key: _record(item) for key, item in value.items()})
    if isinstance(value, list):
        return [_record(item) for item in value]
    return value


def _named(operations: list[Operation], name: str) -> list[Operation]:
    """The operations `name` means: the advertised name, or `server/tool`."""
    found = [item for item in operations if item.get("name") == name]
    if not found and "/" in name:
        server, tool = name.split("/", 1)
        found = [
            item
            for item in operations
            if item.get("server") == server and item.get("tool") == tool
        ]
    return found


class Mcp:
    """This session's MCP servers. Results are records of the server's
    CallToolResult: untrusted data, with a tool-reported failure in `isError`
    rather than raised; McpError is raised when the call itself fails."""

    def __init__(self, host: Host) -> None:
        self._host = host

    async def _operations(self) -> list[Operation]:
        return cast(list[Operation], await self._host("mcp.list", {}))

    async def tools(self, server: str | None = None) -> list[Record]:
        """Every operation (name, server, kind, tool, description), or one server's."""
        return [
            Record(
                {
                    key: item.get(key, "")
                    for key in ("name", "server", "kind", "tool", "description")
                }
            )
            for item in await self._operations()
            if server is None or item.get("server") == server
        ]

    async def describe(self, name: str) -> Record:
        """One operation with its `parameters` schema; name as for call()."""
        found = _named(await self._operations(), name)
        if not found:
            raise LookupError(f"unknown MCP operation {name!r}; mcp.tools() lists them")
        return Record(found[0])

    async def call(
        self, name: str, arguments: dict[str, object] | None = None, **kwargs: object
    ) -> Record:
        """Call one operation by advertised name or `server/tool`; keyword
        arguments join `arguments`."""
        merged = {**(arguments or {}), **kwargs}
        albedo_trace.note("mcp", name, str(merged)[:512])
        result = await self._host("mcp.call", {"name": name, "arguments": merged})
        return cast(Record, _record(result))


def _identifier(value: str) -> str:
    return re.sub(r"[^a-zA-Z0-9_]", "_", value)


def _mintable(name: str, taken: set[str]) -> bool:
    return (
        bool(name)
        and not name.startswith("_")
        and not keyword.iskeyword(name)
        and name not in taken
    )


def _method(mcp: Mcp, item: Operation) -> Callable[..., Coroutine[Any, Any, Record]]:
    name = cast(str, item["name"])
    schema = cast(dict[str, object], item.get("parameters") or {})
    required = cast(list[str], schema.get("required") or [])
    names = required + [
        key for key in cast(dict, schema.get("properties") or {}) if key not in required
    ]

    async def call(**arguments: object) -> Record:
        return await mcp.call(name, arguments)

    call.__name__ = _identifier(cast(str, item["tool"]))
    call.__qualname__ = f"mcp.{_identifier(cast(str, item['server']))}.{call.__name__}"
    call.__doc__ = str(item.get("description", "")) + (
        "\n\nArguments: " + ", ".join(names) if names else ""
    )
    return call


class Server:
    """One MCP server's operations as methods."""

    def __init__(self, name: str) -> None:
        self.name = name


async def setup(api: PythonApi) -> dict[str, object]:
    """Mint `mcp.<server>.<tool>` from the boot catalogue; an operation whose
    identifiers clash or are not mintable stays reachable through mcp.call."""
    mcp = Mcp(api.host)
    servers: dict[str, Server] = {}
    for item in cast(list[Operation], await api.host("mcp.list", {})):
        server = _identifier(str(item.get("server", "")))
        tool = _identifier(str(item.get("tool", "")))
        if not _mintable(server, set(dir(mcp))) or not _mintable(
            tool, set(dir(Server))
        ):
            continue
        holder = servers.setdefault(server, Server(str(item["server"])))
        if not hasattr(holder, tool):
            setattr(holder, tool, _method(mcp, item))
    for server, holder in servers.items():
        setattr(mcp, server, holder)
    return {"mcp": mcp, "McpError": api.HostError}
