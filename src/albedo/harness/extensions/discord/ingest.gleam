//// Messages the bot process saw become letters in the session's inbox, by
//// the ingest rules in robot-docs/discord.md: whitelisted DMs steer a running
//// turn, configured channels follow their row's delivery, and the rest is
//// ignored or recorded as a DM request.

import albedo/daemon/mail
import albedo/daemon/store
import albedo/daemon/usage
import albedo/harness/extensions/discord/ledger
import albedo/harness/extensions/discord/refs
import albedo/text_scalars
import gleam/bool
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import sqlight

pub type Author {
  Author(id: String, username: String, global_name: Option(String), bot: Bool)
}

pub type Attachment {
  Attachment(filename: String, url: String)
}

pub type Reaction {
  Reaction(
    id: String,
    message_id: String,
    channel_id: String,
    guild_id: Option(String),
    guild_name: Option(String),
    channel_name: Option(String),
    parent_id: Option(String),
    author: Author,
    nick: Option(String),
    emoji: String,
    message_author_id: Option(String),
  )
}

pub type Message {
  Message(
    id: String,
    channel_id: String,
    guild_id: Option(String),
    guild_name: Option(String),
    channel_name: Option(String),
    parent_id: Option(String),
    is_dm: Bool,
    content: String,
    timestamp: Option(String),
    author: Author,
    nick: Option(String),
    mentions_me: Bool,
    reply_to: Option(String),
    attachments: List(Attachment),
  )
}

fn optional_text(
  name: String,
  next: fn(Option(String)) -> decode.Decoder(a),
) -> decode.Decoder(a) {
  decode.optional_field(name, None, decode.optional(decode.string), next)
}

pub fn author_decoder() -> decode.Decoder(Author) {
  use id <- decode.field("id", decode.string)
  use username <- decode.optional_field("username", "", decode.string)
  use global_name <- optional_text("global_name")
  use bot <- decode.optional_field("bot", False, decode.bool)
  decode.success(Author(id, username, global_name, bot))
}

pub fn reaction_decoder() -> decode.Decoder(Reaction) {
  use id <- decode.field("id", decode.string)
  use message_id <- decode.field("message_id", decode.string)
  use channel_id <- decode.field("channel_id", decode.string)
  use guild_id <- optional_text("guild_id")
  use guild_name <- optional_text("guild_name")
  use channel_name <- optional_text("channel_name")
  use parent_id <- optional_text("parent_id")
  use author <- decode.field("author", author_decoder())
  use nick <- optional_text("nick")
  use emoji <- decode.field("emoji", decode.string)
  use message_author_id <- optional_text("message_author_id")
  decode.success(Reaction(
    id,
    message_id,
    channel_id,
    guild_id,
    guild_name,
    channel_name,
    parent_id,
    author,
    nick,
    emoji,
    message_author_id,
  ))
}

pub fn decoder() -> decode.Decoder(Message) {
  use id <- decode.field("id", decode.string)
  use channel <- decode.field("channel_id", decode.string)
  use guild <- optional_text("guild_id")
  use guild_name <- optional_text("guild_name")
  use channel_name <- optional_text("channel_name")
  use parent <- optional_text("parent_id")
  use is_dm <- decode.optional_field("is_dm", False, decode.bool)
  use content <- decode.optional_field("content", "", decode.string)
  use timestamp <- optional_text("timestamp")
  use author <- decode.field("author", author_decoder())
  use nick <- optional_text("nick")
  use mentions_me <- decode.optional_field("mentions_me", False, decode.bool)
  use reply_to <- optional_text("reply_to")
  use attachments <- decode.optional_field(
    "attachments",
    [],
    decode.list({
      use filename <- decode.optional_field("filename", "file", decode.string)
      use url <- decode.optional_field("url", "", decode.string)
      decode.success(Attachment(filename, url))
    }),
  )
  decode.success(Message(
    id,
    channel,
    guild,
    guild_name,
    channel_name,
    parent,
    is_dm,
    content,
    timestamp,
    author,
    nick,
    mentions_me,
    reply_to,
    attachments,
  ))
}

pub fn letter_id(bot: String, message: String) -> String {
  "discord-" <> bot <> "-" <> message
}

pub fn reaction_letter_id(bot: String, event: String) -> String {
  "discord-" <> bot <> "-reaction-" <> event
}

