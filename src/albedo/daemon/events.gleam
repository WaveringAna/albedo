//// Native stream observations. The session owner assigns sequence numbers and
//// serializes each envelope once; workers never construct public JSON events.

import albedo/daemon/http_api
import albedo/daemon/http_history
import albedo/daemon/mail
import albedo/daemon/operations
import albedo/daemon/session_activity
import albedo/daemon/tool_progress as progress
import albedo/daemon/transcript
import albedo/daemon/usage
import albedo/harness/compaction
import albedo/openai_api/types
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub type Event {
  Status(session_activity.Status)
  Input(operations.InputOutcome, Option(operations.Display))
  Text(run_id: String, message_id: String, text: String)
  Thinking(
    run_id: String,
    message_id: String,
    text: String,
    elapsed_ms: Option(Int),
  )
  Message(http_history.Entry)
  ToolProgress(Option(progress.Snapshot))
  Tool(
    call: types.ToolCall,
    output: String,
    trace: Option(json.Json),
    progress_id: String,
    position: Int,
  )
  Note(entry_id: String, origin: String, text: String, mail: Option(json.Json))
  Retry(run_id: String, attempt: Int, reason: String, delay_ms: Int)
  Usage(usage.Metadata)
  Committed(high_water: Int)
  TurnCompleted(run_id: String, state: String, input_ids: List(String))
  Compacted(
    observation: Option(compaction.Observation),
    evicted: Int,
    summary: String,
  )
  Failure(run_id: Option(String), code: String, message: String)
  Invalidate(kind: String, url: String)
  /// A worker liveness handshake, never a public observation.
  Checkpoint
  ProviderStarted
}

pub fn error(message: String) -> Event {
  Failure(None, "session_error", message)
}

pub fn note(origin: String, text: String) -> Event {
  Note(mail.new_id(), origin, text, None)
}

pub fn stream_event(
  run_id: String,
  message_id: String,
  incoming: types.Event,
) -> Option(Event) {
  case incoming {
    types.TextDelta(_, _, "") | types.ThinkingDelta("") -> None
    types.TextDelta(output_index, content_index, value) ->
      Some(Text(
        run_id,
        message_id
          <> ":"
          <> int.to_string(output_index)
          <> ":"
          <> int.to_string(content_index),
        value,
      ))
    types.ThinkingDelta(value) ->
      Some(Thinking(run_id, message_id <> ":thinking", value, None))
    types.ArgumentsDelta(_, _, _) | types.Started(_) -> None
  }
}

pub fn tool_progress_event(snapshot: progress.Snapshot) -> Event {
  ToolProgress(Some(snapshot))
}

pub fn clear_tool_progress() -> Event {
  ToolProgress(None)
}

