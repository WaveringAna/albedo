//// The numbers a session addresses Discord by. E2E drives the happy path
//// through a bot; the rules that need two servers sharing a channel name, two
//// bots sharing a store, or a message edited into a longer text are checked
//// here against the tables.

import albedo/daemon/store
import albedo/harness/extensions/discord/ingest
import albedo/harness/extensions/discord/refs
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleeunit/should
import sqlight

fn tables() -> store.Store {
  let assert Ok(db) = store.start(":memory:", "")
  let assert Ok(_) =
    store.query(db, fn(connection) {
      use _ <- result.try(store.exec(
        connection,
        "CREATE TABLE discord_bots(id TEXT PRIMARY KEY); INSERT INTO discord_bots VALUES('b1'),('b2');",
      ))
      store.exec(connection, refs.schema)
    })
  db
}

fn on(db: store.Store, run: fn(sqlight.Connection) -> a) -> a {
  store.query(db, run)
}

pub fn channels_are_numbered_per_bot_and_keep_the_names_they_learn_test() -> Nil {
  let db = tables()
  use connection <- on(db)
  let assert Ok(first) = refs.channel(connection, "b1", "11", None, None)
  let assert Ok(second) =
    refs.channel(connection, "b1", "22", Some("general"), Some("Lab"))
  let assert Ok(other_bot) = refs.channel(connection, "b2", "11", None, None)
  #(first.ref, second.ref, other_bot.ref) |> should.equal(#(1, 2, 1))

  let assert Ok(again) =
    refs.channel(connection, "b1", "11", Some("random"), Some("Lab"))
  again.ref |> should.equal(1)
  again.name |> should.equal(Some("random"))
  let assert Ok(kept) = refs.channel(connection, "b1", "11", None, None)
  kept.name |> should.equal(Some("random"))
  refs.handle(second.ref) |> should.equal("c2")
}

pub fn messages_are_numbered_per_channel_and_keep_what_was_known_test() -> Nil {
  let db = tables()
  use connection <- on(db)
  let met = fn(channel, id, author, excerpt) {
    let assert Ok(met) =
      refs.message(connection, "b1", channel, id, None, author, excerpt)
    met
  }
  met("11", "900", Some("Ann"), Some("hello")).number |> should.equal(1)
  met("11", "901", None, None).number |> should.equal(2)
  met("22", "902", None, None).number |> should.equal(1)

  // Meeting a message again changes neither its number nor what it quotes.
  let again = met("11", "900", None, None)
  again.number |> should.equal(1)
  again.author |> should.equal(Some("Ann"))
  again.excerpt |> should.equal(Some("hello"))
  // A reaction met it first, a delivery learns the rest.
  let learnt = met("11", "901", Some("Bo"), Some("later"))
  #(learnt.number, learnt.author) |> should.equal(#(2, Some("Bo")))
}

pub fn a_channel_is_found_by_handle_name_or_server_and_name_test() -> Nil {
  let db = tables()
  use connection <- on(db)
  let assert Ok(_) =
    refs.channel(connection, "b1", "11", Some("general"), Some("Lab"))
  let assert Ok(_) =
    refs.channel(connection, "b1", "22", Some("general"), Some("Garden"))
  let assert Ok(_) =
    refs.channel(connection, "b1", "33", Some("Random"), Some("Lab"))
  let assert Ok(_) =
    refs.channel(connection, "b2", "44", Some("only-b2"), Some("Lab"))
  let find = fn(text) {
    let assert Ok(found) = refs.resolve_channel(connection, "b1", text)
    found
  }
  find("c2") |> should.equal(refs.Found("22"))
  find("C2") |> should.equal(refs.Found("22"))
  find("#random") |> should.equal(refs.Found("33"))
  find("garden/general") |> should.equal(refs.Found("22"))
  find("Lab/#general") |> should.equal(refs.Found("11"))
  find("12345678901234567") |> should.equal(refs.Found("12345678901234567"))
  find("general")
  |> should.equal(
    refs.Ambiguous([
      "c1 (#general in Lab)",
      "c2 (#general in Garden)",
    ]),
  )
  find("only-b2") |> should.equal(refs.Unknown)
  find("c9") |> should.equal(refs.Unknown)
}

pub fn a_message_is_found_by_number_or_snowflake_test() -> Nil {
  let db = tables()
  use connection <- on(db)
  let assert Ok(_) =
    refs.message(connection, "b1", "11", "900", None, None, None)
  let find = fn(channel, text) {
    let assert Ok(found) = refs.resolve_message(connection, "b1", channel, text)
    found
  }
  find("11", "1") |> should.equal(Some("900"))
  find("11", " #1 ") |> should.equal(Some("900"))
  find("11", "900000000000000001") |> should.equal(Some("900000000000000001"))
  find("11", "2") |> should.equal(None)
  find("22", "1") |> should.equal(None)
  find("11", "yesterday") |> should.equal(None)
}

pub fn a_preview_is_one_short_line_test() -> Nil {
  ingest.preview("  two\n\tlines   here \r\n")
  |> should.equal(Some("two lines here"))
  ingest.preview(" \n ") |> should.equal(None)
  let long = string.repeat("word ", 40)
  let assert Some(cut) = ingest.preview(long)
  string.ends_with(cut, "…") |> should.be_true
  string.length(cut) |> should.equal(81)
}