/// Applies the reaction ingest rules without advancing a message cursor.
pub fn ingest_reaction(
  db: store.Store,
  bot: String,
  self_id: Option(String),
  reaction: Reaction,
) -> Result(Option(mail.Letter), String) {
  store.query(db, fn(connection) {
    store.transaction(connection, fn() {
      use recipient <- result.try(recipient(connection, bot))
      case recipient {
        None -> Ok(None)
        Some(#(session, owner, stored_self)) -> {
          let self_id = option.or(self_id, stored_self)
          use <- bool.guard(self_id == Some(reaction.author.id), Ok(None))
          use delivery <- result.try(reaction_delivery(
            connection,
            bot,
            self_id,
            owner,
            reaction,
          ))
          case delivery {
            None -> Ok(None)
            Some(delivery) -> {
              use channel <- result.try(refs.channel(
                connection,
                bot,
                reaction.channel_id,
                reaction.channel_name,
                reaction.guild_name,
              ))
              use target <- result.try(refs.message(
                connection,
                bot,
                reaction.channel_id,
                reaction.message_id,
                reaction.message_author_id,
                None,
                None,
              ))
              store_event_letter(
                connection,
                reaction_letter_id(bot, reaction.id),
                session,
                delivery,
                reaction_body(reaction, self_id, channel.ref, target),
              )
            }
          }
        }
      }
    })
  })
}

fn reaction_delivery(
  connection: sqlight.Connection,
  bot: String,
  self_id: Option(String),
  owner: String,
  reaction: Reaction,
) -> Result(Option(mail.Delivery), String) {
  case reaction.guild_id {
    None -> {
      use allowed <- result.try(ledger.whitelisted(
        connection,
        bot,
        owner,
        reaction.author.id,
      ))
      case allowed {
        True -> Ok(Some(mail.AfterTool))
        False -> Ok(None)
      }
    }
    Some(_) -> {
      use config <- result.try(ledger.channel_config(
        connection,
        bot,
        reaction.channel_id,
        reaction.parent_id,
      ))
      case config {
        None -> Ok(None)
        Some(config) -> {
          use allowed <- result.try(reaction_allowed(
            connection,
            bot,
            self_id,
            config.mentions_only,
            reaction,
          ))
          case allowed {
            False -> Ok(None)
            True -> {
              let delivery = case config.delivery {
                "tool" -> mail.AfterTool
                _ -> mail.AfterTurn
              }
              Ok(Some(delivery))
            }
          }
        }
      }
    }
  }
}

fn reaction_allowed(
  connection: sqlight.Connection,
  bot: String,
  self_id: Option(String),
  mentions_only: Bool,
  reaction: Reaction,
) -> Result(Bool, String) {
  case mentions_only {
    False -> Ok(True)
    True -> {
      let authored_by_bot = case reaction.message_author_id, self_id {
        Some(author), Some(bot_id) -> author == bot_id
        _, _ -> False
      }
      case authored_by_bot {
        True -> Ok(True)
        False ->
          store.rows(
            connection,
            "SELECT 1 FROM mail WHERE id=? AND delivered_at IS NOT NULL",
            [sqlight.text(letter_id(bot, reaction.message_id))],
            decode.success(Nil),
          )
          |> result.map(fn(rows) { rows != [] })
      }
    }
  }
}

/// Applies the ingest rules to one message in one store transaction and
/// answers the letter it stored, for the caller to deliver after commit.
/// `self_id` is the bot user from READY when the live process knows it.
pub fn ingest(
  db: store.Store,
  bot: String,
  self_id: Option(String),
  message: Message,
) -> Result(Option(mail.Letter), String) {
  store.query(db, fn(connection) {
    store.transaction(connection, fn() {
      use found <- result.try(recipient(connection, bot))
      case found {
        None -> Ok(None)
        Some(#(session, owner, stored_self)) -> {
          let self_id = option.or(self_id, stored_self)
          let own = Some(message.author.id) == self_id
          case message.is_dm {
            True -> direct(connection, bot, session, owner, own, message)
            False -> guild(connection, bot, session, own, message)
          }
        }
      }
    })
  })
}

