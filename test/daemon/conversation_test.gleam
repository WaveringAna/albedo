import albedo/daemon/conversation
import albedo/daemon/events as view
import albedo/daemon/store
import albedo/daemon/transcript
import albedo/daemon/usage
import albedo/harness/runtime
import albedo/openai_api/types
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
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
  )
}

pub fn title_is_a_safe_bounded_unicode_preview_test() {
  conversation.title("  first\nsecond\tline  ")
  |> should.equal("first second line")
  conversation.title("\u{1b}[31m red\u{202e}hidden")
  |> should.equal("[31m red hidden")
  conversation.title("\n\t") |> should.equal("new session")

  let family = "👩‍💻"
  let bounded = conversation.title(string.repeat(family, 80) <> "x")
  string.length(bounded) |> should.equal(80)
  bounded |> should.equal(string.repeat(family, 79) <> "…")
}

pub fn latest_user_title_survives_restart_and_legacy_migration_test() {
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

pub fn last_assistant_at_tracks_only_visible_assistant_messages_test() {
  let path = temporary_database()
  let assert Ok(host) = runtime.start(path)
  let ledger = runtime.ledger(host)
  let assert Ok(_) = conversation.initialise(ledger)
  let assert Ok(_) = conversation.create(ledger, session("session"))
  let assert Ok([initial]) = conversation.list(ledger)
  initial.last_assistant_at |> should.equal(None)

  let assert Ok(_) =
    store.query(ledger, fn(db) {
      sqlight.exec(
        "UPDATE sessions SET last_assistant_at=7 WHERE id='session'",
        db,
      )
    })
  let assert Ok(reasoning) =
    json.parse(
      "{\"type\":\"reasoning\",\"id\":\"rs_1\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"why\"}]}",
      types.replay_decoder(types.Responses),
    )
  let assert Ok(message) =
    json.parse(
      "{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"visible answer\"}]}",
      types.replay_decoder(types.Responses),
    )

  let non_messages = [
    [types.User("prompt")],
    [types.ToolOutput("call", "result", [])],
    [types.Replay(reasoning)],
    [types.Assistant("")],
  ]
  list.try_each(non_messages, fn(inputs) {
    use _ <- result.try(conversation.commit(
      ledger,
      "session",
      inputs,
      conversation.Model,
    ))
    use infos <- result.try(conversation.list(ledger))
    case infos {
      [info] -> {
        info.last_assistant_at |> should.equal(Some(7))
        Ok(Nil)
      }
      _ -> Error("expected one session")
    }
  })
  |> should.be_ok

  let assert Ok(_) =
    conversation.commit(
      ledger,
      "session",
      [types.Replay(message)],
      conversation.Idle,
    )
  let assert Ok([answered]) = conversation.list(ledger)
  let assert Some(timestamp) = answered.last_assistant_at
  let assert True = timestamp > 7
  runtime.stop(host)
  cleanup(path)
}

pub fn list_orders_sessions_by_latest_activity_test() {
  let path = temporary_database()
  let assert Ok(host) = runtime.start(path)
  let ledger = runtime.ledger(host)
  let assert Ok(_) = conversation.initialise(ledger)
  let assert Ok(_) = conversation.create(ledger, session("older"))
  let assert Ok(_) = conversation.create(ledger, session("newer"))
  let assert Ok([newer, older]) = conversation.list(ledger)
  newer.id |> should.equal("newer")
  older.id |> should.equal("older")

  let assert Ok(_) =
    conversation.commit(
      ledger,
      "older",
      [types.User("latest task")],
      conversation.Model,
    )
  let assert Ok([active, _]) = conversation.list(ledger)
  active.id |> should.equal("older")
  active.title |> should.equal("latest task")

  let assert Ok(_) =
    conversation.commit(
      ledger,
      "newer",
      [types.Assistant("assistant activity")],
      conversation.Idle,
    )
  let assert Ok([active, _]) = conversation.list(ledger)
  active.id |> should.equal("newer")
  active.title |> should.equal("new session")
  runtime.stop(host)
  cleanup(path)
}

pub fn migration_recovers_placeholder_titles_and_activity_order_test() {
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

pub fn usage_metadata_roundtrips_without_touching_conversation_activity_test() {
  let path = temporary_database()
  let assert Ok(host) = runtime.start(path)
  let ledger = runtime.ledger(host)
  let assert Ok(_) = conversation.initialise(ledger)
  let assert Ok(_) = conversation.create(ledger, session("measured"))
  let assert Ok(_) = conversation.create(ledger, session("newer"))
  let measured =
    usage.Metadata(
      "openai/gpt-test",
      1_735_689_600_123,
      Some(usage.Tokens(120, 30, Some(0))),
    )
  let assert Ok(_) = conversation.record_usage(ledger, "measured", measured)
  let assert Ok([newer, unchanged]) = conversation.list(ledger)
  newer.id |> should.equal("newer")
  unchanged.id |> should.equal("measured")
  unchanged.title |> should.equal("new session")
  unchanged.last_assistant_at |> should.equal(None)
  conversation.load(ledger, "measured") |> should.equal(Ok([]))
  conversation.load_usage(ledger, "measured")
  |> should.equal(Ok(Some(measured)))
  let before = view.snapshot(ledger, [], Some(measured))
  runtime.stop(host)

  let assert Ok(restarted) = runtime.start(path)
  let ledger = runtime.ledger(restarted)
  let assert Ok(_) = conversation.initialise(ledger)
  let assert Ok(Some(restored)) = conversation.load_usage(ledger, "measured")
  let after = view.snapshot(ledger, [], Some(restored))
  after |> should.equal(before)
  let assert [event] = after
  let event_decoder = {
    use model <- decode.field("model", decode.string)
    use prompt <- decode.field("promptTokens", decode.int)
    use completion <- decode.field("completionTokens", decode.int)
    use cached <- decode.field("cachedPromptTokens", decode.int)
    use total <- decode.field("totalTokens", decode.int)
    use recorded_at <- decode.field("recordedAt", decode.int)
    decode.success(#(model, prompt, completion, cached, total, recorded_at))
  }
  json.parse(event, event_decoder)
  |> should.equal(Ok(#("openai/gpt-test", 120, 30, 0, 150, 1_735_689_600_123)))

  let unreported = usage.Metadata("openai/gpt-next", 1_735_689_600_456, None)
  let assert Ok(_) = conversation.record_usage(ledger, "measured", unreported)
  conversation.load_usage(ledger, "measured")
  |> should.equal(Ok(Some(unreported)))
  let assert [clearing_event] = view.snapshot(ledger, [], Some(unreported))
  json.parse(
    clearing_event,
    decode.optional_field(
      "promptTokens",
      None,
      decode.optional(decode.int),
      decode.success,
    ),
  )
  |> should.equal(Ok(None))
  runtime.stop(restarted)
  cleanup(path)
}

pub fn transcript_timestamps_migrate_without_invention_and_roundtrip_test() {
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
        "ALTER TABLE transcript DROP COLUMN timestamp; ALTER TABLE transcript DROP COLUMN provider",
        db,
      )
    })
  let assert Ok(_) = conversation.initialise(ledger)
  conversation.load_entries(ledger, "timestamped")
  |> should.equal(Ok([transcript.Entry(types.User("legacy"), None, None)]))

  let new_inputs = [types.User("current"), types.Assistant("answer")]
  let assert Ok(timestamp) =
    conversation.commit(ledger, "timestamped", new_inputs, conversation.Idle)
  let assert True = timestamp > 1_000_000_000_000
  let assert Ok(entries) = conversation.load_entries(ledger, "timestamped")
  entries
  |> should.equal([
    transcript.Entry(types.User("legacy"), None, None),
    transcript.Entry(types.User("current"), Some(timestamp), None),
    transcript.Entry(types.Assistant("answer"), Some(timestamp), None),
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

pub fn provider_provenance_backfills_on_switch_and_survives_restart_test() {
  let path = temporary_database()
  let assert Ok(host) = runtime.start(path)
  let ledger = runtime.ledger(host)
  let assert Ok(_) = conversation.initialise(ledger)
  let assert Ok(_) = conversation.create(ledger, session("provenance"))
  let original = [types.User("old provider input"), types.Assistant("answer")]
  let assert Ok(old_timestamp) =
    conversation.commit(ledger, "provenance", original, conversation.Idle)
  let assert Ok(before_payloads) =
    store.query(ledger, fn(db) {
      sqlight.query(
        "SELECT payload FROM transcript WHERE session=? ORDER BY seq",
        db,
        [sqlight.text("provenance")],
        decode.field(0, decode.bit_array, decode.success),
      )
    })
  let assert Ok(_) =
    conversation.set_configuration(
      ledger,
      "provenance",
      "new-provider",
      "new-model",
      types.ChatCompletions,
    )
  let assert Ok(after_payloads) =
    store.query(ledger, fn(db) {
      sqlight.query(
        "SELECT payload FROM transcript WHERE session=? ORDER BY seq",
        db,
        [sqlight.text("provenance")],
        decode.field(0, decode.bit_array, decode.success),
      )
    })
  after_payloads |> should.equal(before_payloads)
  let assert Ok(new_timestamp) =
    conversation.commit_from(
      ledger,
      "provenance",
      [types.User("new provider input")],
      conversation.Idle,
      Some("new-provider"),
    )
  let expected = [
    transcript.Entry(
      types.User("old provider input"),
      Some(old_timestamp),
      Some("provider"),
    ),
    transcript.Entry(
      types.Assistant("answer"),
      Some(old_timestamp),
      Some("provider"),
    ),
    transcript.Entry(
      types.User("new provider input"),
      Some(new_timestamp),
      Some("new-provider"),
    ),
  ]
  conversation.load_entries(ledger, "provenance") |> should.equal(Ok(expected))
  conversation.load(ledger, "provenance")
  |> should.equal(
    Ok([
      types.User("old provider input"),
      types.Assistant("answer"),
      types.User("new provider input"),
    ]),
  )

  runtime.stop(host)
  let assert Ok(restarted) = runtime.start(path)
  let ledger = runtime.ledger(restarted)
  let assert Ok(_) = conversation.initialise(ledger)
  conversation.load_entries(ledger, "provenance") |> should.equal(Ok(expected))
  let assert Ok([info]) = conversation.list(ledger)
  #(info.provider, info.model, info.protocol)
  |> should.equal(#("new-provider", "new-model", types.ChatCompletions))
  runtime.stop(restarted)
  cleanup(path)
}
