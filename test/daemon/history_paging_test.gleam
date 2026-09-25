import albedo/daemon/conversation
import albedo/daemon/history
import albedo/daemon/session
import albedo/daemon/transcript
import albedo/harness/runtime
import albedo/openai_api/types
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should

@external(erlang, "albedo_runtime_test_support", "temporary_database")
fn temporary_database() -> String

@external(erlang, "albedo_runtime_test_support", "cleanup")
fn cleanup(path: String) -> Nil

fn info(id: String) -> conversation.Info {
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

/// Rows 1..7: u1 a1 u2 a2 a3 u3 a4.
fn seeded() {
  let path = temporary_database()
  let assert Ok(host) = runtime.start(path)
  let ledger = runtime.ledger(host)
  let assert Ok(_) = conversation.initialise(ledger)
  let assert Ok(_) = conversation.create(ledger, info("s"))
  let assert Ok(_) =
    conversation.commit(
      ledger,
      "s",
      [
        types.User("u1"),
        types.Assistant("a1"),
        types.User("u2"),
        types.Assistant("a2"),
        types.Assistant("a3"),
        types.User("u3"),
        types.Assistant("a4"),
      ],
      conversation.Idle,
    )
  #(path, host)
}

fn texts(entries: List(transcript.SourcedEntry)) -> List(String) {
  list.map(entries, fn(item) {
    case item.entry.input {
      types.User(text) | types.Assistant(text) -> text
      _ -> "?"
    }
  })
}

pub fn a_tail_starts_at_a_user_message_and_reports_older_rows_test() {
  let #(path, host) = seeded()
  let ledger = runtime.ledger(host)

  let assert Ok(#(newest, more)) = conversation.load_tail(ledger, "s", None, 2)
  texts(newest) |> should.equal(["u3", "a4"])
  more |> should.be_true

  // A page may start on any row but a tool result.
  let assert Ok(#(older, more)) =
    conversation.load_tail(ledger, "s", Some(6), 2)
  texts(older) |> should.equal(["a2", "a3"])
  more |> should.be_true

  // Reading to the transcript's start reports nothing older.
  let assert Ok(#(first, more)) =
    conversation.load_tail(ledger, "s", Some(4), 10)
  texts(first) |> should.equal(["u1", "a1", "u2"])
  more |> should.be_false

  let assert Ok(#([], False)) = conversation.load_tail(ledger, "s", Some(1), 5)
  runtime.stop(host)
  cleanup(path)
}

pub fn a_page_never_starts_on_a_tool_result_test() {
  let path = temporary_database()
  let assert Ok(host) = runtime.start(path)
  let ledger = runtime.ledger(host)
  let assert Ok(_) = conversation.initialise(ledger)
  let assert Ok(_) = conversation.create(ledger, info("t"))
  let assert Ok(_) =
    conversation.commit(
      ledger,
      "t",
      [
        types.User("u"),
        types.Assistant("a"),
        types.ToolOutput("c1", "one", []),
        types.ToolOutput("c2", "two", []),
      ],
      conversation.Idle,
    )
  // The newest row is a tool result: the page widens back to "a" only.
  let assert Ok(#(page, more)) = conversation.load_tail(ledger, "t", None, 1)
  list.map(page, fn(item) { item.source.seq }) |> should.equal([2, 3, 4])
  more |> should.be_true
  runtime.stop(host)
  cleanup(path)
}

pub fn a_rendered_page_marks_its_rows_and_cursor_test() {
  let #(path, host) = seeded()
  let assert Ok(body) = history.rendered(runtime.ledger(host), "s", Some(6), 2)
  body |> string.contains("\"text\":\"a2\"") |> should.be_true
  body |> string.contains("\"text\":\"u3\"") |> should.be_false
  body
  |> string.contains("{\"type\":\"committed\",\"seq\":5}")
  |> should.be_true
  body |> string.ends_with("\"before\":4,\"more\":true}") |> should.be_true
  runtime.stop(host)
  cleanup(path)
}

pub fn a_tail_reset_replays_only_the_newest_turn_test() {
  let #(path, host) = seeded()
  let assert Ok(worker) = session.start(host, info("s"), "/tmp")
  let page = session.read(worker, -1, Some(2))
  let assert [reset, ..events] = page.events
  reset |> should.equal("{\"type\":\"reset\",\"before\":6,\"more\":true}")
  list.any(events, string.contains(_, "\"u3\"")) |> should.be_true
  list.any(events, string.contains(_, "\"u2\"")) |> should.be_false
  list.any(events, string.contains(_, "\"committed\"")) |> should.be_true
  // Without a tail the whole transcript replays, as older clients expect.
  let full = session.read(worker, -1, None)
  list.any(full.events, string.contains(_, "\"u1\"")) |> should.be_true
  session.close(worker)
  runtime.stop(host)
  cleanup(path)
}
