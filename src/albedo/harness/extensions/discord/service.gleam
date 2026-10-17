//// The Discord page's API under /extensions/discord/, for the human: bots,
//// the channels each one sees, and its DM whitelist and requests.

import albedo/daemon/http_api as api
import albedo/daemon/store
import albedo/harness/extension
import albedo/harness/extensions/discord/ledger
import albedo/harness/extensions/discord/manager
import gleam/dict
import gleam/dynamic/decode
import gleam/http.{type Method, Delete, Get, Patch, Post, Put}
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import mist

pub fn admission(_path: List(String), _method: Method) -> extension.Admission {
  extension.Admission(extension.DaemonToken, 16_384)
}

pub fn handle(
  daemon: extension.Daemon,
  path: List(String),
  req: request.Request(BitArray),
  _live: request.Request(mist.Connection),
) -> response.Response(mist.ResponseData) {
  case dispatch(daemon.ledger, path, req) {
    Ok(reply) -> reply
    Error(error) -> api.fail(error)
  }
}

pub fn failure(error: ledger.Error) -> api.Failure {
  case error {
    ledger.Invalid(detail) -> api.invalid(detail)
    ledger.NotFound -> api.Failure(404, "not_found", "discord bot not found")
    ledger.SessionNotFound -> api.Failure(404, "not_found", "session not found")
    ledger.Exists ->
      api.Failure(409, "bot_exists", "this session already has a discord bot")
    ledger.Conflict ->
      api.Failure(412, "precondition_failed", "the bot changed; reload it")
    ledger.Storage(detail) -> api.Failure(503, "storage_failed", detail)
  }
}

fn offline(detail: String) -> api.Failure {
  api.Failure(503, "bot_offline", detail)
}

fn stored(outcome: Result(a, ledger.Error)) -> Result(a, api.Failure) {
  result.map_error(outcome, failure)
}

