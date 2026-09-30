from __future__ import annotations

from typing import cast

from albedo_api import Host, PythonApi

host: Host


async def vent(topic: str, message: str, suggestion: str = "", title: str = "") -> dict:
    """Record one complaint for the user to review in /paperclips."""
    return cast(
        dict,
        await host(
            "paperclips.vent",
            {
                "topic": topic,
                "message": message,
                "suggestion": suggestion,
                "title": title,
            },
        ),
    )


async def vents(limit: int = 20) -> list[dict]:
    """Recent vents from every session, newest first."""
    return cast(list[dict], await host("paperclips.list", {"limit": limit}))


async def resolve_vent(id: int, note: str) -> dict:
    """Close an open or acknowledged vent your change fixed; `note` says what
    fixed it, and the user sees it on the vent."""
    return cast(dict, await host("paperclips.resolve", {"id": id, "note": note}))


def setup(api: PythonApi) -> dict[str, object]:
    global host
    host = api.host
    return {"vent": vent, "vents": vents, "resolve_vent": resolve_vent}
