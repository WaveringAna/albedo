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
    """Recent vents for this workspace, newest first."""
    return cast(list[dict], await host("paperclips.list", {"limit": limit}))


def setup(api: PythonApi) -> dict[str, object]:
    global host
    host = api.host
    return {"vent": vent, "vents": vents}
