from __future__ import annotations

from typing import cast
from albedo_api import Host, PythonApi, Record


class Hook(Record):
    id: str
    session: str
    name: str
    enabled: bool
    url: str
    signatureHeader: str
    signaturePrefix: str
    revision: int


host: Host


class Webhooks:
    async def list(self) -> list[Hook]:
        """Hooks targeting this session. Agent management requires human opt-in."""
        return [Hook(item) for item in cast(list[dict], await host("webhooks.list", {}))]

    async def delivery(self, id: str) -> Record:
        """Read one accepted payload for this session, even without management permission."""
        return Record(cast(dict, await host("webhooks.delivery", {"id": id})))

    async def create(self, name: str, secret: str | None = None) -> Record:
        """Create a signed endpoint; returns a generated secret when omitted."""
        value = cast(dict, await host("webhooks.create", {"name": name, "secret": secret}))
        return Record({"hook": Hook(value["hook"]), "secret": value["secret"]})

    async def rotate(self, id: str, *, revision: int, secret: str | None = None) -> Record:
        value = cast(dict, await host("webhooks.rotate", {"id": id, "revision": revision, "secret": secret}))
        return Record({"hook": Hook(value["hook"]), "secret": value["secret"]})

    async def configure(self, id: str, *, revision: int, header: str, prefix: str = "sha256=") -> Hook:
        return Hook(cast(dict, await host("webhooks.configure", {"id": id, "revision": revision, "header": header, "prefix": prefix})))

    async def enable(self, id: str, *, revision: int) -> Hook:
        return Hook(cast(dict, await host("webhooks.enable", {"id": id, "revision": revision})))

    async def disable(self, id: str, *, revision: int) -> Hook:
        return Hook(cast(dict, await host("webhooks.disable", {"id": id, "revision": revision})))

    async def delete(self, id: str, *, revision: int) -> Hook:
        return Hook(cast(dict, await host("webhooks.delete", {"id": id, "revision": revision})))


def setup(api: PythonApi) -> dict[str, object]:
    global host
    host = api.host
    return {"webhooks": Webhooks(), "WebhookError": api.HostError}
