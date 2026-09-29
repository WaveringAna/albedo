"""agents: spawn children, look up any session and read its messages, cancel
or close your own children.
Talking is mail.submit. Spawn returns once the child exists; its answer
arrives later as mail and starts your next turn."""

from __future__ import annotations

import os
import time
from dataclasses import dataclass, field
from typing import cast

from albedo_api import Host, PythonApi, Record

host: Host
_models_seen = False
_last_progress = 0.0


class MessagePage(Record):
    """page.content and page["content"] both work; next_offset is None at the end."""

    seq: int
    offset: int
    content: str
    next_offset: int | None


class MessageMatches(Record):
    """matches.rows is a list of {seq, preview}; read one with messages(seq=...)."""

    pattern: str
    offset: int
    count: int
    next_offset: int | None
    rows: list[dict]


@dataclass(frozen=True)
class Agent:
    """A handle to one agent. `running` and `closed` are set on snapshots
    from get(), children(), siblings(), and sessions(); None on handles that
    were not looked up. `cwd`, `model`, `last_active` (unix seconds of its
    last answer), and `matches` are set only on snapshots from sessions()."""

    id: str
    name: str
    depth: int
    parent: "Agent | None" = None
    running: bool | None = None
    closed: bool | None = None
    cwd: str | None = None
    model: str | None = None
    last_active: int | None = None
    matches: list[dict] | None = field(default=None, compare=False)

    async def spawn(
        self,
        task: str,
        *,
        name: str,
        model: str,
        deliverable: str | None = None,
        evidence_bar: str | None = None,
        falsifier: str | None = None,
    ) -> "Agent":
        """Start a child with `task`. Returns at once; its answer comes as mail."""
        if self.id != agents.self.id:
            raise PermissionError(
                "only agents.self.spawn(...) starts children: you spawn your own"
            )
        if not _models_seen:
            raise RuntimeError(
                "call await agents.models() first and pick a model from it"
            )
        for label, value in (("task", task), ("name", name), ("model", model)):
            if not isinstance(value, str) or not value.strip():
                raise TypeError(f"{label} must be a non-empty str")
        brief = _brief(
            task,
            name=name,
            deliverable=deliverable,
            evidence_bar=evidence_bar,
            falsifier=falsifier,
        )
        return _agent(
            cast(
                dict,
                await host(
                    "agents.spawn", {"task": brief, "name": name, "model": model}
                ),
            )
        )

    async def children(self) -> list["Agent"]:
        if self.id != agents.self.id:
            raise PermissionError(
                "children() lists your own: use agents.self.children()"
            )
        return [_agent(item) for item in cast(list, await host("agents.children", {}))]

    async def siblings(self) -> list["Agent"]:
        if self.id != agents.self.id:
            raise PermissionError(
                "siblings() lists your own: use agents.self.siblings()"
            )
        return [_agent(item) for item in cast(list, await host("agents.siblings", {}))]

    async def cancel(self) -> bool:
        """Stop this child's running turn. It keeps its session and work."""
        return bool(await host("agents.cancel", {"id": self.id}))

    async def close(self) -> bool:
        """Done with this child: stop it, keep its messages and files, free its kernel."""
        return bool(await host("agents.close", {"id": self.id}))

    async def messages(
        self, seq: int = 0, *, offset: int = 0, limit: int = 4000
    ) -> MessagePage:
        """A page of this session's messages from row `seq` on (at most 8000 chars).
        Any session may read any other."""
        return MessagePage(
            cast(
                dict,
                await host(
                    "agents.messages",
                    {"id": self.id, "seq": seq, "offset": offset, "limit": limit},
                ),
            )
        )

    async def search_messages(
        self, pattern: str, *, limit: int = 10, offset: int = 0
    ) -> MessageMatches:
        """This session's message rows containing `pattern`, case-insensitively."""
        return MessageMatches(
            cast(
                dict,
                await host(
                    "agents.search_messages",
                    {
                        "id": self.id,
                        "pattern": pattern,
                        "limit": limit,
                        "offset": offset,
                    },
                ),
            )
        )

    async def delete(self) -> None:
        await host("agents.delete", {"id": self.id})


