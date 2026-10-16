from __future__ import annotations

import builtins
from typing import cast
from albedo_api import Host, PythonApi, Record

host: Host


class Discord:
    async def send(
        self, channel: str, text: str, reply_to: str | None = None
    ) -> Record:
        """Post in a channel the bot sees, optionally replying to a message id.
        Text past 2000 characters is split; returns Record(ids, channel)."""
        value = cast(
            dict,
            await host(
                "discord.send",
                {"channel": channel, "text": text, "reply_to": reply_to},
            ),
        )
        return Record(value)

    async def dm(self, user: str, text: str) -> Record:
        """DM the bot's owner or an allowed person; returns Record(ids, channel)."""
        return Record(
            cast(dict, await host("discord.dm", {"user": user, "text": text}))
        )

    async def history(
        self, channel: str, limit: int = 20, before: str | None = None
    ) -> builtins.list[Record]:
        """Recent messages in a channel the bot sees, oldest first."""
        items = await host(
            "discord.history",
            {"channel": channel, "limit": limit, "before": before},
        )
        return [Record(item) for item in cast(builtins.list[dict], items)]

    async def react(self, channel: str, message: str, emoji: str) -> None:
        """Add a reaction (a unicode emoji, or name:id for a custom one)."""
        await host(
            "discord.react", {"channel": channel, "message": message, "emoji": emoji}
        )

    async def channels(self) -> builtins.list[Record]:
        """Channels the bot sees: id, name, guild, delivery, mentions_only."""
        items = await host("discord.channels", {})
        return [Record(item) for item in cast(builtins.list[dict], items)]

    async def status(self) -> Record:
        """The bot's name, state, detail, user, owner and invite_url."""
        return Record(cast(dict, await host("discord.status", {})))


def setup(api: PythonApi) -> dict[str, object]:
    global host
    host = api.host
    return {"discord": Discord(), "DiscordError": api.HostError}