fn recipient(
  connection: sqlight.Connection,
  bot: String,
) -> Result(Option(#(String, String, Option(String))), String) {
  store.rows(
    connection,
    "SELECT session,owner_id,user_id FROM discord_bots WHERE id=?",
    [sqlight.text(bot)],
    {
      use session <- decode.field(0, decode.string)
      use owner <- decode.field(1, decode.string)
      use user <- decode.field(2, decode.optional(decode.string))
      decode.success(#(session, owner, user))
    },
  )
  |> result.map(fn(rows) {
    case rows {
      [] -> None
      [row, ..] -> Some(row)
    }
  })
}

fn direct(
  connection: sqlight.Connection,
  bot: String,
  session: String,
  owner: String,
  own: Bool,
  message: Message,
) -> Result(Option(mail.Letter), String) {
  use allowed <- result.try(ledger.whitelisted(
    connection,
    bot,
    owner,
    message.author.id,
  ))
  case own, allowed {
    True, _ -> {
      // The bot's own DM lands in a channel it may already know.
      use known <- result.try(known_channel(connection, bot, message.channel_id))
      case known {
        True -> ledger.advance(connection, bot, message.channel_id, message.id)
        False -> Ok(Nil)
      }
      |> result.replace(None)
    }
    False, True -> {
      use _ <- result.try(ledger.advance(
        connection,
        bot,
        message.channel_id,
        message.id,
      ))
      store_letter(connection, bot, session, mail.AfterTool, message)
    }
    False, False ->
      ledger.refuse(
        connection,
        bot,
        message.author.id,
        message.author.username,
        message.content,
      )
      |> result.replace(None)
  }
}

fn known_channel(
  connection: sqlight.Connection,
  bot: String,
  channel: String,
) -> Result(Bool, String) {
  store.rows(
    connection,
    "SELECT 1 FROM discord_cursors WHERE bot=? AND channel_id=?",
    [sqlight.text(bot), sqlight.text(channel)],
    decode.success(Nil),
  )
  |> result.map(fn(rows) { rows != [] })
}

fn guild(
  connection: sqlight.Connection,
  bot: String,
  session: String,
  own: Bool,
  message: Message,
) -> Result(Option(mail.Letter), String) {
  use config <- result.try(ledger.channel_config(
    connection,
    bot,
    message.channel_id,
    message.parent_id,
  ))
  case config {
    None -> Ok(None)
    Some(config) -> {
      use _ <- result.try(ledger.advance(
        connection,
        bot,
        message.channel_id,
        message.id,
      ))
      case own || { config.mentions_only && !message.mentions_me } {
        True -> Ok(None)
        False -> {
          let delivery = case config.delivery {
            "tool" -> mail.AfterTool
            _ -> mail.AfterTurn
          }
          store_letter(connection, bot, session, delivery, message)
        }
      }
    }
  }
}

/// A message delivered once already (a catch-up replay) stores nothing; nor
/// does one past the session's full inbox.
fn store_letter(
  connection: sqlight.Connection,
  bot: String,
  session: String,
  delivery: mail.Delivery,
  message: Message,
) -> Result(Option(mail.Letter), String) {
  use channel <- result.try(refs.channel(
    connection,
    bot,
    message.channel_id,
    message.channel_name,
    message.guild_name,
  ))
  use number <- result.try(
    refs.message(
      connection,
      bot,
      message.channel_id,
      message.id,
      Some(message.author.id),
      Some(author_name(message)),
      excerpt(message),
    )
    |> result.map(fn(met) { met.number }),
  )
  use reply <- result.try(case message.is_dm, message.reply_to {
    False, Some(target) ->
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
    _, _ -> Ok(None)
  })
  store_event_letter(
    connection,
    letter_id(bot, message.id),
    session,
    delivery,
    body(message, channel.ref, number, reply),
  )
}

fn store_event_letter(
  connection: sqlight.Connection,
  id: String,
  session: String,
  delivery: mail.Delivery,
  body: String,
) -> Result(Option(mail.Letter), String) {
  use existing <- result.try(store.rows(
    connection,
    "SELECT 1 FROM mail WHERE id=?",
    [sqlight.text(id)],
    decode.success(Nil),
  ))
  case existing {
    [_, ..] -> Ok(None)
    [] -> {
      let letter =
        mail.Letter(
          id,
          session,
          None,
          "discord",
          mail.Event(delivery),
          body,
          usage.now(),
        )
      use stored <- result.try(mail.insert(connection, letter, mail.Inbox))
      case stored {
        True -> Ok(Some(letter))
        False -> Ok(None)
      }
    }
  }
}

fn reaction_body(
  reaction: Reaction,
  self_id: Option(String),
  channel: Int,
  target: refs.Message,
) -> String {
  let in_guild = option.is_some(reaction.guild_id)
  let name = display_name(reaction.author, reaction.nick, !in_guild)
  let mine = case self_id {
    Some(bot) -> target.author_id == Some(bot)
    None -> False
  }
  let whose = case mine, target.author {
    True, _ -> "your message"
    False, Some(author) -> author <> "'s message"
    False, None -> "message"
  }
  let quoted = case target.excerpt {
    Some(text) -> ": \"" <> text <> "\""
    None -> ""
  }
  place(True, in_guild, reaction.channel_name, reaction.guild_name, channel)
  <> " "
  <> person(reaction.author, name)
  <> " reacted "
  <> reaction.emoji
  <> " to "
  <> whose
  <> " "
  <> int.to_string(target.number)
  <> quoted
}

/// The leading `[discord …]` of an event: where it happened, and the
/// channel's handle for answering there.
fn place(
  reaction: Bool,
  in_guild: Bool,
  name: Option(String),
  guild: Option(String),
  channel: Int,
) -> String {
  let handle = refs.handle(channel)
  case in_guild, reaction {
    False, False -> "[discord dm · " <> handle <> "]"
    False, True -> "[discord dm reaction · " <> handle <> "]"
    True, _ ->
      "[discord "
      <> case reaction {
        True -> "reaction "
        False -> ""
      }
      <> case name {
        Some(name) -> "#" <> name
        None -> "a channel"
      }
      <> " in "
      <> option.unwrap(guild, "a server")
      <> " · "
      <> handle
      <> "]"
  }
}

/// The name a person goes by where they spoke: their server nickname, else
/// the account's display name. Nothing in a DM but the display name.
fn display_name(
  author: Author,
  nick: Option(String),
  dm: Bool,
) -> Option(String) {
  case dm {
    True -> author.global_name
    False -> option.or(nick, author.global_name)
  }
}

/// `@username (name, bot)`; the parenthesis holds only what there is.
fn person(author: Author, name: Option(String)) -> String {
  let parenthesis = case name, author.bot {
    None, False -> ""
    None, True -> " (bot)"
    Some(name), False -> " (" <> name <> ")"
    Some(name), True -> " (" <> name <> ", bot)"
  }
  "@" <> author.username <> parenthesis
}

/// What a message's author is called in the session's view: the name they go
/// by in that place, else their username.
pub fn author_name(message: Message) -> String {
  display_name(message.author, message.nick, message.is_dm)
  |> option.unwrap(message.author.username)
}

const excerpt_limit = 80

/// A line of at most `excerpt_limit` scalars standing for `text`; None when
/// there is nothing to show.
pub fn preview(text: String) -> Option(String) {
  let line =
    text
    |> string.replace("\n", " ")
    |> string.replace("\r", " ")
    |> string.replace("\t", " ")
    |> string.split(" ")
    |> list.filter(fn(word) { word != "" })
    |> string.join(" ")
  case line {
    "" -> None
    _ ->
      case text_scalars.length(line) > excerpt_limit {
        True -> Some(text_scalars.take(line, excerpt_limit) <> "…")
        False -> Some(line)
      }
  }
}

pub fn excerpt(message: Message) -> Option(String) {
  case preview(message.content), message.attachments {
    None, [first, ..] -> Some("[" <> first.filename <> "]")
    shown, _ -> shown
  }
}

/// Content past this many scalars is cut, well inside mail's body limit.
const content_limit = 16_384

/// The text the session reads inside its `<event>` block. `channel` is the
/// channel's handle, `number` the message's number there, and `reply` the
/// number of the message it answers.
pub fn body(
  message: Message,
  channel: Int,
  number: Int,
  reply: Option(Int),
) -> String {
  let name = display_name(message.author, message.nick, message.is_dm)
  let reply = case reply {
    Some(target) -> " · reply to " <> int.to_string(target)
    None -> ""
  }
  let header =
    place(
      False,
      !message.is_dm,
      message.channel_name,
      message.guild_name,
      channel,
    )
    <> " "
    <> person(message.author, name)
    <> " · message "
    <> int.to_string(number)
    <> reply
  let content = case message.content {
    "" -> "(no text)"
    text ->
      case text_scalars.length(text) > content_limit {
        True -> text_scalars.take(text, content_limit) <> "\n[truncated]"
        False -> text
      }
  }
  [
    header,
    content,
    ..list.map(message.attachments, fn(item) {
      "attachment: " <> item.filename <> " " <> item.url
    })
  ]
  |> string.join("\n")
}
