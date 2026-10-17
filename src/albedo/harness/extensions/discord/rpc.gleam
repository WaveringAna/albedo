//// The session's `discord` binding: it acts only through its own bot, DMs
//// only the owner and allowed people, and reads or writes only channels the
//// bot sees. Channels and messages are named as `refs` numbers them (a
//// snowflake is still accepted); no answer carries a snowflake.

import albedo/daemon/http_api as api
import albedo/daemon/store
import albedo/harness/extensions/discord/ingest
import albedo/harness/extensions/discord/ledger
import albedo/harness/extensions/discord/manager
import albedo/harness/extensions/discord/refs
import albedo/harness/extensions/discord/service
import albedo/harness/rpc
import gleam/dynamic
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import sqlight

type Error {
  Refused(code: String, message: String)
  Stored(ledger.Error)
}

pub fn handle(
  db: store.Store,
  session: String,
  method: String,
  args: dynamic.Dynamic,
) -> Result(json.Json, #(String, String)) {
  rpc.serve(
    method,
    args,
    fn(method, args) { dispatch(db, session, method, args) },
    describe,
  )
}

fn describe(error: Error) -> #(String, String) {
  case error {
    Refused(code, message) -> #(code, message)
    Stored(ledger.NotFound) -> #(
      "not_found",
      "this session has no discord bot; add one on the Discord page (/discord)",
    )
    Stored(ledger.Invalid(message)) -> #("invalid", message)
    Stored(ledger.Storage(message)) -> #("storage", message)
    Stored(_) -> #("conflict", "the bot changed; try again")
  }
}

fn parse(
  args: dynamic.Dynamic,
  decoder: decode.Decoder(a),
) -> Result(a, Error) {
  rpc.args(args, decoder, Refused("invalid", "invalid discord arguments"))
}

fn stored(outcome: Result(a, ledger.Error)) -> Result(a, Error) {
  result.map_error(outcome, Stored)
}

fn text(
  name: String,
  next: fn(String) -> decode.Decoder(a),
) -> decode.Decoder(a) {
  decode.field(name, decode.string, next)
}

fn optional_text(
  name: String,
  next: fn(option.Option(String)) -> decode.Decoder(a),
) -> decode.Decoder(a) {
  decode.optional_field(name, None, decode.optional(decode.string), next)
}

fn dispatch(
  db: store.Store,
  session: String,
  method: String,
  args: dynamic.Dynamic,
) -> Result(json.Json, Error) {
  use bot <- result.try(stored(ledger.for_session(db, session)))
  case method {
    "discord.send" -> {
      use #(channel, content, reply_to) <- result.try(
        parse(args, {
          use channel <- text("channel")
          use content <- text("text")
          use reply_to <- optional_text("reply_to")
          decode.success(#(channel, content, reply_to))
        }),
      )
      use channel <- result.try(visible_channel(db, bot, channel))
      use reply_to <- result.try(optional_message(db, bot, channel, reply_to))
      sent(
        db,
        bot,
        json.object([
          #("op", json.string("send")),
          #("channel_id", json.string(channel)),
          #("content", json.string(content)),
          #("reply_to", json.nullable(reply_to, json.string)),
        ]),
        content,
      )
    }
    "discord.dm" -> {
      use #(user, content) <- result.try(
        parse(args, {
          use user <- text("user")
          use content <- text("text")
          decode.success(#(user, content))
        }),
      )
      use allowed <- result.try(stored(ledger.may_dm(db, bot, user)))
      use _ <- result.try(case allowed {
        True -> Ok(Nil)
        False ->
          Error(Refused(
            "denied",
            "the bot only DMs its owner and people allowed on the Discord page",
          ))
      })
      sent(
        db,
        bot,
        json.object([
          #("op", json.string("dm")),
          #("user_id", json.string(user)),
          #("content", json.string(content)),
        ]),
        content,
      )
    }
    "discord.history" -> {
      use #(channel, limit, before) <- result.try(
        parse(args, {
          use channel <- text("channel")
          use limit <- decode.optional_field("limit", 20, decode.int)
          use before <- optional_text("before")
          decode.success(#(channel, limit, before))
        }),
      )
      use _ <- result.try(case limit >= 1 && limit <= 100 {
        True -> Ok(Nil)
        False -> Error(Refused("invalid", "limit must be 1–100"))
      })
      use channel <- result.try(visible_channel(db, bot, channel))
      use before <- result.try(optional_message(db, bot, channel, before))
      history(
        db,
        bot,
        json.object([
          #("op", json.string("history")),
          #("channel_id", json.string(channel)),
          #("limit", json.int(limit)),
          #("before", json.nullable(before, json.string)),
        ]),
      )
    }
    "discord.react" -> {
      use #(channel, message, emoji) <- result.try(
        parse(args, {
          use channel <- text("channel")
          use message <- text("message")
          use emoji <- text("emoji")
          decode.success(#(channel, message, emoji))
        }),
      )
      use channel <- result.try(visible_channel(db, bot, channel))
      use message <- result.try(message_id(db, bot, channel, message))
      relay(
        bot,
        json.object([
          #("op", json.string("react")),
          #("channel_id", json.string(channel)),
          #("message_id", json.string(message)),
          #("emoji", json.string(emoji)),
        ]),
      )
      |> result.replace(json.null())
    }
    "discord.channels" -> {
      use rows <- result.try(numbered(db, bot))
      Ok(
        json.array(rows, fn(entry) {
          let #(row, channel) = entry
          json.object([
            #("handle", json.string(refs.handle(channel.ref))),
            #("name", json.nullable(channel.name, json.string)),
            #("guild", json.nullable(channel.guild, json.string)),
            #("delivery", json.string(row.delivery)),
            #("mentions_only", json.bool(row.mentions_only)),
          ])
        }),
      )
    }
    "discord.status" -> {
      let status = manager.status(bot.id)
      let application = service.application(bot, status)
      Ok(
        json.object([
          #("name", json.string(bot.name)),
          #("state", json.string(status.state)),
          #("detail", json.nullable(status.detail, json.string)),
          #("user", json.nullable(service.user(bot, status), service.user_json)),
          #("owner", json.string(bot.owner_id)),
          #(
            "invite_url",
            json.nullable(
              option.map(application, service.invite_url),
              json.string,
            ),
          ),
        ]),
      )
    }
    _ -> Error(Refused("invalid", "unknown discord method"))
  }
}

