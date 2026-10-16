//// The session's `discord` binding: it acts only through its own bot, DMs
//// only the owner and allowed people, and reads or writes only channels the
//// bot sees.

import albedo/daemon/http_api as api
import albedo/daemon/store
import albedo/harness/extensions/discord/ledger
import albedo/harness/extensions/discord/manager
import albedo/harness/extensions/discord/service
import albedo/harness/rpc
import gleam/dynamic
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/result

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
      use _ <- result.try(sees(db, bot, channel))
      sent(
        db,
        bot,
        json.object([
          #("op", json.string("send")),
          #("channel_id", json.string(channel)),
          #("content", json.string(content)),
          #("reply_to", json.nullable(reply_to, json.string)),
        ]),
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
      use _ <- result.try(sees(db, bot, channel))
      relay(
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
      use _ <- result.try(sees(db, bot, channel))
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
      use rows <- result.try(stored(ledger.channels(db, bot.id)))
      Ok(
        json.array(rows, fn(row) {
          json.object([
            #("id", json.string(row.channel_id)),
            #("name", json.nullable(row.channel_name, json.string)),
            #("guild", json.nullable(row.guild_name, json.string)),
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

fn sees(
  db: store.Store,
  bot: ledger.Bot,
  channel: String,
) -> Result(Nil, Error) {
  use visible <- result.try(stored(ledger.visible(db, bot.id, channel)))
  case visible {
    True -> Ok(Nil)
    False ->
      Error(Refused(
        "denied",
        "the bot does not see channel "
          <> channel
          <> "; turn it on in the Discord page, or use a channel a message came from",
      ))
  }
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

/// A send or DM: `{ids, channel}`, and the channel joins the ones the session
/// may act in.
fn sent(
  db: store.Store,
  bot: ledger.Bot,
  request: json.Json,
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
    |> result.replace_error(Refused(
      "discord",
      "the bot process answered unexpectedly",
    )),
  )
  use _ <- result.try(case list.last(ids) {
    Ok(last) -> stored(ledger.note_sent(db, bot.id, channel, last))
    Error(_) -> Ok(Nil)
  })
  Ok(
    json.object([
      #("ids", json.array(ids, json.string)),
      #("channel", json.string(channel)),
    ]),
  )
}
