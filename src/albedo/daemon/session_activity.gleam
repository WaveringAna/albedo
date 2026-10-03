//// One bounded live tail per session actor, shared by every subscriber.

import albedo/daemon/conversation
import albedo/daemon/mail
import albedo/daemon/turn
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

pub type Status {
  Status(
    phase: String,
    run_id: Option(String),
    interrupt_requested: Bool,
    blocking_reason: Option(String),
  )
}

pub type Line {
  Line(kind: String, text: String)
}

pub type Input {
  Input(id: String, source: String, bytes: Int)
}

pub type Answer {
  Answer(id: String, bytes: Int)
}

pub type Projection {
  Projection(
    lines: List(Line),
    output_scalars: Int,
    output_utf8_bytes: Int,
    observed_at: Int,
    latest_input: Option(Input),
    latest_answer: Option(Answer),
    streamed_answer: Bool,
    current_request: Option(mail.Request),
    latest_progress: Option(String),
  )
}

pub fn new(now: Int) -> Projection {
  Projection([], 0, 0, now, None, None, False, None, None)
}

pub fn status(
  activity: turn.Activity,
  preparing: Bool,
  blocking_reason: Option(String),
) -> Status {
  case turn.running(activity) {
    None ->
      Status(
        case preparing {
          True -> "preparing"
          False -> "idle"
        },
        None,
        False,
        blocking_reason,
      )
    Some(run) ->
      Status(
        case run.cancelled, run.work {
          True, _ -> "interrupting"
          _, turn.Compaction(..) -> "compacting"
          _, turn.Background(_) -> "generating"
          _, turn.Turn(Some(stage)) ->
            case stage {
              conversation.Tool -> "running"
              _ -> "generating"
            }
          _, turn.Turn(None) -> "preparing"
        },
        Some(run.id),
        run.cancelled,
        blocking_reason,
      )
  }
}

pub fn output(
  projection: Projection,
  kind: String,
  text: String,
) -> Projection {
  case text {
    "" -> projection
    _ ->
      Projection(
        ..append(projection, kind, text),
        output_scalars: projection.output_scalars
          + list.length(string.to_utf_codepoints(text)),
        output_utf8_bytes: projection.output_utf8_bytes + string.byte_size(text),
        streamed_answer: projection.streamed_answer || kind == "assistant",
      )
  }
}

pub fn input(
  projection: Projection,
  id: String,
  source: String,
  text: String,
) -> Projection {
  case projection.latest_input {
    Some(Input(previous, _, _)) if previous == id -> projection
    _ ->
      Projection(
        ..append(projection, "input", text),
        latest_input: Some(Input(id, source, string.byte_size(text))),
      )
  }
}

pub fn answer(projection: Projection, id: String, text: String) -> Projection {
  let completed = case projection.streamed_answer {
    True -> projection
    False -> output(projection, "assistant", text)
  }
  Projection(
    ..completed,
    latest_answer: Some(Answer(id, string.byte_size(text))),
    streamed_answer: False,
  )
}

pub fn append(
  projection: Projection,
  kind: String,
  text: String,
) -> Projection {
  // Keep the current partial line as the final element. A trailing newline
  // leaves an empty partial line, so a later delta cannot join a closed line.
  let parts = string.split(text, "\n")
  let lines = case list.reverse(projection.lines), parts {
    [Line(previous_kind, previous_text), ..rest], [first, ..remaining]
      if previous_kind == kind && { kind == "assistant" || kind == "thinking" }
    ->
      list.reverse(rest)
      |> list.append([Line(kind, tail(previous_text <> first))])
      |> append_lines(kind, remaining)
    _, _ -> append_lines(projection.lines, kind, parts)
  }
  Projection(
    ..projection,
    lines: list.drop(lines, int.max(0, list.length(lines) - 12)),
  )
}

fn append_lines(
  lines: List(Line),
  kind: String,
  parts: List(String),
) -> List(Line) {
  list.fold(parts, lines, fn(lines, text) {
    let lines = list.append(lines, [Line(kind, tail(text))])
    list.drop(lines, int.max(0, list.length(lines) - 12))
  })
}

fn tail(text: String) -> String {
  let scalars = string.to_utf_codepoints(text)
  list.drop(scalars, int.max(0, list.length(scalars) - 256))
  |> string.from_utf_codepoints
}

/// A new parent request invalidates progress belonging to the preceding work.
pub fn request(
  projection: Projection,
  request: Option(mail.Request),
) -> Projection {
  case request == projection.current_request {
    True -> projection
    False ->
      Projection(..projection, current_request: request, latest_progress: None)
  }
}