fn dispatch(
  db: store.Store,
  path: List(String),
  req: request.Request(BitArray),
) -> Result(response.Response(mist.ResponseData), api.Failure) {
  use _ <- result.try(api.accepts_json(req))
  use query <- result.try(
    api.parameters(req, case req.method, path {
      Delete, ["bots", _] -> ["revision"]
      _, _ -> []
    }),
  )
  case req.method, path {
    Get, ["bots"] -> {
      use found <- result.try(stored(ledger.list_all(db)))
      let statuses = manager.statuses()
      Ok(api.reply(
        200,
        json.object([
          #(
            "items",
            json.array(found, fn(item) {
              bot_json(
                item,
                dict.get(statuses, item.bot.id)
                  |> result.unwrap(manager.unknown()),
              )
            }),
          ),
        ]),
      ))
    }
    Post, ["bots"] -> {
      use #(session, name, token, owner) <- result.try(
        api.body(req, ["session_id", "name", "token", "owner_id"], {
          use session <- decode.field(
            "session_id",
            api.bounded_string(256, True),
          )
          use name <- decode.field("name", decode.string)
          use token <- decode.field("token", decode.string)
          use owner <- decode.field("owner_id", decode.string)
          decode.success(#(session, name, token, owner))
        }),
      )
      use bot <- result.try(
        stored(ledger.create(db, session, name, token, owner)),
      )
      manager.reconcile()
      manager.changed(bot.id)
      use reply <- result.try(bot_reply(db, bot.id, 201))
      Ok(response.set_header(
        reply,
        "location",
        "/extensions/discord/bots/" <> bot.id,
      ))
    }
    Get, ["bots", id] -> bot_reply(db, id, 200)
    Patch, ["bots", id] -> {
      use #(revision, patch) <- result.try(
        api.body(req, ["revision", "name", "token", "owner_id", "enabled"], {
          use revision <- decode.field("revision", decode.int)
          use name <- optional("name", decode.string)
          use token <- optional("token", decode.string)
          use owner <- optional("owner_id", decode.string)
          use enabled <- optional("enabled", decode.bool)
          decode.success(#(revision, ledger.Patch(name, token, owner, enabled)))
        }),
      )
      use bot <- result.try(stored(ledger.patch(db, id, revision, patch)))
      manager.reconcile()
      manager.changed(bot.id)
      bot_reply(db, id, 200)
    }
    Delete, ["bots", id] -> {
      use _ <- result.try(api.empty_body(req))
      use revision <- result.try(
        list.key_find(query, "revision")
        |> result.try(int.parse)
        |> result.replace_error(api.invalid(
          "revision query parameter is required",
        )),
      )
      use _ <- result.try(stored(ledger.delete(db, id, revision)))
      manager.reconcile()
      manager.changed(id)
      Ok(api.reply(200, json.object([#("deleted", json.string(id))])))
    }
    Get, ["bots", id, "guilds"] -> {
      use _ <- result.try(stored(ledger.find(db, id)))
      use channels <- result.try(stored(ledger.channels(db, id)))
      use answer <- result.try(
        manager.request(id, json.object([#("op", json.string("guilds"))]))
        |> result.map_error(offline),
      )
      use guilds <- result.try(
        json.parse(answer, decode.list(guild_decoder()))
        |> result.replace_error(offline("the bot process answered unexpectedly")),
      )
      Ok(api.reply(
        200,
        json.object([
          #("guilds", json.array(guilds, guild_json(_, channels))),
        ]),
      ))
    }
    Put, ["bots", id, "channels", channel] -> {
      use row <- result.try(
        api.body(
          req,
          [
            "delivery",
            "mentions_only",
            "guild_id",
            "guild_name",
            "channel_name",
          ],
          {
            use delivery <- decode.field("delivery", decode.string)
            use mentions_only <- decode.optional_field(
              "mentions_only",
              False,
              decode.bool,
            )
            use guild <- nullable("guild_id")
            use guild_name <- nullable("guild_name")
            use channel_name <- nullable("channel_name")
            decode.success(ledger.Channel(
              channel,
              guild,
              guild_name,
              channel_name,
              delivery,
              mentions_only,
            ))
          },
        ),
      )
      use _ <- result.try(stored(ledger.set_channel(db, id, row)))
      manager.changed(id)
      Ok(api.reply(
        200,
        json.object([
          #("channel_id", json.string(channel)),
          #("delivery", json.string(row.delivery)),
          #(
            "mentions_only",
            json.bool(row.delivery != "off" && row.mentions_only),
          ),
        ]),
      ))
    }
    Get, ["bots", id, "dms"] -> {
      use bot <- result.try(stored(ledger.find(db, id)))
      use allowed <- result.try(stored(ledger.allowed(db, id)))
      use requests <- result.try(stored(ledger.requests(db, id)))
      Ok(api.reply(
        200,
        json.object([
          #(
            "owner",
            json.object([
              #("user_id", json.string(bot.owner_id)),
              #("name", json.null()),
            ]),
          ),
          #("allowed", json.array(allowed, allowed_json)),
          #(
            "requests",
            json.array(requests, fn(item) {
              json.object([
                #("user_id", json.string(item.user_id)),
                #("username", json.string(item.username)),
                #("preview", json.string(item.preview)),
                #("last_at", json.int(item.last_at)),
                #("count", json.int(item.count)),
              ])
            }),
          ),
        ]),
      ))
    }
    Put, ["bots", id, "dms", user] -> {
      use name <- result.try(api.body(
        req,
        ["name"],
        nullable("name", decode.success),
      ))
      use _ <- result.try(stored(ledger.find(db, id)))
      let name = case name {
        Some(_) -> name
        None -> resolve_name(id, user)
      }
      use allowed <- result.try(stored(ledger.allow(db, id, user, name)))
      manager.changed(id)
      Ok(api.reply(200, allowed_json(allowed)))
    }
    Delete, ["bots", id, "dms", user] -> {
      use _ <- result.try(api.empty_body(req))
      use bot <- result.try(stored(ledger.find(db, id)))
      use _ <- result.try(case user == bot.owner_id {
        True -> Error(api.invalid("the owner can always DM the bot"))
        False -> Ok(Nil)
      })
      use _ <- result.try(stored(ledger.disallow(db, id, user)))
      manager.changed(id)
      Ok(api.reply(200, json.object([#("deleted", json.string(user))])))
    }
    Delete, ["bots", id, "requests", user] -> {
      use _ <- result.try(api.empty_body(req))
      use _ <- result.try(stored(ledger.dismiss(db, id, user)))
      manager.changed(id)
      Ok(api.reply(200, json.object([#("deleted", json.string(user))])))
    }
    _, ["bots"]
    | _, ["bots", _]
    | _, ["bots", _, "guilds"]
    | _, ["bots", _, "channels", _]
    | _, ["bots", _, "dms"]
    | _, ["bots", _, "dms", _]
    | _, ["bots", _, "requests", _]
    ->
      Error(api.Failure(
        405,
        "method_not_allowed",
        "method not allowed for discord resource",
      ))
    _, _ -> Error(api.Failure(404, "not_found", "discord route not found"))
  }
}

fn optional(
  name: String,
  decoder: decode.Decoder(a),
  next: fn(Option(a)) -> decode.Decoder(b),
) -> decode.Decoder(b) {
  decode.optional_field(name, None, decode.map(decoder, Some), next)
}

fn nullable(
  name: String,
  next: fn(Option(String)) -> decode.Decoder(b),
) -> decode.Decoder(b) {
  decode.optional_field(name, None, decode.optional(decode.string), next)
}

/// The person's Discord display name, when the bot can ask for it.
fn resolve_name(bot: String, user: String) -> Option(String) {
  manager.request(
    bot,
    json.object([#("op", json.string("user")), #("user_id", json.string(user))]),
  )
  |> result.try(fn(answer) {
    json.parse(answer, {
      use username <- decode.optional_field(
        "username",
        None,
        decode.optional(decode.string),
      )
      use global <- decode.optional_field(
        "global_name",
        None,
        decode.optional(decode.string),
      )
      decode.success(option.or(global, username))
    })
    |> result.replace_error("")
  })
  |> result.unwrap(None)
}

fn bot_reply(
  db: store.Store,
  id: String,
  status: Int,
) -> Result(response.Response(mist.ResponseData), api.Failure) {
  use item <- result.try(stored(ledger.overview(db, id)))
  Ok(api.reply(status, bot_json(item, manager.status(id))))
}

pub fn invite_url(application: String) -> String {
  "https://discord.com/oauth2/authorize?client_id="
  <> application
  <> "&scope=bot&permissions=274878024768"
}

/// The bot user, live from the process or as READY last recorded it.
pub fn user(bot: ledger.Bot, status: manager.Status) -> Option(manager.User) {
  case status.user, bot.user_id {
    Some(user), _ -> Some(user)
    None, Some(id) -> Some(manager.User(id, option.unwrap(bot.username, "")))
    None, None -> None
  }
}

pub fn application(bot: ledger.Bot, status: manager.Status) -> Option(String) {
  option.or(status.application_id, bot.application_id)
}

fn bot_json(item: ledger.Overview, status: manager.Status) -> json.Json {
  let bot = item.bot
  let application = application(bot, status)
  json.object([
    #("id", json.string(bot.id)),
    #("session_id", json.string(bot.session)),
    #("name", json.string(bot.name)),
    #("owner_id", json.string(bot.owner_id)),
    #("enabled", json.bool(bot.enabled)),
    #("revision", json.int(bot.revision)),
    #("state", json.string(status.state)),
    #("detail", json.nullable(status.detail, json.string)),
    #("user", json.nullable(user(bot, status), user_json)),
    #("application_id", json.nullable(application, json.string)),
    #(
      "invite_url",
      json.nullable(option.map(application, invite_url), json.string),
    ),
    #("channels", json.int(item.channels)),
    #("allowed", json.int(item.allowed)),
    #("requests", json.int(item.requests)),
  ])
}

pub fn user_json(user: manager.User) -> json.Json {
  json.object([
    #("id", json.string(user.id)),
    #("username", json.string(user.username)),
  ])
}

fn allowed_json(item: ledger.Allowed) -> json.Json {
  json.object([
    #("user_id", json.string(item.user_id)),
    #("name", json.nullable(item.name, json.string)),
    #("added_at", json.int(item.added_at)),
  ])
}

type Listed {
  Listed(
    id: String,
    name: String,
    kind: Int,
    parent_id: Option(String),
    position: Int,
  )
}

type Guild {
  Guild(id: String, name: String, channels: List(Listed))
}

fn guild_decoder() -> decode.Decoder(Guild) {
  use id <- decode.field("id", decode.string)
  use name <- decode.optional_field("name", "", decode.string)
  use channels <- decode.optional_field(
    "channels",
    [],
    decode.list({
      use id <- decode.field("id", decode.string)
      use name <- decode.optional_field("name", "", decode.string)
      use kind <- decode.optional_field("type", 0, decode.int)
      use parent <- nullable("parent_id")
      use position <- decode.optional_field("position", 0, decode.int)
      decode.success(Listed(id, name, kind, parent, position))
    }),
  )
  decode.success(Guild(id, name, channels))
}

fn guild_json(guild: Guild, rows: List(ledger.Channel)) -> json.Json {
  json.object([
    #("id", json.string(guild.id)),
    #("name", json.string(guild.name)),
    #(
      "channels",
      json.array(guild.channels, fn(channel) {
        let row = list.find(rows, fn(row) { row.channel_id == channel.id })
        json.object([
          #("id", json.string(channel.id)),
          #("name", json.string(channel.name)),
          #("type", json.int(channel.kind)),
          #("parent_id", json.nullable(channel.parent_id, json.string)),
          #("position", json.int(channel.position)),
          #(
            "delivery",
            json.string(case row {
              Ok(row) -> row.delivery
              Error(_) -> "off"
            }),
          ),
          #(
            "mentions_only",
            json.bool(case row {
              Ok(row) -> row.mentions_only
              Error(_) -> False
            }),
          ),
        ])
      }),
    ),
  ])
}
