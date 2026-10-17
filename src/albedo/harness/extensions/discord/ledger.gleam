//// Durable Discord bots: one per session, the channels each one sees, the
//// people allowed to DM it, refused DMs, and the newest message seen in each
//// channel. Tokens leave this module only through `runnable`, for the bot
//// process environment.

import albedo/daemon/mail
import albedo/daemon/store
import albedo/daemon/usage
import albedo/text_scalars
import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import sqlight

pub type Bot {
  Bot(
    id: String,
    session: String,
    name: String,
    owner_id: String,
    enabled: Bool,
    /// From READY, or before that the bot user id the token carries.
    application_id: Option(String),
    user_id: Option(String),
    username: Option(String),
    revision: Int,
  )
}

pub type Overview {
  Overview(bot: Bot, channels: Int, allowed: Int, requests: Int)
}

/// What the manager needs to run a bot.
pub type Runnable {
  Runnable(id: String, token: String, enabled: Bool)
}

pub type Channel {
  Channel(
    channel_id: String,
    guild_id: Option(String),
    guild_name: Option(String),
    channel_name: Option(String),
    delivery: String,
    mentions_only: Bool,
  )
}

pub type Allowed {
  Allowed(user_id: String, name: Option(String), added_at: Int)
}

pub type Request {
  Request(
    user_id: String,
    username: String,
    preview: String,
    last_at: Int,
    count: Int,
  )
}

/// Changes a PATCH asks for; None keeps the stored value.
pub type Patch {
  Patch(
    name: Option(String),
    token: Option(String),
    owner_id: Option(String),
    enabled: Option(Bool),
  )
}

/// The human's own Discord login, used only to provision bots. Its token
/// stays in this table and in the provisioner's environment.
pub type Account {
  Account(user_id: String, username: String)
}

/// How the daemon reaches Discord as that human. A pasted user token is one
/// way; signing in to the Chrome window browser mode opens is another, and the
/// one Discord's captcha reacts to less. Both are against Discord's terms.
pub type Login {
  Token(token: String)
  Browser
}

pub type Error {
  Invalid(String)
  NotFound
  SessionNotFound
  Exists
  Conflict
  Storage(String)
}

const schema =
  "
