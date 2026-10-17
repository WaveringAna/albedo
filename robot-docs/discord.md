# discord

The `discord` extension gives a session its own Discord bot. Messages the bot may see reach the session through the daemon's event inbox (the same durable `mail` table and dispatcher webhooks use), and the session answers through the `discord` binding in its kernel. The extension is installed but **disabled by default**; enable it globally in `/extensions` to run bots and mount its HTTP service. A bot whose extension is off globally does not connect and reports state `disabled`.

## Setup

1. In the Discord developer portal, create an application, open **Bot**, press **Reset Token** and copy the token. On the same page enable the **Message Content** intent; without it the gateway closes with 4014 and the bot fails with that reason.
2. Open the Discord page (`/discord`), press `ctrl+o`, and give the bot a name (1–64 characters), the session it belongs to (one bot per session), the token, and your own Discord user ID. To copy your ID, turn on Settings → Advanced → Developer Mode, then right-click yourself → Copy User ID. You, the owner, can always DM the bot.
3. Invite the bot with the page's invite URL (`ctrl+l` copies it): `https://discord.com/oauth2/authorize?client_id=<application_id>&scope=bot&permissions=274878024768`, which grants View Channel, Send Messages, Embed Links, Attach Files, Read Message History, Add Reactions and Send Messages in Threads. Before the bot's first READY, the application id is read from the token's first segment.
4. On the bot's Channels pane, choose what each channel delivers. Channels start **off**.

The token never leaves the daemon except into the bot process's environment. Listings and the kernel never include it.

## Channels and delivery

A `discord_channels` row means the bot sees that channel; no row means off. Each row sets a delivery:

- `turn` (end of turn): a message waits for a running turn to end, then everything that waited starts the next turn together. An idle session starts a turn at once.
- `tool` (after tool call): a message steers a running turn after its current tool call, or starts a turn when idle.

`mentions_only` delivers only messages that mention the bot user (`@everyone` does not count). Threads follow their parent channel's row. DMs are always delivered after the current tool call.

Other bots' messages are delivered like anyone's: other people's albedos live in these channels. There are no cooldowns. The bot's own messages are never delivered.

## DM whitelist

The owner and the people on the bot's allowed list may DM it. A DM from anyone else stores no letter; it creates or updates a **request** (username, a 200-character preview, last time, count; at most 50 per bot, oldest dropped). The DMs pane lists the owner, the allowed people, and the requests; allowing a request (`PUT .../dms/{user_id}`) removes it, and when no name is given and the bot is online the daemon looks the person's display name up. The owner cannot be removed.

## Ingest rules

For every message the bot process reports, in one store transaction:

1. The channel's cursor (newest message id seen, compared as integers) moves forward, for configured guild channels and their threads and for whitelisted DM channels.
2. A message from the bot user is ignored.
3. A DM from the owner or an allowed person becomes an `Event(AfterTool)` letter; any other DM becomes a request.
4. A guild message uses the row for its channel, else for its parent channel. Without one it is ignored. With `mentions_only` and no mention of the bot it is ignored. Otherwise it becomes `Event(AfterTool)` for `tool` and `Event(AfterTurn)` for `turn`.
5. The channel and the message are numbered (below). The letter id is `discord-<bot id>-<message id>`; a message whose letter exists already (a catch-up replay) stores nothing. Sender name is `discord`.

The letter body, which mail wraps as `<event id="…" from="discord">`:

```
[discord #<channel> in <server> · c<N>] @<username> (<nick or global name>, bot) · message <number>[ · reply to <number>]
<content, or "(no text)">
attachment: <filename> <url>
```

DMs start with `[discord dm · c<N>] @<username> (<global name>)`. The parenthesis is left out when there is no display name and says `bot` only for bots. A channel whose name is not known is `a channel`. Content past 16,384 characters is cut. Attachment URLs are the CDN links; no jump link or snowflake appears anywhere in the body.

## Handles and numbers

The session never handles a snowflake. A channel the bot sees is numbered `c1`, `c2`, … in the order the daemon first met it (`discord_channel_refs`, per bot), and every message the daemon delivers, sends, reads with `history`, or sees reacted to is numbered 1, 2, … within its channel, in the order it was first met (`discord_message_refs`, per bot, with the author, their name and the first 80 characters of the text, for reactions to quote). Both tables belong to the bot and go with it; a number means the same after a restart. Numbers follow first sight, not time: older messages read later with `history` get larger numbers than newer ones already met.

Wherever the binding takes a channel it accepts the handle (`c3`), the name (`general`, `#general`, `Server/general` when two servers share one), or a snowflake; `Server/general` and the name are matched against channels the daemon has numbered, which includes every configured channel. A name two channels share fails and lists their handles. Wherever it takes a message it accepts the number (`413`, `#413`) or a snowflake. A number the channel does not have fails with `not_found`. `send`, `history` and `react` still work only where the bot sees (below).

## Incoming reactions

