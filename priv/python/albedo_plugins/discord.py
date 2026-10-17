from __future__ import annotations

import builtins
from typing import cast
from albedo_api import Host, PythonApi, Record

host: Host


def written(value: str | int | None) -> str | None:
    return None if value is None else str(value)


class Discord:
    async def send(
        self, channel: str, text: str, reply_to: str | int | None = None
    ) -> Record:
        """Post in a channel by handle ("c3") or name, optionally replying to a
        message number. Text past 2000 characters is split; returns
        Record(messages, channel): the numbers posted and the handle."""
        value = cast(
            dict,
            await host(
                "discord.send",
                {"channel": channel, "text": text, "reply_to": written(reply_to)},
            ),
        )
        return Record(value)

    async def dm(self, user: str, text: str) -> Record:
        """DM the bot's owner or an allowed person; returns Record(messages, channel)."""
        return Record(
            cast(dict, await host("discord.dm", {"user": user, "text": text}))
        )

    async def history(
        self, channel: str, limit: int = 20, before: str | int | None = None
    ) -> builtins.list[Record]:
        """Recent messages, oldest first: Record(number, author, username, bot,
        content, timestamp, reply_to, attachments). `before` is a number."""
        items = await host(
            "discord.history",
            {"channel": channel, "limit": limit, "before": written(before)},
        )
        return [Record(item) for item in cast(builtins.list[dict], items)]

    async def react(self, channel: str, message: str | int, emoji: str) -> None:
        """React to a message number with a unicode emoji, or name:id for a custom one."""
        await host(
            "discord.react",
            {"channel": channel, "message": str(message), "emoji": emoji},
        )

    async def channels(self) -> builtins.list[Record]:
        """Channels the bot sees: handle, name, guild, delivery, mentions_only."""
        items = await host("discord.channels", {})
        return [Record(item) for item in cast(builtins.list[dict], items)]

    async def status(self) -> Record:
        """The bot's name, state, detail, user, owner and invite_url."""
        return Record(cast(dict, await host("discord.status", {})))


def setup(api: PythonApi) -> dict[str, object]:
    global host
    host = api.host
    return {"discord": Discord(), "DiscordError": api.HostError}
