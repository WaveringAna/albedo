from albedo_api import Host, PythonApi
from typing import TypedDict, cast


class WorkItem(TypedDict):
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
    async def list(self, *, after: int = 0, limit: int = 50) -> list[WorkItem]:
        return cast(list[WorkItem], await host("work.list", {"after": after, "limit": limit}))

    async def get(self, id: int) -> WorkItem:
        return cast(WorkItem, await host("work.get", {"id": id}))

    async def create(self, title: str, *, notes: str = "", parent: int | None = None) -> WorkItem:
        return cast(WorkItem, await host("work.create", {"title": title, "notes": notes, "parent": parent}))

    async def update(self, id: int, *, revision: int, **changes: object) -> WorkItem:
        allowed = {"title", "notes", "status", "session", "run"}
        if changes.keys() - allowed:
            raise ValueError("unknown work fields: " + repr(changes.keys() - allowed))
        return cast(WorkItem, await host("work.update", {"id": id, "revision": revision, **changes}))


def setup(api: PythonApi) -> dict[str, object]:
    global host
    host = api.host
    return {"work": Work(), "WorkError": api.HostError}
