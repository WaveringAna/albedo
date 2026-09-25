import albedo/daemon/events as view
import albedo/daemon/note
import albedo/daemon/session
import albedo/daemon/transcript
import albedo/harness/runtime
import albedo/openai_api/types
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/result
import gleeunit/should

fn types_of(events: List(String)) -> List(String) {
  list.filter_map(events, fn(event) {
    case
      json.parse(event, decode.field("type", decode.string, decode.success))
    {
      Ok(value) -> Ok(value)
      Error(_) -> Error(Nil)
    }
  })
}

fn texts(events: List(String), kind: String) -> List(String) {
  let decoder = {
    use name <- decode.field("type", decode.string)
    use text <- decode.field("text", decode.string)
    decode.success(#(name, text))
  }
  list.filter_map(events, fn(event) {
    use #(name, text) <- result.try(
      json.parse(event, decoder) |> result.map_error(fn(_) { Nil }),
    )
    case name == kind {
      True -> Ok(text)
      False -> Error(Nil)
    }
  })
}

/// Replayed history must show thinking apart from the answer, and never leak
/// reasoning (or a provider's raw reasoning_text) into the assistant message.
pub fn snapshot_surfaces_saved_reasoning_apart_from_the_answer_test() {
  let assert Ok(host) = runtime.start(":memory:")
  let store = runtime.ledger(host)
  let assert Ok(chat) =
    json.parse(
      "{\"role\":\"assistant\",\"content\":\"answer\",\"reasoning_content\":\"think\"}",
      types.replay_decoder(types.ChatCompletions),
    )
  let chat_events =
    view.snapshot(
      store,
      [transcript.Entry(types.Replay(chat), None, None)],
      None,
    )
  types_of(chat_events) |> should.equal(["thinking", "message"])
  texts(chat_events, "thinking") |> should.equal(["think"])
  texts(chat_events, "message") |> should.equal(["answer"])

  let assert Ok(reasoning) =
    json.parse(
      "{\"type\":\"reasoning\",\"id\":\"rs_1\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"why\"}],\"content\":[{\"type\":\"reasoning_text\",\"text\":\"raw\"}]}",
      types.replay_decoder(types.Responses),
    )
  let assert Ok(message) =
    json.parse(
      "{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"answer\"}]}",
      types.replay_decoder(types.Responses),
    )
  let response_events =
    view.snapshot(
      store,
      [
        transcript.Entry(types.Replay(reasoning), None, None),
        transcript.Entry(types.Replay(message), None, None),
      ],
      None,
    )
  types_of(response_events) |> should.equal(["thinking", "message"])
  texts(response_events, "thinking") |> should.equal(["why"])
  texts(response_events, "message") |> should.equal(["answer"])
  runtime.stop(host)
}

pub fn snapshot_omits_continue_notice_test() {
  let assert Ok(host) = runtime.start(":memory:")
  let events =
    view.snapshot(
      runtime.ledger(host),
      [transcript.Entry(types.User(session.continue_prompt), None, None)],
      None,
    )
  types_of(events) |> should.equal([])
  runtime.stop(host)
}

/// A reloaded transcript labels a note by its origin and shows its body, and
/// labels a typed message the way the live stream does.
pub fn snapshot_labels_notes_by_origin_test() {
  let assert Ok(host) = runtime.start(":memory:")
  let decoder = {
    use source <- decode.field("source", decode.string)
    use text <- decode.field("text", decode.string)
    decode.success(#(source, text))
  }
  view.snapshot(
    runtime.ledger(host),
    [
      types.User("hello"),
      types.User(note.wrap("daemon restart", "resumed")),
      types.User("<system-note>legacy</system-note>"),
    ]
      |> list.map(transcript.Entry(_, None, None)),
    None,
  )
  |> list.filter_map(fn(event) {
    json.parse(event, decoder) |> result.replace_error(Nil)
  })
  |> should.equal([
    #("chat", "hello"),
    #("daemon restart", "resumed"),
    #("note", "legacy"),
  ])
  runtime.stop(host)
}
