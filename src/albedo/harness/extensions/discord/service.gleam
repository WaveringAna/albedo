//// The Discord page's API under /extensions/discord/, for the human: bots,
//// the channels each one sees, and its DM whitelist and requests.

import albedo/daemon/http_api as api
import albedo/daemon/store
import albedo/harness/extension
import albedo/harness/extensions/discord/ledger
import albedo/harness/extensions/discord/manager
import albedo/harness/extensions/discord/provision
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
import gleam/string
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
    Get, ["account"] -> account_reply(db)
    Put, ["account"] -> {
      use #(token, browser) <- result.try(
        api.body(req, ["token", "browser"], {
          use token <- decode.optional_field(
            "token",
            None,
            decode.optional(api.bounded_string(512, True)),
          )
          use browser <- decode.optional_field("browser", False, decode.bool)
          decode.success(#(token, browser))
        }),
      )
      case token, browser {
        Some(token), _ -> connect_login(db, ledger.Token(string.trim(token)))
        None, True -> connect_login(db, ledger.Browser)
        None, False ->
          Error(api.invalid("a user token, or browser, is required"))
      }
    }
    Delete, ["account"] -> {
      use _ <- result.try(api.empty_body(req))
      use _ <- result.try(stored(ledger.forget_account(db)))
      account_reply(db)
    }
    Get, ["account", "guilds"] -> {
      use login <- result.try(login_of(db))
      use guilds <- result.try(
        provision.run_once(
          login,
          json.object([#("op", json.string("guilds"))]),
          decode.list({
            use id <- decode.field("id", decode.string)
            use name <- decode.optional_field("name", "", decode.string)
            use icon <- nullable("icon")
            decode.success(#(id, name, icon))
          }),
        )
        |> result.map_error(fn(failure) { login_failure(login, failure) }),
      )
      Ok(api.reply(
        200,
        json.object([
          #(
            "guilds",
            json.array(guilds, fn(guild) {
              json.object([
                #("id", json.string(guild.0)),
                #("name", json.string(guild.1)),
                #("icon", json.nullable(guild.2, json.string)),
              ])
            }),
          ),
        ]),
      ))
    }
    Post, ["provisions"] -> {
      use #(session, name, guild) <- result.try(
        api.body(req, ["session_id", "name", "guild_id"], {
          use session <- decode.field(
            "session_id",
            api.bounded_string(256, True),
          )
          use name <- decode.field("name", api.bounded_string(64, True))
          use guild <- nullable("guild_id")
          decode.success(#(session, name, guild))
        }),
      )
      // Discord refuses such an application only after the request is sent.
      use _ <- result.try(
        case string.contains(string.lowercase(name), "discord") {
          True ->
            Error(api.invalid("Discord refuses names that contain \"discord\""))
          False -> Ok(Nil)
        },
      )
      use exists <- result.try(stored(ledger.session_exists(db, session)))
      use _ <- result.try(case exists {
        True -> Ok(Nil)
        False -> Error(failure(ledger.SessionNotFound))
      })
      use _ <- result.try(case ledger.for_session(db, session) {
        Ok(_) -> Error(failure(ledger.Exists))
        Error(_) -> Ok(Nil)
      })
      use login <- result.try(login_of(db))
      use account <- result.try(stored(ledger.account(db)))
      use owner <- result.try(option.to_result(account, no_account()))
      use started <- result.try(
        provision.begin(provision.Request(
          session,
          name,
          guild,
          login,
          owner.user_id,
        ))
        |> result.map_error(provision_failure),
      )
      Ok(api.reply(202, provision_json(db, started)))
    }
    Get, ["provisions", id] -> provision_reply(db, provision.get(id))
    Post, ["provisions", id, "mfa"] -> {
      use code <- result.try(api.body(
        req,
        ["code"],
        decode.field("code", api.bounded_string(64, True), decode.success),
      ))
      provision_reply(db, provision.mfa(id, string.trim(code)))
    }
    Delete, ["provisions", id] -> {
      use _ <- result.try(api.empty_body(req))
      provision_reply(db, provision.cancel(id))
    }
    _, ["bots"]
    | _, ["account"]
    | _, ["account", "guilds"]
    | _, ["provisions"]
    | _, ["provisions", _]
    | _, ["provisions", _, "mfa"]
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

fn no_account() -> api.Failure {
  api.Failure(
    412,
    "no_account",
    "connect your Discord account on the Discord page first",
  )
}

fn login_of(db: store.Store) -> Result(ledger.Login, api.Failure) {
  use login <- result.try(stored(ledger.login(db)))
  option.to_result(login, no_account())
}

/// Checks the login with Discord once, then stores it: a pasted token, or the
/// Chrome window a person signs in to.
fn connect_login(
  db: store.Store,
  login: ledger.Login,
) -> Result(response.Response(mist.ResponseData), api.Failure) {
  use me <- result.try(
    provision.run_once(login, json.object([#("op", json.string("me"))]), {
      use id <- decode.field("id", decode.string)
      use username <- decode.optional_field(
        "username",
        None,
        decode.optional(decode.string),
      )
      decode.success(ledger.Account(id, option.unwrap(username, "")))
    })
    |> result.map_error(fn(failure) { login_failure(login, failure) }),
  )
  use _ <- result.try(stored(ledger.connect_account(db, login, me)))
  account_reply(db)
}

fn account_reply(
  db: store.Store,
) -> Result(response.Response(mist.ResponseData), api.Failure) {
  use account <- result.try(stored(ledger.account(db)))
  Ok(api.reply(
    200,
    json.object([
      #("connected", json.bool(option.is_some(account))),
      #(
        "user",
        json.nullable(account, fn(account) {
          user_json(manager.User(account.user_id, account.username))
        }),
      ),
    ]),
  ))
}

/// A provisioner failure on the account routes. The provisioner names what is
/// wrong with the login itself, so its message is what the user reads.
fn login_failure(
  login: ledger.Login,
  failure: #(String, String),
) -> api.Failure {
  case failure {
    #("unauthorized", detail) ->
      case login {
        ledger.Token(_) -> api.Failure(400, "invalid_token", detail)
        ledger.Browser -> api.Failure(400, "not_signed_in", detail)
      }
    #(_, detail) -> api.Failure(503, "discord_unavailable", detail)
  }
}

fn provision_failure(failure: provision.Failure) -> api.Failure {
  case failure {
    provision.NotFound ->
      api.Failure(404, "not_found", "provision not found or expired")
    provision.NotWaiting ->
      api.Failure(409, "not_waiting", "the provision is not waiting for a code")
    provision.Unavailable ->
      api.Failure(503, "daemon_unavailable", "provisioning is not running")
  }
}

fn provision_reply(
  db: store.Store,
  outcome: Result(provision.Provision, provision.Failure),
) -> Result(response.Response(mist.ResponseData), api.Failure) {
  use found <- result.try(outcome |> result.map_error(provision_failure))
  Ok(api.reply(200, provision_json(db, found)))
}

fn provision_json(db: store.Store, item: provision.Provision) -> json.Json {
  let bot =
    option.to_result(item.bot, Nil)
    |> result.try(fn(id) {
      ledger.overview(db, id) |> result.replace_error(Nil)
    })
    |> option.from_result
  json.object([
    #("id", json.string(item.id)),
    #("session_id", json.string(item.session)),
    #("name", json.string(item.name)),
    #("state", json.string(item.state)),
    #("step", json.nullable(item.step, json.string)),
    #("methods", json.array(item.methods, json.string)),
    #("mfa_error", json.nullable(item.mfa_error, json.string)),
    #("error", json.nullable(item.error, json.string)),
    #("code", json.nullable(item.code, json.string)),
    #(
      "bot",
      json.nullable(bot, fn(overview) {
        bot_json(overview, manager.status(overview.bot.id))
      }),
    ),
    #("portal_url", json.string(provision.portal_url)),
  ])
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