pub fn encode(session: String, sequence: Int, event: Event) -> json.Json {
  let #(kind, data) = case event {
    Status(value) -> #("status", status(value))
    Input(value, _) -> #("input", json.object([#("input", input(value))]))
    Text(run_id, message_id, text) -> #(
      "text",
      delta(run_id, message_id, text, None),
    )
    Thinking(run_id, message_id, text, elapsed) -> #(
      "thinking",
      delta(run_id, message_id, text, elapsed),
    )
    Message(entry) -> #(
      "message",
      json.object([#("entry", http_history.encode(session, entry, 65_536))]),
    )
    ToolProgress(value) -> #(
      "tool_progress",
      json.object([#("progress", json.nullable(value, progress))]),
    )
    Tool(call, output, trace, progress_id, position) -> #(
      "tool",
      tool(session, call, output, trace, progress_id, position),
    )
    Note(id, origin, text, letter) -> #(
      "note",
      json.object([
        #("entry_id", json.string(id)),
        #("origin", json.string(http_api.scalar_prefix(origin, 256))),
        #("text", json.string(http_api.scalar_prefix(text, 262_144))),
        #("mail", json.nullable(letter, fn(value) { value })),
      ]),
    )
    Retry(run_id, attempt, reason, delay_ms) -> #(
      "retry",
      json.object([
        #("run_id", json.string(run_id)),
        #("attempt", json.int(attempt)),
        #("reason", http_api.reason("provider_retry", reason)),
        #("delay_ms", json.int(delay_ms)),
      ]),
    )
    Usage(metadata) -> #("usage", usage(Some(metadata)))
    Committed(high_water) -> #(
      "committed",
      json.object([#("high_water", json.int(high_water))]),
    )
    TurnCompleted(run_id, state, ids) -> #(
      "turn_completed",
      json.object([
        #("run_id", json.string(run_id)),
        #("state", json.string(state)),
        #("input_ids", json.array(list.take(ids, 200), json.string)),
        #("input_count", json.int(list.length(ids))),
        #("truncated", json.bool(list.length(ids) > 200)),
      ]),
    )
    Compacted(observation, evicted, summary) -> #(
      "compacted",
      json.object([
        #(
          "strategy",
          json.nullable(
            option.map(observation, fn(value) { value.strategy }),
            json.string,
          ),
        ),
        #("before_tokens", json.null()),
        #("after_tokens", json.null()),
        #("evicted_entries", json.int(evicted)),
        #("summary", json.string(http_api.scalar_prefix(summary, 32_768))),
      ]),
    )
    Failure(run_id, code, message) -> #(
      "error",
      json.object([
        #("run_id", json.nullable(run_id, json.string)),
        #("code", json.string(http_api.scalar_prefix(code, 100))),
        #("message", json.string(http_api.scalar_prefix(message, 4096))),
      ]),
    )
    Invalidate(kind, url) -> #(
      "invalidate",
      json.object([#("kind", json.string(kind)), #("url", json.string(url))]),
    )
    Checkpoint | ProviderStarted -> #("checkpoint", json.null())
  }
  json.object([
    #("type", json.string(kind)),
    #("sequence", json.int(sequence)),
    #("data", data),
  ])
}

fn delta(
  run_id: String,
  message_id: String,
  text: String,
  elapsed: Option(Int),
) -> json.Json {
  let fields = [
    #("run_id", json.string(run_id)),
    #("message_id", json.string(message_id)),
    #("text", json.string(text)),
  ]
  json.object(case elapsed {
    None -> fields
    Some(value) -> [#("elapsed_ms", json.int(value)), ..fields]
  })
}

fn tool(
  session: String,
  call: types.ToolCall,
  output: String,
  trace: Option(json.Json),
  progress_id: String,
  position: Int,
) -> json.Json {
  // A large completed argument document is fetched from its durable entry;
  // live publication never parses it merely to discard the value.
  let arguments = case string.byte_size(call.arguments) <= 65_536 {
    True -> transcript.argument_json(call.arguments)
    False -> json.null()
  }
  let result = json.string(output)
  let result_bytes = string.byte_size(json.to_string(result))
  let size =
    string.byte_size(json.to_string(arguments))
    + result_bytes
    + {
      option.map(trace, fn(value) { string.byte_size(json.to_string(value)) })
      |> option.unwrap(0)
    }
  let complete = string.byte_size(call.arguments) <= 65_536 && size <= 65_536
  json.object([
    #("tool_call_id", json.string(call.id)),
    #("progress_call_id", json.string(progress_id)),
    #("name", json.string(call.name)),
    #("arguments", case complete {
      True -> arguments
      False -> json.null()
    }),
    #("result", case complete {
      True -> result
      False -> json.null()
    }),
    #("trace", case complete {
      True -> json.nullable(trace, fn(value) { value })
      False -> json.null()
    }),
    #("content_complete", json.bool(complete)),
    #("reference", case complete {
      True -> json.null()
      False ->
        json.object([
          #(
            "url",
            json.string(
              "/sessions/" <> session <> "/history/" <> int.to_string(position),
            ),
          ),
          #("field", json.string("result")),
          #("bytes", json.int(result_bytes)),
        ])
    }),
  ])
}

pub fn status(value: session_activity.Status) -> json.Json {
  json.object([
    #("phase", json.string(value.phase)),
    #("run_id", json.nullable(value.run_id, json.string)),
    #("interrupt_requested", json.bool(value.interrupt_requested)),
    #(
      "blocking_reason",
      json.nullable(value.blocking_reason, http_api.reason("inputs_blocked", _)),
    ),
  ])
}