/// The snowflake of the channel `written` names, once the session may act
/// in it.
fn visible_channel(
  db: store.Store,
  bot: ledger.Bot,
  written: String,
) -> Result(String, Error) {
  use _ <- result.try(numbered(db, bot))
  use resolved <- result.try(
    store.query(db, refs.resolve_channel(_, bot.id, written)) |> stored_text,
  )
  use channel <- result.try(case resolved {
    refs.Found(channel) -> Ok(channel)
    refs.Unknown ->
      Error(Refused(
        "not_found",
        "no channel is called "
          <> written
          <> "; discord.channels() lists the ones you can use",
      ))
    refs.Ambiguous(choices) ->
      Error(Refused(
        "invalid",
        written
          <> " could be "
          <> string.join(choices, " or ")
          <> "; write its handle, such as c1",
      ))
  })
  use visible <- result.try(stored(ledger.visible(db, bot.id, channel)))
  case visible {
    True -> Ok(channel)
    False ->
      Error(Refused(
        "denied",
        "the bot does not see "
          <> written
          <> "; turn it on in the Discord page, or use a channel a message came from",
      ))
  }
}

/// The configured channels with their handles, which numbers any that are
/// not numbered yet.
fn numbered(
  db: store.Store,
  bot: ledger.Bot,
) -> Result(List(#(ledger.Channel, refs.Channel)), Error) {
  use rows <- result.try(stored(ledger.channels(db, bot.id)))
  store.query(db, fn(connection) {
    list.try_map(rows, fn(row) {
      refs.channel(
        connection,
        bot.id,
        row.channel_id,
        row.channel_name,
        row.guild_name,
      )
      |> result.map(fn(channel) { #(row, channel) })
    })
  })
  |> stored_text
}

/// The snowflake of message `written` in `channel`: a message number, or a
/// snowflake itself.
fn message_id(
  db: store.Store,
  bot: ledger.Bot,
  channel: String,
  written: String,
) -> Result(String, Error) {
  use found <- result.try(
    store.query(db, refs.resolve_message(_, bot.id, channel, written))
    |> stored_text,
  )
  case found {
    Some(id) -> Ok(id)
    None ->
      Error(Refused(
        "not_found",
        "no message "
          <> written
          <> " in that channel; message numbers come from events, send results and history",
      ))
  }
}

fn optional_message(
  db: store.Store,
  bot: ledger.Bot,
  channel: String,
  written: Option(String),
) -> Result(Option(String), Error) {
  case written {
    Some(written) -> message_id(db, bot, channel, written) |> result.map(Some)
    None -> Ok(None)
  }
}

fn stored_text(outcome: Result(a, String)) -> Result(a, Error) {
  result.map_error(outcome, fn(message) { Stored(ledger.Storage(message)) })
}

/// The process's reply, passed through as the binding's value.
fn relay(bot: ledger.Bot, request: json.Json) -> Result(json.Json, Error) {
  use answer <- result.try(
    manager.request(bot.id, request) |> result.map_error(Refused("discord", _)),
  )
  api.json_value(answer)
  |> result.replace_error(Refused(
    "discord",
    "the bot process answered unexpectedly",
  ))
}

/// What a process reply is when it is not what the daemon asked for.
const unexpected = "the bot process answered unexpectedly"

/// Recent messages, oldest first, each with its number in the channel.
fn history(
  db: store.Store,
  bot: ledger.Bot,
  request: json.Json,
) -> Result(json.Json, Error) {
  use answer <- result.try(
    manager.request(bot.id, request) |> result.map_error(Refused("discord", _)),
  )
  use messages <- result.try(
    json.parse(answer, decode.list(ingest.decoder()))
    |> result.replace_error(Refused("discord", unexpected)),
  )
  store.query(db, fn(connection) {
    store.transaction(connection, fn() {
      list.try_map(messages, history_row(connection, bot.id, _))
    })
  })
  |> stored_text
  |> result.map(json.preprocessed_array)
}

fn history_row(
  connection: sqlight.Connection,
  bot: String,
  message: ingest.Message,
) -> Result(json.Json, String) {
  // History carries no server nicknames, so it never overwrites the name a
  // live event recorded.
  use met <- result.try(refs.message(
    connection,
    bot,
    message.channel_id,
    message.id,
    Some(message.author.id),
    None,
    ingest.excerpt(message),
  ))
  let name = option.unwrap(met.author, ingest.author_name(message))
  use reply <- result.try(case message.reply_to {
    Some(target) ->
      refs.message(
        connection,
        bot,
        message.channel_id,
        target,
        None,
        None,
        None,
      )
      |> result.map(fn(met) { Some(met.number) })
    None -> Ok(None)
  })
  Ok(
    json.object([
      #("number", json.int(met.number)),
      #("author", json.string(name)),
      #("username", json.string(message.author.username)),
      #("bot", json.bool(message.author.bot)),
      #("content", json.string(message.content)),
      #("timestamp", json.nullable(message.timestamp, json.string)),
      #("reply_to", json.nullable(reply, json.int)),
      #(
        "attachments",
        json.array(message.attachments, fn(item) {
          json.object([
            #("filename", json.string(item.filename)),
            #("url", json.string(item.url)),
          ])
        }),
      ),
    ]),
  )
}

/// A send or DM: `{messages, channel}` by number and handle, and the channel
/// joins the ones the session may act in. The first part of the text is what
/// a later reaction to the message quotes.
fn sent(
  db: store.Store,
  bot: ledger.Bot,
  request: json.Json,
  content: String,
) -> Result(json.Json, Error) {
  use answer <- result.try(
    manager.request(bot.id, request) |> result.map_error(Refused("discord", _)),
  )
  use #(ids, channel) <- result.try(
    json.parse(answer, {
      use ids <- decode.field("ids", decode.list(decode.string))
      use channel <- decode.field("channel_id", decode.string)
      decode.success(#(ids, channel))
    })
    |> result.replace_error(Refused("discord", unexpected)),
  )
  use _ <- result.try(case list.last(ids) {
    Ok(last) -> stored(ledger.note_sent(db, bot.id, channel, last))
    Error(_) -> Ok(Nil)
  })
  use #(handle, numbers) <- result.try(
    store.query(db, fn(connection) {
      store.transaction(connection, fn() {
        use handle <- result.try(
          refs.channel(connection, bot.id, channel, None, None)
          |> result.map(fn(channel) { channel.ref }),
        )
        use numbers <- result.try(
          list.index_map(ids, fn(id, index) { #(id, index) })
          |> list.try_map(fn(entry) {
            let excerpt = case entry.1 {
              0 -> ingest.preview(content)
              _ -> None
            }
            refs.message(
              connection,
              bot.id,
              channel,
              entry.0,
              bot.user_id,
              bot.username,
              excerpt,
            )
            |> result.map(fn(met) { met.number })
          }),
        )
        Ok(#(handle, numbers))
      })
    })
    |> stored_text,
  )
  Ok(
    json.object([
      #("messages", json.array(numbers, json.int)),
      #("channel", json.string(refs.handle(handle))),
    ]),
  )
}
