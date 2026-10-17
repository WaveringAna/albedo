//// Short names for what Discord identifies by snowflake. A channel the bot
//// sees is `c<N>`, and each message in it is a number counted in the order
//// the daemon first met it, so the model reads "your message 413" and writes
//// `react("c3", 413, "👍")` instead of handling 19-digit ids. Both are kept
//// per bot, so they mean the same after a restart.

import albedo/daemon/store
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import sqlight

pub const schema =
  "
CREATE TABLE IF NOT EXISTS discord_channel_refs (
 bot TEXT NOT NULL REFERENCES discord_bots(id) ON DELETE CASCADE,
 channel_id TEXT NOT NULL,
 ref INTEGER NOT NULL,
 guild_name TEXT,
 channel_name TEXT,
 PRIMARY KEY(bot,channel_id),
 UNIQUE(bot,ref)
);
CREATE TABLE IF NOT EXISTS discord_message_refs (
 bot TEXT NOT NULL REFERENCES discord_bots(id) ON DELETE CASCADE,
 channel_id TEXT NOT NULL,
 number INTEGER NOT NULL,
 message_id TEXT NOT NULL,
 author_id TEXT,
 author_name TEXT,
 excerpt TEXT,
 PRIMARY KEY(bot,channel_id,number),
 UNIQUE(bot,channel_id,message_id)
);
"

/// A channel's handle number, and the names recorded for it.
pub type Channel {
  Channel(ref: Int, name: Option(String), guild: Option(String))
}

/// A message's number, and what was recorded of it when it was met.
pub type Message {
  Message(
    number: Int,
    author_id: Option(String),
    author: Option(String),
    excerpt: Option(String),
  )
}

pub type Resolved {
  Found(String)
  Unknown
  /// The handles and names of every channel the text could mean.
  Ambiguous(List(String))
}

pub fn handle(ref: Int) -> String {
  "c" <> int.to_string(ref)
}

/// The channel's handle, numbering it when it is new. A name that is known
/// replaces one that is not.
pub fn channel(
  connection: sqlight.Connection,
  bot: String,
  id: String,
  name: Option(String),
  guild: Option(String),
) -> Result(Channel, String) {
  store.one(
    connection,
    "INSERT INTO discord_channel_refs(bot,channel_id,ref,guild_name,channel_name) VALUES(?,?,(SELECT coalesce(max(ref),0)+1 FROM discord_channel_refs WHERE bot=?),?,?) ON CONFLICT(bot,channel_id) DO UPDATE SET guild_name=coalesce(excluded.guild_name,guild_name),channel_name=coalesce(excluded.channel_name,channel_name) RETURNING ref,channel_name,guild_name",
    [
      sqlight.text(bot),
      sqlight.text(id),
      sqlight.text(bot),
      sqlight.nullable(sqlight.text, guild),
      sqlight.nullable(sqlight.text, name),
    ],
    {
      use ref <- decode.field(0, decode.int)
      use name <- decode.field(1, decode.optional(decode.string))
      use guild <- decode.field(2, decode.optional(decode.string))
      decode.success(Channel(ref, name, guild))
    },
    "channel not numbered",
  )
}

/// The message's number in its channel, numbering it when it is new. What is
/// known of its author and text is kept once.
pub fn message(
  connection: sqlight.Connection,
  bot: String,
  channel: String,
  id: String,
  author_id: Option(String),
  author: Option(String),
  excerpt: Option(String),
) -> Result(Message, String) {
  store.one(
    connection,
    "INSERT INTO discord_message_refs(bot,channel_id,number,message_id,author_id,author_name,excerpt) VALUES(?,?,(SELECT coalesce(max(number),0)+1 FROM discord_message_refs WHERE bot=? AND channel_id=?),?,?,?,?) ON CONFLICT(bot,channel_id,message_id) DO UPDATE SET author_id=coalesce(excluded.author_id,author_id),author_name=coalesce(excluded.author_name,author_name),excerpt=coalesce(excluded.excerpt,excerpt) RETURNING number,author_id,author_name,excerpt",
    [
      sqlight.text(bot),
      sqlight.text(channel),
      sqlight.text(bot),
      sqlight.text(channel),
      sqlight.text(id),
      sqlight.nullable(sqlight.text, author_id),
      sqlight.nullable(sqlight.text, author),
      sqlight.nullable(sqlight.text, excerpt),
    ],
    {
      use number <- decode.field(0, decode.int)
      use author_id <- decode.field(1, decode.optional(decode.string))
      use author <- decode.field(2, decode.optional(decode.string))
      use excerpt <- decode.field(3, decode.optional(decode.string))
      decode.success(Message(number, author_id, author, excerpt))
    },
    "message not numbered",
  )
}