pub fn activity(value: session_activity.Projection) -> json.Json {
  let encoded = activity_value(value)
  case string.byte_size(json.to_string(encoded)) <= 16_384 {
    True -> encoded
    False ->
      case value.lines {
        [] -> encoded
        [first, ..rest] ->
          activity(
            session_activity.Projection(..value, lines: case first.text {
              "" -> rest
              text -> {
                let scalars = string.to_utf_codepoints(text)
                [
                  session_activity.Line(
                    first.kind,
                    scalars
                      |> list.drop(int.max(1, list.length(scalars) / 2))
                      |> string.from_utf_codepoints,
                  ),
                  ..rest
                ]
              }
            }),
          )
      }
  }
}

fn activity_value(value: session_activity.Projection) -> json.Json {
  json.object([
    #(
      "lines",
      json.array(value.lines, fn(line) {
        json.object([
          #("kind", json.string(line.kind)),
          #("text", json.string(line.text)),
        ])
      }),
    ),
    #("output_scalars", json.int(value.output_scalars)),
    #("output_utf8_bytes", json.int(value.output_utf8_bytes)),
    #("observed_at", timestamp(value.observed_at)),
    #(
      "current_request",
      json.nullable(value.current_request, fn(request) {
        json.object([
          #("input_id", json.string(request.id)),
          #("text", json.string(request.text)),
        ])
      }),
    ),
    #("latest_progress", json.nullable(value.latest_progress, json.string)),
    #(
      "latest_input",
      json.nullable(value.latest_input, fn(input) {
        json.object([
          #("input_id", json.string(input.id)),
          #("source", json.string(input.source)),
          #("bytes", json.int(input.bytes)),
        ])
      }),
    ),
    #(
      "latest_answer",
      json.nullable(value.latest_answer, fn(answer) {
        json.object([
          #("message_id", json.string(answer.id)),
          #("bytes", json.int(answer.bytes)),
        ])
      }),
    ),
  ])
}

pub fn progress(value: progress.Snapshot) -> json.Json {
  let fields = [
    #("call_id", json.string(value.call_id)),
    #("tool_call_id", json.nullable(value.tool_call_id, json.string)),
    #("name", json.string(value.name)),
    #("phase", json.string(value.phase)),
    #("intent", json.string("unknown")),
  ]
  json.object(case value.code {
    None -> fields
    Some(#(offset, text)) -> [
      #(
        "preview",
        json.object([
          #("offset_scalars", json.int(offset)),
          #("text", json.string(text)),
        ]),
      ),
      ..fields
    ]
  })
}

pub fn input(value: operations.InputOutcome) -> json.Json {
  let receipt = value.receipt
  let admitted = receipt.status == "accepted"
  let problem =
    json.nullable(receipt.rejection, fn(rejection) {
      http_api.problem(http_api.Failure(
        rejection.status,
        rejection.code,
        rejection.detail,
      ))
    })
  json.object([
    #("id", json.string(receipt.operation.id)),
    #("session_id", json.string(receipt.operation.target)),
    #(
      "kind",
      json.string(case receipt.operation.kind {
        "user" -> "message"
        other -> other
      }),
    ),
    #("admission", json.string(receipt.status)),
    #("http_status", json.int(receipt.http_status)),
    #("problem", problem),
    #("accepted_at", case admitted {
      True -> timestamp(receipt.created_at)
      False -> json.null()
    }),
    #("acceptance_order", case admitted {
      True -> json.int(value.acceptance_order)
      False -> json.null()
    }),
    #("delivery", json.nullable(receipt.delivery, json.string)),
    #(
      "blocking_reason",
      json.nullable(receipt.blocking_reason, http_api.reason("input_blocked", _)),
    ),
    #("transcript_position", json.nullable(receipt.committed_seq, json.int)),
    #(
      "turn",
      json.nullable(value.turn, fn(turn) {
        json.object([
          #("id", json.string(turn.id)),
          #("state", json.string(turn.state)),
          #("started_at", timestamp(turn.started_at)),
          #("ended_at", json.nullable(turn.ended_at, timestamp)),
          #("outcome", json.null()),
        ])
      }),
    ),
    #("client_id", json.nullable(receipt.operation.client_id, json.string)),
  ])
}