Reaction additions arrive as inbox events naming who reacted, the emoji, and the message:

```
[discord reaction #<channel> in <server> · c<N>] @<username> (<nick or global name>) reacted <emoji> to your message <number>: "<start of its text>"
```

`your message` is a message the bot wrote; for another author it is `<name>'s message`, and when the daemon never recorded the author it is `message`. The quoted text is what the daemon recorded when it met the message (delivered, sent or read through `history`); a message it never met has no quote. DMs are `[discord dm reaction · c<N>]`. The bot's own reactions are ignored. In DMs, only the owner and allowed users reach the session; refused reactions do not create DM requests. Configured channels and their threads use the same delivery setting as messages. In a mentions-only channel, a reaction reaches the session only when its target was written by the bot or was already delivered to this session.

Reactions do not advance message cursors. Their letter IDs include the Gateway session ID and dispatch sequence, so a replay during RESUME does not deliver twice. No message text is fetched for a reaction; the session uses the recorded quote, its conversation, or `discord.history()` for context. Reaction removals and additions missed while the bot process was stopped are not backfilled.

## Kernel binding

`discord` acts only through the session's own bot; failures raise `DiscordError`.

- `await discord.send(channel, text, reply_to=None)` → `Record(messages, channel)`: the numbers of the messages posted and the channel's handle. Text over 2,000 characters is split on lines; only the first part replies, and a later reaction quotes the start of the first part. Mentions never ping `@everyone` or roles.
- `await discord.dm(user, text)` → `Record(messages, channel)`, only to the owner or an allowed person.
- `await discord.history(channel, limit=20, before=None)` → `Record(number, author, username, bot, content, timestamp, reply_to, attachments)` per message, oldest first; `author` is the name they go by there, `reply_to` a number.
- `await discord.react(channel, message, emoji)`.
- `await discord.channels()` → `Record(handle, name, guild, delivery, mentions_only)` per configured channel.
- `await discord.status()` → `Record(name, state, detail, user, owner, invite_url)`.

`send`, `history` and `react` work in configured channels and in channels the bot has delivered or sent a message in (threads under configured channels, whitelisted DMs). Channel messages are conversation, not instructions from the user.

## Bot process

`src/albedo/harness/extensions/discord/manager.gleam` owns the bot processes. The extension's initialiser starts it once per daemon, under its own supervisor; every two seconds, and at once after an HTTP change, it rereads the bots and the global selection. Each enabled bot runs `python3 -u priv/python/albedo_discord.py` as an Erlang port (`albedo_discord.erl` owns the port, line framing and request ids) with `ALBEDO_DISCORD_TOKEN` in its environment; `ALBEDO_DISCORD_API` (default `https://discord.com/api/v10`) passes through from the daemon's environment, which tests point at a fake Discord. The process connects with intents 46593 (guilds, guild messages and reactions, direct messages and reactions, message content), heartbeats, resumes after socket loss with 1–60 s backoff, and exits on stdin EOF.

A DM reaction event names no one, so the process asks Discord who it was once and remembers the answer. Every line is one JSON object. The process sends `status` (`connecting`, `online`, `reconnecting`, with the bot `user` and `application_id`), `fatal` (then exits 2), `message` (every MESSAGE_CREATE, normalized), `reaction` (MESSAGE_REACTION_ADD with actor, their server nickname, emoji and target message IDs), and `reply`. The daemon sends requests with an integer `id`: `send`, `dm`, `history`, `react`, `guilds` (from the process's cache), `user`, and `catch_up`. A request waits at most 15 s; a process that exits fails its pending requests. After each `online` the daemon sends `catch_up` with its stored cursors, and the process replays up to 50 newer messages per channel as `backfill` messages.

## States and failures

The page and `discord.status()` show one state with a detail:

- `disabled`: the bot is disabled, or the extension is off globally.
- `connecting` / `online` / `reconnecting`: as the process reports.
- `reconnecting` with "the bot process exited …; restarting in Ns": the process died; the daemon restarts it after a doubling pause (1 s up to 60 s), reset by the next `online`.
- `failed`: a fatal close (4004 bad token, 4010–4013, 4014 Message Content intent not enabled). The daemon does not restart it until the bot's token or enabled flag changes.

READY records the bot's user id, username and application id. Deleting the bot, or its session, stops the process and removes its rows.

## HTTP

The page uses `/extensions/discord/` with the daemon token, while the extension is enabled globally: `GET`/`POST /bots`, `GET`/`PATCH`/`DELETE /bots/{id}` (PATCH carries `revision`; a stale one answers 412; DELETE takes `?revision=N`), `GET /bots/{id}/guilds` (live; 503 `bot_offline` unless online), `PUT /bots/{id}/channels/{channel_id}`, `GET /bots/{id}/dms`, `PUT`/`DELETE /bots/{id}/dms/{user_id}`, and `DELETE /bots/{id}/requests/{user_id}`. Times are unix milliseconds. [OpenAPI](../docs/openapi.yaml) has the schemas.
