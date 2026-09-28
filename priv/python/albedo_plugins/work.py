from __future__ import annotations

from albedo_api import Host, PythonApi, Record
from typing import cast


class WorkItem(Record):
    """One ledger item: item.id and item["id"] both work."""

    id: int
    title: str
    notes: str
    status: str
    parent: int | None
    session: str | None
    run: str | None
    revision: int


host: Host


class Work:
    async def list(self, after: int = 0, limit: int = 50) -> list[WorkItem]:
        return [
            WorkItem(item)
            for item in cast(
                list[dict], await host("work.list", {"after": after, "limit": limit})
            )
        ]

    async def get(self, id: int) -> WorkItem:
        return WorkItem(cast(dict, await host("work.get", {"id": id})))

    async def create(
        self, title: str, notes: str = "", parent: int | None = None
    ) -> WorkItem:
        return WorkItem(
            cast(
                dict,
                await host(
                    "work.create", {"title": title, "notes": notes, "parent": parent}
                ),
            )
        )

    async def update(self, id: int, *, revision: int, **changes: object) -> WorkItem:
        allowed = {"title", "notes", "status", "session", "run"}
        if changes.keys() - allowed:
            raise ValueError("unknown work fields: " + repr(changes.keys() - allowed))
        return WorkItem(
            cast(
                dict,
                await host("work.update", {"id": id, "revision": revision, **changes}),
            )
        )

    async def delete(self, id: int, *, revision: int) -> WorkItem:
        """Remove an item at the revision you last read; one with sub-items stays."""
        return WorkItem(
            cast(dict, await host("work.delete", {"id": id, "revision": revision}))
        )


def setup(api: PythonApi) -> dict[str, object]:
    global host
    host = api.host
    return {"work": Work(), "WorkError": api.HostError}