pub fn usage(metadata: Option(usage.Metadata)) -> json.Json {
  let tokens = option.then(metadata, fn(value) { value.tokens })
  let counter = fn(read) { json.nullable(option.map(tokens, read), json.int) }
  json.object([
    #(
      "model",
      json.nullable(
        option.map(metadata, fn(value) { value.model }),
        json.string,
      ),
    ),
    #(
      "observed_at",
      json.nullable(
        option.map(metadata, fn(value) { value.recorded_at }),
        timestamp,
      ),
    ),
    #("prompt_tokens", counter(fn(value) { value.prompt_tokens })),
    #(
      "cached_prompt_tokens",
      json.nullable(
        option.then(tokens, fn(value) { value.cached_prompt_tokens }),
        json.int,
      ),
    ),
    #(
      "cache_write_tokens",
      json.nullable(
        option.then(tokens, fn(value) { value.cache_creation_tokens }),
        json.int,
      ),
    ),
    #("completion_tokens", counter(fn(value) { value.completion_tokens })),
    #(
      "total_tokens",
      counter(fn(value) { value.prompt_tokens + value.completion_tokens }),
    ),
    #("elapsed_ms", json.null()),
    #("tokens_per_second", json.null()),
    #("context_window_tokens", json.null()),
    #("cache_ttl_seconds", json.null()),
    #("cache_fade", case option.then(metadata, fn(value) { value.cache }) {
      None -> json.array([], fn(value) { value })
      Some(fade) ->
        json.array(list.take(fade.steps, 200), fn(step) {
          json.object([
            #("at", timestamp(fade.anchor_ms + step.after_ms)),
            #("cached_tokens", json.nullable(step.cached, json.int)),
          ])
        })
    }),
  ])
}

fn timestamp(value: Int) -> json.Json {
  json.string(http_api.timestamp(value))
}

/// Advance bounded live activity from native values, without parsing an
/// envelope or reconstructing argument fragments.
pub fn observe(
  projection: session_activity.Projection,
  event: Event,
  now: Int,
) -> session_activity.Projection {
  let projection = session_activity.Projection(..projection, observed_at: now)
  case event {
    Status(value) ->
      case value.phase {
        "preparing" ->
          session_activity.Projection(..projection, streamed_answer: False)
        _ -> projection
      }
    Text(_, _, text) -> session_activity.output(projection, "assistant", text)
    Thinking(_, _, text, _) ->
      session_activity.output(projection, "thinking", text)
    Input(outcome, Some(display)) ->
      case outcome.receipt.delivery {
        Some("committed") ->
          session_activity.input(
            projection,
            outcome.receipt.operation.id,
            case display.source {
              "chat" | "continue" -> "chat"
              "mail" -> "agent"
              _ -> "system"
            },
            display.text,
          )
        _ -> projection
      }
    Message(entry) -> {
      let text =
        list.filter_map(entry.parts, fn(part) {
          case part {
            http_history.Text(_, value) -> Ok(value)
            _ -> Error(Nil)
          }
        })
        |> string.concat
      case entry.kind {
        "assistant" if text != "" ->
          session_activity.answer(projection, entry.id, text)
        "assistant" -> projection
        "user" ->
          case entry.input_id {
            None -> session_activity.append(projection, "input", text)
            Some(_) -> projection
          }
        "thinking" -> projection
        "note" | "compaction" | "image_fit" ->
          session_activity.append(projection, "note", text)
        _ -> projection
      }
    }
    Tool(_, output, _, _, _) -> {
      let text =
        json.parse(
          output,
          decode.field("output", decode.string, decode.success),
        )
        |> result.unwrap(output)
      session_activity.append(projection, "tool", text)
    }
    Note(_, "agent", text, None) ->
      session_activity.Projection(
        ..projection,
        latest_progress: Some(http_api.scalar_prefix(text, 512)),
      )
    Note(_, _, text, _) -> session_activity.append(projection, "note", text)
    Failure(_, _, text) -> session_activity.append(projection, "error", text)
    _ -> projection
  }
}