/// A channel written as its handle (`c3`), a name (`general`, `#general`, or
/// `Server/general`), or a snowflake.
pub fn resolve_channel(
  connection: sqlight.Connection,
  bot: String,
  text: String,
) -> Result(Resolved, String) {
  let text = string.trim(text)
  case snowflake(text), ref_of(text) {
    True, _ -> Ok(Found(text))
    False, Some(ref) ->
      channels(connection, " AND ref=?", [sqlight.int(ref)], bot)
      |> result.map(fn(rows) { one_of(rows) })
    False, None -> {
      let #(guild, name) = case string.split_once(text, "/") {
        Ok(#(guild, name)) -> #(Some(guild), name)
        Error(_) -> #(None, text)
      }
      let name = without_hash(name)
      let #(clause, arguments) = case guild {
        Some(guild) -> #(
          " AND lower(channel_name)=lower(?) AND lower(guild_name)=lower(?)",
          [
            sqlight.text(name),
            sqlight.text(guild),
          ],
        )
        None -> #(" AND lower(channel_name)=lower(?)", [sqlight.text(name)])
      }
      channels(connection, clause, arguments, bot)
      |> result.map(fn(rows) { one_of(rows) })
    }
  }
}

fn channels(
  connection: sqlight.Connection,
  clause: String,
  arguments: List(sqlight.Value),
  bot: String,
) -> Result(List(#(String, String)), String) {
  store.rows(
    connection,
    "SELECT channel_id,ref,channel_name,guild_name FROM discord_channel_refs WHERE bot=?"
      <> clause
      <> " ORDER BY ref",
    [sqlight.text(bot), ..arguments],
    {
      use id <- decode.field(0, decode.string)
      use ref <- decode.field(1, decode.int)
      use name <- decode.field(2, decode.optional(decode.string))
      use guild <- decode.field(3, decode.optional(decode.string))
      decode.success(#(id, describe(ref, name, guild)))
    },
  )
}

/// `c3 (#general in Server)`.
fn describe(ref: Int, name: Option(String), guild: Option(String)) -> String {
  let place = case name, guild {
    Some(name), Some(guild) -> " (#" <> name <> " in " <> guild <> ")"
    Some(name), None -> " (#" <> name <> ")"
    None, _ -> ""
  }
  handle(ref) <> place
}

fn one_of(rows: List(#(String, String))) -> Resolved {
  case rows {
    [] -> Unknown
    [#(id, _)] -> Found(id)
    many -> Ambiguous(list.map(many, fn(row) { row.1 }))
  }
}

/// The snowflake of message `text` in `channel`: `text` is one itself, or
/// the number (`413`, `#413`) the daemon gave a message there. None when
/// the channel has no such number.
pub fn resolve_message(
  connection: sqlight.Connection,
  bot: String,
  channel: String,
  text: String,
) -> Result(Option(String), String) {
  let text = string.trim(text)
  case snowflake(text), int.parse(without_hash(text)) {
    True, _ -> Ok(Some(text))
    False, Ok(number) ->
      store.rows(
        connection,
        "SELECT message_id FROM discord_message_refs WHERE bot=? AND channel_id=? AND number=?",
        [sqlight.text(bot), sqlight.text(channel), sqlight.int(number)],
        decode.field(0, decode.string, decode.success),
      )
      |> result.map(fn(rows) { list.first(rows) |> option.from_result })
    False, Error(_) -> Ok(None)
  }
}

fn without_hash(text: String) -> String {
  case text {
    "#" <> rest -> rest
    _ -> text
  }
}

/// Discord ids are 17 to 20 digits; anything shorter is a number or a handle.
fn snowflake(text: String) -> Bool {
  let length = string.length(text)
  length >= 17
  && length <= 20
  && list.all(string.to_graphemes(text), fn(digit) {
    string.contains("0123456789", digit)
  })
}

fn ref_of(text: String) -> Option(Int) {
  case string.lowercase(text) {
    "c" <> digits -> int.parse(digits) |> option.from_result
    _ -> None
  }
}