def _agent(raw: dict) -> Agent:
    parent = raw.get("parent")
    return Agent(
        id=raw["id"],
        name=raw["name"],
        depth=raw["depth"],
        parent=_agent(parent) if isinstance(parent, dict) else None,
        running=raw.get("running"),
        closed=raw.get("closed"),
        cwd=raw.get("cwd"),
        model=raw.get("model"),
        last_active=raw.get("last_active"),
        matches=raw.get("matches"),
    )


def _directory(cwd: str | None) -> str:
    """A cwd filter as sessions store it: absolute, or "" for every directory."""
    return os.path.abspath(os.path.expanduser(cwd)) if cwd else ""


def _brief(
    task: str,
    *,
    name: str,
    deliverable: str | None,
    evidence_bar: str | None,
    falsifier: str | None,
) -> str:
    parts = [f"TASK:\n{task.strip()}"]
    if deliverable:
        parts.append(
            f"DELIVERABLE: {deliverable.strip()}\nWrite it to {deliverable.strip()}.partial and rename it "
            "into place when finished, so a reader never sees half of it."
        )
    if evidence_bar:
        parts.append(f"EVIDENCE BAR:\n{evidence_bar.strip()}")
    if falsifier:
        parts.append(f"FALSIFIER:\n{falsifier.strip()}")
    parts.append(
        'WHEN DONE: await mail.submit("parent", <short summary, with paths to anything large>).'
    )
    return "\n\n".join(parts)


class Agents:
    self: Agent

    async def models(self) -> list[str]:
        """Models a child may run on. Required once before spawning."""
        global _models_seen
        _models_seen = True
        return list(cast(list, await host("agents.models", {})))

    async def progress(self, text: str) -> bool:
        """A short status (≤512 chars) the agents view shows without starting a
        turn. At most one per 10 seconds; returns False when throttled."""
        global _last_progress
        if not isinstance(text, str) or not text.strip():
            raise TypeError("progress(text) takes a non-empty str")
        now = time.monotonic()
        if now - _last_progress < 10:
            return False
        _last_progress = now
        return bool(await host("agents.progress", {"text": text.strip()}))

    async def get(self, to: object) -> Agent:
        """A live snapshot of "parent", a child or sibling by name, an agent
        handle, or any session id, resolved the way mail.submit resolves it."""
        target = getattr(to, "id", to)
        if not isinstance(target, str) or not target.strip():
            raise TypeError(
                'agents.get(to): to is "parent", a name, a session id, or an agent handle'
            )
        return _agent(cast(dict, await host("agents.get", {"to": target.strip()})))

    async def sessions(
        self,
        query: str = "",
        *,
        cwd: str | None = None,
        limit: int = 20,
        offset: int = 0,
    ) -> list[Agent]:
        """Every session, most recently active first (at most 100 per call).
        A `query` keeps those whose title or name contains it, or whose
        messages do, case-insensitively; each snapshot's `matches` then holds
        up to 3 of its newest matching rows as {seq, preview}, to read with
        messages(seq=...). Your own messages are not searched. With `cwd`,
        only sessions opened in that directory."""
        found = await host(
            "agents.sessions",
            {
                "query": query,
                "cwd": _directory(cwd),
                "limit": limit,
                "offset": offset,
            },
        )
        return [_agent(item) for item in cast(list, found)]

    def spawn(self, *_: object, **__: object) -> None:
        raise AttributeError(
            "spawn lives on your handle: await agents.self.spawn(task, name=..., model=...)"
        )


agents = Agents()


async def setup(api: PythonApi) -> dict[str, object]:
    global host
    host = api.host
    agents.self = _agent(cast(dict, await host("agents.self", {})))
    return {"agents": agents, "Agent": Agent, "AgentsError": api.HostError}
