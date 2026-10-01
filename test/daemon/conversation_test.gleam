/// Legacy schema migrations preserve titles and event timestamps; E2E uses current schemas.
import albedo/daemon/conversation
import albedo/daemon/events as view
import albedo/daemon/store
import albedo/daemon/transcript
import albedo/harness/runtime
import albedo/openai_api/types
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import sqlight

@external(erlang, "albedo_runtime_test_support", "temporary_database")
fn temporary_database() -> String

@external(erlang, "albedo_runtime_test_support", "cleanup")
fn cleanup(path: String) -> Nil

fn session(id: String) -> conversation.Info {
  conversation.Info(
    id,
    "new session",
    "/tmp",
    "provider",
    "model",
    types.Responses,
    conversation.Idle,
    None,
    None,
  )
}

pub fn latest_user_title_survives_restart_and_legacy_migration_test() -> Nil {
  let path = temporary_database()
  let assert Ok(host) = runtime.start(path)
  let ledger = runtime.ledger(host)
  let assert Ok(_) = conversation.initialise(ledger)
  let assert Ok(_) = conversation.create(ledger, session("session"))
  let assert Ok(_) =
    conversation.commit(
      ledger,
      "session",
      [types.User("earlier title"), types.Assistant("not the title")],
      conversation.Model,
    )
  let assert Ok(_) =
    conversation.commit(
      ledger,
      "session",
      [types.User("  latest\naccepted 👩‍💻  ")],
      conversation.Model,
    )
  let assert Ok(_) =
    conversation.commit(
      ledger,
      "session",
      [
        types.Assistant("must not replace it"),
        types.ToolOutput("call", "output", []),
      ],
      conversation.Idle,
    )
  let assert Ok([before]) = conversation.list(ledger)
  before.title |> should.equal("latest accepted 👩‍💻")

  // Recreate the old schema shape; startup performs this transcript scan once.
  let assert Ok(_) =
    store.query(ledger, fn(db) {
      sqlight.exec(
        "ALTER TABLE sessions DROP COLUMN title; ALTER TABLE sessions DROP COLUMN last_assistant_at",
        db,
      )
    })
  runtime.stop(host)

  let assert Ok(restarted) = runtime.start(path)
  let ledger = runtime.ledger(restarted)
  let assert Ok(_) = conversation.initialise(ledger)
  let assert Ok([after]) = conversation.list(ledger)
  after.title |> should.equal("latest accepted 👩‍💻")
  after.last_assistant_at |> should.equal(None)
  runtime.stop(restarted)
  cleanup(path)
}

pub fn migration_recovers_placeholder_titles_and_activity_order_test() -> Nil {
  let path = temporary_database()
  let assert Ok(host) = runtime.start(path)
  let ledger = runtime.ledger(host)
  let assert Ok(_) = conversation.initialise(ledger)
  let assert Ok(_) = conversation.create(ledger, session("first"))
  let assert Ok(_) = conversation.create(ledger, session("second"))
  let assert Ok(_) =
    conversation.commit(
      ledger,
      "second",
      [types.User("older prompt")],
      conversation.Idle,
    )
  let assert Ok(_) =
    conversation.commit(
      ledger,
      "first",
      [types.User("newest prompt")],
      conversation.Idle,
    )
  let assert Ok(_) =
    store.query(ledger, fn(db) {
      sqlight.exec(
        "UPDATE sessions SET title='new session',activity_seq=NULL",
        db,
      )
    })

  // The null activity marker makes this a one-time legacy backfill. It also
  // distinguishes a placeholder title from a real current-session title.
  let assert Ok(_) = conversation.initialise(ledger)
  let assert Ok([first, second]) = conversation.list(ledger)
  first.id |> should.equal("first")
  first.title |> should.equal("newest prompt")
  second.id |> should.equal("second")
  second.title |> should.equal("older prompt")
  runtime.stop(host)
  cleanup(path)
}

pub fn transcript_timestamps_migrate_without_invention_and_roundtrip_test() -> Nil {
  let path = temporary_database()
  let assert Ok(host) = runtime.start(path)
  let ledger = runtime.ledger(host)
  let assert Ok(_) = conversation.initialise(ledger)
  let assert Ok(_) = conversation.create(ledger, session("timestamped"))
  let assert Ok(_) =
    conversation.commit(
      ledger,
      "timestamped",
      [types.User("legacy")],
      conversation.Idle,
    )

  // Recreate the legacy transcript shape. Migration adds a nullable column and
  // must not claim to know when this row was accepted.
  let assert Ok(_) =
    store.query(ledger, fn(db) {
      sqlight.exec(
        "ALTER TABLE transcript DROP COLUMN timestamp; ALTER TABLE transcript DROP COLUMN provider; ALTER TABLE transcript DROP COLUMN thought_ms",
        db,
      )
    })
  let assert Ok(_) = conversation.initialise(ledger)
  conversation.load_entries(ledger, "timestamped")
  |> should.equal(
    Ok([transcript.Entry(types.User("legacy"), None, None, None)]),
  )

  let new_inputs = [types.User("current"), types.Assistant("answer")]
  let assert Ok(timestamp) =
    conversation.commit(ledger, "timestamped", new_inputs, conversation.Idle)
  let assert True = timestamp > 1_000_000_000_000
  let assert Ok(entries) = conversation.load_entries(ledger, "timestamped")
  entries
  |> should.equal([
    transcript.Entry(types.User("legacy"), None, None, None),
    transcript.Entry(types.User("current"), Some(timestamp), None, None),
    transcript.Entry(types.Assistant("answer"), Some(timestamp), None, None),
  ])
  conversation.load(ledger, "timestamped")
  |> should.equal(Ok([types.User("legacy"), ..new_inputs]))

  let snapshot = view.snapshot(ledger, entries, None)
  let stamped_event = {
    use kind <- decode.field("type", decode.string)
    use text <- decode.field("text", decode.string)
    use saved_at <- decode.optional_field(
      "timestamp",
      None,
      decode.optional(decode.int),
    )
    decode.success(#(kind, text, saved_at))
  }
  list.map(snapshot, fn(event) { json.parse(event, stamped_event) })
  |> should.equal([
    Ok(#("user", "legacy", None)),
    Ok(#("user", "current", Some(timestamp))),
    Ok(#("message", "answer", Some(timestamp))),
  ])
  let assert [legacy_event, _, _] = snapshot
  string.contains(legacy_event, "\"timestamp\"") |> should.be_false

  // The live acceptance/completion renderers use the same committed value.
  let live = [
    view.user("current", "chat", Some("client-1"), Some(timestamp)),
    ..view.assistant_message(types.Assistant("answer"), Some(timestamp))
  ]
  list.map(live, fn(event) { json.parse(event, stamped_event) })
  |> should.equal([
    Ok(#("user", "current", Some(timestamp))),
    Ok(#("message", "answer", Some(timestamp))),
  ])

  runtime.stop(host)
  let assert Ok(restarted) = runtime.start(path)
  let ledger = runtime.ledger(restarted)
  let assert Ok(_) = conversation.initialise(ledger)
  conversation.load_entries(ledger, "timestamped") |> should.equal(Ok(entries))
  let assert Ok(restored) = conversation.load_entries(ledger, "timestamped")
  view.snapshot(ledger, restored, None) |> should.equal(snapshot)
  runtime.stop(restarted)
  cleanup(path)
}