CREATE TABLE IF NOT EXISTS discord_bots (
 id TEXT PRIMARY KEY,
 session TEXT NOT NULL UNIQUE REFERENCES sessions(id) ON DELETE CASCADE,
 name TEXT NOT NULL,
 token TEXT NOT NULL,
 owner_id TEXT NOT NULL,
 enabled INTEGER NOT NULL DEFAULT 1 CHECK(enabled IN (0,1)),
 application_id TEXT,
 user_id TEXT,
 username TEXT,
 revision INTEGER NOT NULL DEFAULT 1,
 created_at INTEGER
);
CREATE TABLE IF NOT EXISTS discord_channels (
 bot TEXT NOT NULL REFERENCES discord_bots(id) ON DELETE CASCADE,
 channel_id TEXT NOT NULL,
 guild_id TEXT,
 guild_name TEXT,
 channel_name TEXT,
 delivery TEXT NOT NULL CHECK(delivery IN ('turn','tool')),
 mentions_only INTEGER NOT NULL DEFAULT 0 CHECK(mentions_only IN (0,1)),
 PRIMARY KEY(bot,channel_id)
);
CREATE TABLE IF NOT EXISTS discord_allowed (
 bot TEXT NOT NULL REFERENCES discord_bots(id) ON DELETE CASCADE,
 user_id TEXT NOT NULL,
 name TEXT,
 added_at INTEGER NOT NULL,
 PRIMARY KEY(bot,user_id)
);
CREATE TABLE IF NOT EXISTS discord_requests (
 bot TEXT NOT NULL REFERENCES discord_bots(id) ON DELETE CASCADE,
 user_id TEXT NOT NULL,
 username TEXT NOT NULL,
 preview TEXT NOT NULL,
 last_at INTEGER NOT NULL,
 count INTEGER NOT NULL DEFAULT 1,
 PRIMARY KEY(bot,user_id)
);
CREATE TABLE IF NOT EXISTS discord_account (
 id INTEGER PRIMARY KEY CHECK(id=1),
 token TEXT NOT NULL,
 user_id TEXT NOT NULL,
 username TEXT NOT NULL,
 browser INTEGER NOT NULL DEFAULT 0 CHECK(browser IN (0,1)),
 connected_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS discord_cursors (
 bot TEXT NOT NULL REFERENCES discord_bots(id) ON DELETE CASCADE,
 channel_id TEXT NOT NULL,
 last_seen TEXT NOT NULL,
 PRIMARY KEY(bot,channel_id)
);
"

/// Refused DMs kept per bot; the oldest go first.
const request_limit = 50

pub fn initialise(db: store.Store) -> Result(Nil, String) {
  use _ <- result.try(mail.initialise(db))
  use _ <- result.try(store.query(db, store.exec(_, schema)))
  // A store created before browser mode has no `discord_account.browser`; its
  // rows were all pasted tokens.
  store.query(db, fn(connection) {
    store.add_columns(connection, "discord_account", [
      #("browser", "INTEGER NOT NULL DEFAULT 0"),
    ])
  })
}

/// Session deletion cascades through the foreign keys; this covers a store
/// opened without them.
pub fn forget(
  connection: sqlight.Connection,
  session: String,
) -> Result(Nil, String) {
  store.forget_session(connection, ["discord_bots"], session)
}

const columns =
  "b.id,b.session,b.name,b.owner_id,b.enabled,b.application_id,b.user_id,b.username,b.revision,b.token"

fn bot_decoder() -> decode.Decoder(Bot) {
  use id <- decode.field(0, decode.string)
  use session <- decode.field(1, decode.string)
  use name <- decode.field(2, decode.string)
  use owner <- decode.field(3, decode.string)
  use enabled <- decode.field(4, decode.int)
  use application <- decode.field(5, decode.optional(decode.string))
  use user_id <- decode.field(6, decode.optional(decode.string))
  use username <- decode.field(7, decode.optional(decode.string))
  use revision <- decode.field(8, decode.int)
  use token <- decode.field(9, decode.string)
  let application = case application {
    Some(_) -> application
    None -> token_user(token) |> option.from_result
  }
  decode.success(Bot(
    id,
    session,
    name,
    owner,
    enabled == 1,
    application,
    user_id,
    username,
    revision,
  ))
}

fn query(
  connection: sqlight.Connection,
  sql: String,
  args: List(sqlight.Value),
  decoder: decode.Decoder(a),
) -> Result(List(a), Error) {
  store.rows(connection, sql, args, decoder) |> result.map_error(Storage)
}

fn run(
  connection: sqlight.Connection,
  sql: String,
  args: List(sqlight.Value),
) -> Result(Nil, Error) {
  store.run(connection, sql, args) |> result.map_error(Storage)
}

fn count(
  connection: sqlight.Connection,
  sql: String,
  args: List(sqlight.Value),
) -> Result(Int, Error) {
  query(connection, sql, args, decode.field(0, decode.int, decode.success))
  |> result.map(fn(rows) { list.first(rows) |> result.unwrap(0) })
}

fn first(rows: List(a)) -> Result(a, Error) {
  list.first(rows) |> result.replace_error(NotFound)
}

const overview_columns =
  ",(SELECT count(*) FROM discord_channels c WHERE c.bot=b.id),(SELECT count(*) FROM discord_allowed a WHERE a.bot=b.id),(SELECT count(*) FROM discord_requests r WHERE r.bot=b.id)"

fn overview_decoder() -> decode.Decoder(Overview) {
  use bot <- decode.then(bot_decoder())
  use channels <- decode.field(10, decode.int)
  use allowed <- decode.field(11, decode.int)
  use requests <- decode.field(12, decode.int)
  decode.success(Overview(bot, channels, allowed, requests))
}

/// Every session's bots, for the human's Discord page.
pub fn list_all(db: store.Store) -> Result(List(Overview), Error) {
  store.query(db, query(
    _,
    "SELECT "
      <> columns
      <> overview_columns
      <> " FROM discord_bots b ORDER BY b.session,b.name",
    [],
    overview_decoder(),
  ))
}

pub fn overview(db: store.Store, id: String) -> Result(Overview, Error) {
  store.query(db, query(
    _,
    "SELECT "
      <> columns
      <> overview_columns
      <> " FROM discord_bots b WHERE b.id=?",
    [sqlight.text(id)],
    overview_decoder(),
  ))
  |> result.try(first)
}

pub fn find(db: store.Store, id: String) -> Result(Bot, Error) {
  store.query(db, find_on(_, id))
}

fn find_on(connection: sqlight.Connection, id: String) -> Result(Bot, Error) {
  query(
    connection,
    "SELECT " <> columns <> " FROM discord_bots b WHERE b.id=?",
    [sqlight.text(id)],
    bot_decoder(),
  )
  |> result.try(first)
}

/// The bot a session acts through.
pub fn for_session(db: store.Store, session: String) -> Result(Bot, Error) {
  store.query(db, query(
    _,
    "SELECT " <> columns <> " FROM discord_bots b WHERE b.session=?",
    [sqlight.text(session)],
    bot_decoder(),
  ))
  |> result.try(first)
}

pub fn runnable(db: store.Store) -> Result(List(Runnable), Error) {
  store.query(
    db,
    query(_, "SELECT id,token,enabled FROM discord_bots", [], {
      use id <- decode.field(0, decode.string)
      use token <- decode.field(1, decode.string)
      use enabled <- decode.field(2, decode.int)
      decode.success(Runnable(id, token, enabled == 1))
    }),
  )
}

pub fn create(
  db: store.Store,
  session: String,
  name: String,
  token: String,
  owner_id: String,
) -> Result(Bot, Error) {
  use _ <- result.try(validate_name(name))
  use _ <- result.try(validate_token(token))
  use _ <- result.try(validate_owner(owner_id))
  store.query(db, fn(connection) {
    use sessions <- result.try(
      count(connection, "SELECT count(*) FROM sessions WHERE id=?", [
        sqlight.text(session),
      ]),
    )
    use existing <- result.try(
      count(connection, "SELECT count(*) FROM discord_bots WHERE session=?", [
        sqlight.text(session),
      ]),
    )
    case sessions, existing {
      0, _ -> Error(SessionNotFound)
      _, 0 -> {
        let id = mail.new_id()
        use _ <- result.try(
          run(
            connection,
            "INSERT INTO discord_bots(id,session,name,token,owner_id,created_at) VALUES(?,?,?,?,?,?)",
            [
              sqlight.text(id),
              sqlight.text(session),
              sqlight.text(name),
              sqlight.text(token),
              sqlight.text(owner_id),
              sqlight.int(usage.now()),
            ],
          ),
        )
        find_on(connection, id)
      }
      _, _ -> Error(Exists)
    }
  })
}

/// One revision guards the whole edit. A new token is a new bot user, so
/// what READY recorded for the old one is cleared.
pub fn patch(
  db: store.Store,
  id: String,
  revision: Int,
  patch: Patch,
) -> Result(Bot, Error) {
  use _ <- result.try(check(patch.name, validate_name))
  use _ <- result.try(check(patch.token, validate_token))
  use _ <- result.try(check(patch.owner_id, validate_owner))
  store.query(db, fn(connection) {
    use current <- result.try(find_on(connection, id))
    use _ <- result.try(case current.revision == revision {
      True -> Ok(Nil)
      False -> Error(Conflict)
    })
    let identity = case patch.token {
      Some(_) -> ",application_id=NULL,user_id=NULL,username=NULL"
      None -> ""
    }
    use _ <- result.try(
      run(
        connection,
        "UPDATE discord_bots SET name=COALESCE(?,name),token=COALESCE(?,token),owner_id=COALESCE(?,owner_id),enabled=COALESCE(?,enabled),revision=revision+1"
          <> identity
          <> " WHERE id=? AND revision=?",
        [
          sqlight.nullable(sqlight.text, patch.name),
          sqlight.nullable(sqlight.text, patch.token),
          sqlight.nullable(sqlight.text, patch.owner_id),
          sqlight.nullable(sqlight.bool, patch.enabled),
          sqlight.text(id),
          sqlight.int(revision),
        ],
      ),
    )
    find_on(connection, id)
  })
}

fn check(
  value: Option(a),
  validate: fn(a) -> Result(Nil, Error),
) -> Result(Nil, Error) {
  case value {
    Some(value) -> validate(value)
    None -> Ok(Nil)
  }
}

pub fn delete(
  db: store.Store,
  id: String,
  revision: Int,
) -> Result(Bot, Error) {
  store.query(db, fn(connection) {
    use current <- result.try(find_on(connection, id))
    use _ <- result.try(case current.revision == revision {
      True -> Ok(Nil)
      False -> Error(Conflict)
    })
    run(connection, "DELETE FROM discord_bots WHERE id=?", [sqlight.text(id)])
    |> result.replace(current)
  })
}

/// What READY said the bot is.
pub fn record_identity(
  db: store.Store,
  id: String,
  user_id: String,
  username: String,
  application_id: Option(String),
) -> Result(Nil, Error) {
  store.query(
    db,
    run(
      _,
      "UPDATE discord_bots SET user_id=?,username=?,application_id=COALESCE(?,application_id) WHERE id=?",
      [
        sqlight.text(user_id),
        sqlight.text(username),
        sqlight.nullable(sqlight.text, application_id),
        sqlight.text(id),
      ],
    ),
  )
}

fn channel_decoder() -> decode.Decoder(Channel) {
  use channel <- decode.field(0, decode.string)
  use guild <- decode.field(1, decode.optional(decode.string))
  use guild_name <- decode.field(2, decode.optional(decode.string))
  use name <- decode.field(3, decode.optional(decode.string))
  use delivery <- decode.field(4, decode.string)
  use mentions_only <- decode.field(5, decode.int)
  decode.success(Channel(
    channel,
    guild,
    guild_name,
    name,
    delivery,
    mentions_only == 1,
  ))
}

const channel_columns =
  "channel_id,guild_id,guild_name,channel_name,delivery,mentions_only"

pub fn channels(db: store.Store, bot: String) -> Result(List(Channel), Error) {
  store.query(db, query(
    _,
    "SELECT "
      <> channel_columns
      <> " FROM discord_channels WHERE bot=? ORDER BY guild_name,channel_name,channel_id",
    [sqlight.text(bot)],
    channel_decoder(),
  ))
}

/// The row a guild message in `channel` follows: its own, else its parent's
/// (a thread follows the channel it hangs off).
pub fn channel_config(
  connection: sqlight.Connection,
  bot: String,
  channel: String,
  parent: Option(String),
) -> Result(Option(Channel), String) {
  store.rows(
    connection,
    "SELECT "
      <> channel_columns
      <> " FROM discord_channels WHERE bot=? AND channel_id IN (?,?) ORDER BY channel_id=? DESC LIMIT 1",
    [
      sqlight.text(bot),
      sqlight.text(channel),
      sqlight.text(option.unwrap(parent, channel)),
      sqlight.text(channel),
    ],
    channel_decoder(),
  )
  |> result.map(fn(rows) { list.first(rows) |> option.from_result })
}

/// "off" removes the row: no row means the bot does not see the channel.
pub fn set_channel(
  db: store.Store,
  bot: String,
  channel: Channel,
) -> Result(Nil, Error) {
  use _ <- result.try(case channel.delivery {
    "off" | "turn" | "tool" -> Ok(Nil)
    _ -> Error(Invalid("delivery must be off, turn or tool"))
  })
  use _ <- result.try(validate_snowflake(channel.channel_id, "channel id"))
  store.query(db, fn(connection) {
    use _ <- result.try(find_on(connection, bot))
    case channel.delivery {
      "off" ->
        run(
          connection,
          "DELETE FROM discord_channels WHERE bot=? AND channel_id=?",
          [sqlight.text(bot), sqlight.text(channel.channel_id)],
        )
      _ ->
        run(
          connection,
          "INSERT INTO discord_channels(bot,channel_id,guild_id,guild_name,channel_name,delivery,mentions_only) VALUES(?,?,?,?,?,?,?) ON CONFLICT(bot,channel_id) DO UPDATE SET guild_id=COALESCE(excluded.guild_id,guild_id),guild_name=COALESCE(excluded.guild_name,guild_name),channel_name=COALESCE(excluded.channel_name,channel_name),delivery=excluded.delivery,mentions_only=excluded.mentions_only",
          [
            sqlight.text(bot),
            sqlight.text(channel.channel_id),
            sqlight.nullable(sqlight.text, channel.guild_id),
            sqlight.nullable(sqlight.text, channel.guild_name),
            sqlight.nullable(sqlight.text, channel.channel_name),
            sqlight.text(channel.delivery),
            sqlight.bool(channel.mentions_only),
          ],
        )
    }
  })
}

pub fn allowed(db: store.Store, bot: String) -> Result(List(Allowed), Error) {
  store.query(
    db,
    query(
      _,
      "SELECT user_id,name,added_at FROM discord_allowed WHERE bot=? ORDER BY added_at,user_id",
      [sqlight.text(bot)],
      {
        use user <- decode.field(0, decode.string)
        use name <- decode.field(1, decode.optional(decode.string))
        use added <- decode.field(2, decode.int)
        decode.success(Allowed(user, name, added))
      },
    ),
  )
}

/// Newest first.
pub fn requests(db: store.Store, bot: String) -> Result(List(Request), Error) {
  store.query(
    db,
    query(
      _,
      "SELECT user_id,username,preview,last_at,count FROM discord_requests WHERE bot=? ORDER BY last_at DESC,user_id",
      [sqlight.text(bot)],
      {
        use user <- decode.field(0, decode.string)
        use username <- decode.field(1, decode.string)
        use preview <- decode.field(2, decode.string)
        use last <- decode.field(3, decode.int)
        use count <- decode.field(4, decode.int)
        decode.success(Request(user, username, preview, last, count))
      },
    ),
  )
}

/// Adds or renames an allowed person and drops their pending request. A
/// rename keeps when they were first added.
pub fn allow(
  db: store.Store,
  bot: String,
  user_id: String,
  name: Option(String),
) -> Result(Allowed, Error) {
  use _ <- result.try(validate_snowflake(user_id, "user id"))
  store.query(db, fn(connection) {
    use _ <- result.try(find_on(connection, bot))
    use _ <- result.try(
      run(
        connection,
        "INSERT INTO discord_allowed(bot,user_id,name,added_at) VALUES(?,?,?,?) ON CONFLICT(bot,user_id) DO UPDATE SET name=COALESCE(excluded.name,name)",
        [
          sqlight.text(bot),
          sqlight.text(user_id),
          sqlight.nullable(sqlight.text, name),
          sqlight.int(usage.now()),
        ],
      ),
    )
    use _ <- result.try(
      run(connection, "DELETE FROM discord_requests WHERE bot=? AND user_id=?", [
        sqlight.text(bot),
        sqlight.text(user_id),
      ]),
    )
    query(
      connection,
      "SELECT user_id,name,added_at FROM discord_allowed WHERE bot=? AND user_id=?",
      [sqlight.text(bot), sqlight.text(user_id)],
      {
        use user <- decode.field(0, decode.string)
        use name <- decode.field(1, decode.optional(decode.string))
        use added <- decode.field(2, decode.int)
        decode.success(Allowed(user, name, added))
      },
    )
    |> result.try(first)
  })
}

/// Removes an allowed person (`table` "discord_allowed") or dismisses a
/// request (`table` "discord_requests"); NotFound when there was none.
fn remove(
  db: store.Store,
  table: String,
  bot: String,
  user_id: String,
) -> Result(Nil, Error) {
  store.query(db, fn(connection) {
    use _ <- result.try(find_on(connection, bot))
    query(
      connection,
      "DELETE FROM " <> table <> " WHERE bot=? AND user_id=? RETURNING user_id",
      [sqlight.text(bot), sqlight.text(user_id)],
      decode.field(0, decode.string, decode.success),
    )
    |> result.try(first)
    |> result.replace(Nil)
  })
}

pub fn disallow(
  db: store.Store,
  bot: String,
  user_id: String,
) -> Result(Nil, Error) {
  remove(db, "discord_allowed", bot, user_id)
}

pub fn dismiss(
  db: store.Store,
  bot: String,
  user_id: String,
) -> Result(Nil, Error) {
  remove(db, "discord_requests", bot, user_id)
}

/// Whether `user_id` may DM the bot, and so be DMed by it.
pub fn whitelisted(
  connection: sqlight.Connection,
  bot: String,
  owner_id: String,
  user_id: String,
) -> Result(Bool, String) {
  case user_id == owner_id {
    True -> Ok(True)
    False ->
      store.rows(
        connection,
        "SELECT 1 FROM discord_allowed WHERE bot=? AND user_id=?",
        [sqlight.text(bot), sqlight.text(user_id)],
        decode.success(Nil),
      )
      |> result.map(fn(rows) { rows != [] })
  }
}

pub fn may_dm(
  db: store.Store,
  bot: Bot,
  user_id: String,
) -> Result(Bool, Error) {
  store.query(db, whitelisted(_, bot.id, bot.owner_id, user_id))
  |> result.map_error(Storage)
}

/// A refused DM: its sender joins the requests the human can allow, at most
/// `request_limit` per bot.
pub fn refuse(
  connection: sqlight.Connection,
  bot: String,
  user_id: String,
  username: String,
  content: String,
) -> Result(Nil, String) {
  use _ <- result.try(
    store.run(
      connection,
      "INSERT INTO discord_requests(bot,user_id,username,preview,last_at,count) VALUES(?,?,?,?,?,1) ON CONFLICT(bot,user_id) DO UPDATE SET username=excluded.username,preview=excluded.preview,last_at=excluded.last_at,count=count+1",
      [
        sqlight.text(bot),
        sqlight.text(user_id),
        sqlight.text(username),
        sqlight.text(text_scalars.take(content, 200)),
        sqlight.int(usage.now()),
      ],
    ),
  )
  store.run(
    connection,
    "DELETE FROM discord_requests WHERE bot=? AND user_id NOT IN (SELECT user_id FROM discord_requests WHERE bot=? ORDER BY last_at DESC,user_id LIMIT ?)",
    [sqlight.text(bot), sqlight.text(bot), sqlight.int(request_limit)],
  )
}

/// Moves a channel's cursor forward to `message`, never back.
pub fn advance(
  connection: sqlight.Connection,
  bot: String,
  channel: String,
  message: String,
) -> Result(Nil, String) {
  use current <- result.try(store.rows(
    connection,
    "SELECT last_seen FROM discord_cursors WHERE bot=? AND channel_id=?",
    [sqlight.text(bot), sqlight.text(channel)],
    decode.field(0, decode.string, decode.success),
  ))
  case current {
    [seen, ..] ->
      case newer(message, seen) {
        True ->
          store.run(
            connection,
            "UPDATE discord_cursors SET last_seen=? WHERE bot=? AND channel_id=?",
            [sqlight.text(message), sqlight.text(bot), sqlight.text(channel)],
          )
        False -> Ok(Nil)
      }
    [] ->
      store.run(
        connection,
        "INSERT INTO discord_cursors(bot,channel_id,last_seen) VALUES(?,?,?)",
        [sqlight.text(bot), sqlight.text(channel), sqlight.text(message)],
      )
  }
}

pub fn note_sent(
  db: store.Store,
  bot: String,
  channel: String,
  message: String,
) -> Result(Nil, Error) {
  store.query(db, advance(_, bot, channel, message))
  |> result.map_error(Storage)
}

/// Snowflakes compare as integers: by length, then by digits.
pub fn newer(candidate: String, than: String) -> Bool {
  case string.length(candidate) - string.length(than) {
    0 -> string.compare(candidate, than) == order.Gt
    difference -> difference > 0
  }
}

pub fn cursors(
  db: store.Store,
  bot: String,
) -> Result(List(#(String, String)), Error) {
  store.query(
    db,
    query(
      _,
      "SELECT channel_id,last_seen FROM discord_cursors WHERE bot=? ORDER BY channel_id",
      [sqlight.text(bot)],
      {
        use channel <- decode.field(0, decode.string)
        use seen <- decode.field(1, decode.string)
        decode.success(#(channel, seen))
      },
    ),
  )
}

/// Channels the session may act in: configured ones, and channels a message
/// was delivered or sent in (threads under them, whitelisted DMs).
pub fn visible(
  db: store.Store,
  bot: String,
  channel: String,
) -> Result(Bool, Error) {
  store.query(
    db,
    count(
      _,
      "SELECT (SELECT count(*) FROM discord_channels WHERE bot=? AND channel_id=?)+(SELECT count(*) FROM discord_cursors WHERE bot=? AND channel_id=?)",
      [
        sqlight.text(bot),
        sqlight.text(channel),
        sqlight.text(bot),
        sqlight.text(channel),
      ],
    ),
  )
  |> result.map(fn(found) { found > 0 })
}

pub fn account(db: store.Store) -> Result(Option(Account), Error) {
  store.query(
    db,
    query(_, "SELECT user_id,username FROM discord_account WHERE id=1", [], {
      use user <- decode.field(0, decode.string)
      use username <- decode.field(1, decode.string)
      decode.success(Account(user, username))
    }),
  )
  |> result.map(fn(rows) { list.first(rows) |> option.from_result })
}

/// The login the provisioner needs, for its environment only.
pub fn login(db: store.Store) -> Result(Option(Login), Error) {
  store.query(
    db,
    query(_, "SELECT browser,token FROM discord_account WHERE id=1", [], {
      use browser <- decode.field(0, decode.int)
      use token <- decode.field(1, decode.string)
      decode.success(case browser {
        0 -> Token(token)
        _ -> Browser
      })
    }),
  )
  |> result.map(fn(rows) { list.first(rows) |> option.from_result })
}

pub fn connect_account(
  db: store.Store,
  login: Login,
  account: Account,
) -> Result(Nil, Error) {
  let #(browser, token) = case login {
    Token(token) -> #(0, token)
    Browser -> #(1, "")
  }
  store.query(
    db,
    run(
      _,
      "INSERT INTO discord_account(id,token,user_id,username,browser,connected_at) VALUES(1,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET token=excluded.token,user_id=excluded.user_id,username=excluded.username,browser=excluded.browser,connected_at=excluded.connected_at",
      [
        sqlight.text(token),
        sqlight.text(account.user_id),
        sqlight.text(account.username),
        sqlight.int(browser),
        sqlight.int(usage.now()),
      ],
    ),
  )
}

/// Forgetting the login leaves every bot it created alone.
pub fn forget_account(db: store.Store) -> Result(Nil, Error) {
  store.query(db, run(_, "DELETE FROM discord_account", []))
}

pub fn session_exists(db: store.Store, session: String) -> Result(Bool, Error) {
  store.query(
    db,
    count(_, "SELECT count(*) FROM sessions WHERE id=?", [
      sqlight.text(session),
    ]),
  )
  |> result.map(fn(found) { found > 0 })
}

fn validate_name(name: String) -> Result(Nil, Error) {
  case string.trim(name) != "" && text_scalars.length(name) <= 64 {
    True -> Ok(Nil)
    False -> Error(Invalid("name must be 1–64 characters"))
  }
}

fn validate_token(token: String) -> Result(Nil, Error) {
  let parts = string.split(token, ".")
  case
    list.length(parts) == 3
    && list.all(parts, fn(part) { part != "" && ascii(part, token_characters) })
    && string.byte_size(token) <= 256
  {
    True -> Ok(Nil)
    False ->
      Error(Invalid(
        "token must be a bot token: three dot-separated parts from the developer portal's Bot page",
      ))
  }
}

const token_characters =
  "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"

fn validate_owner(owner: String) -> Result(Nil, Error) {
  validate_snowflake(owner, "owner_id")
}

fn validate_snowflake(value: String, label: String) -> Result(Nil, Error) {
  let length = string.length(value)
  case length >= 17 && length <= 20 && ascii(value, "0123456789") {
    True -> Ok(Nil)
    False -> Error(Invalid(label <> " must be a Discord id of 17–20 digits"))
  }
}

fn ascii(text: String, allowed: String) -> Bool {
  text |> string.to_graphemes |> list.all(string.contains(allowed, _))
}

@external(erlang, "albedo_discord", "token_user")
fn token_user(token: String) -> Result(String, Nil)
