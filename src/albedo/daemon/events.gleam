import albedo/daemon/note
import albedo/daemon/store
import albedo/daemon/transcript
import albedo/daemon/usage
import albedo/harness/extensions/python/cells as journal
import albedo/openai_api/types
import gleam/dict
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub fn event(kind: String, fields: List(#(String, json.Json))) -> String {
  json.object([#("type", json.string(kind)), ..fields]) |> json.to_string
}

pub fn text(kind: String, value: String) -> String {
  event(kind, [#("text", json.string(value))])
}

pub fn stream_event(
  id: String,
  step: Int,
  incoming: types.Event,
) -> Option(String) {
  case incoming {
    types.TextDelta(_, _, "") -> None
    types.TextDelta(_, _, value) -> Some(text("text", value))
    types.ThinkingDelta("") -> None
    types.ThinkingDelta(value) -> Some(text("thinking", value))
    types.ArgumentsDelta(_, "") -> None
    types.ArgumentsDelta(index, value) ->
      Some(
        event("arguments_delta", [
          #(
            "callId",
            json.string(
              id <> ":" <> int.to_string(step) <> ":" <> int.to_string(index),
            ),
          ),
          #("text", json.string(value)),
        ]),
      )
    types.Started(_) -> Some(event("turn_started", []))
  }
}

pub fn phase(value: String) -> String {
  event("phase", [#("phase", json.string(value))])
}

pub fn progress(id: String, name: String, phase: String) -> String {
  event("tool_progress", [
    #(
      "progress",
      json.object([
        #("callId", json.string(id)),
        #("name", json.string(name)),
        #("phase", json.string(phase)),
      ]),
    ),
  ])
}

pub fn tool(
  store: store.Store,
  call: types.ToolCall,
  output: String,
  images: List(types.Image),
) -> String {
  let trace =
    json.parse(output, decode.field("cell_id", decode.string, decode.success))
    |> result.map(fn(id) { journal.trace(store, id) })
    |> result.unwrap(None)
  event("tool", [
    #("callId", json.string(call.id)),
    #("name", json.string(call.name)),
    #("args", json.string(call.arguments)),
    #("result", json.string(output)),
    #("trace", case trace {
      Some(value) -> value
      None -> json.null()
    }),
    #("images", json.array(images, image_metadata)),
  ])
}

/// Text rendered as an assistant message in the transcript.
pub fn visible_assistant_text(input: types.Input) -> Option(String) {
  let text = case input {
    types.Assistant(value) -> value
    types.Replay(item) ->
      case item_kind(item) {
        "reasoning" -> ""
        _ -> output_text(item)
      }
    _ -> ""
  }
  case text {
    "" -> None
    value -> Some(value)
  }
}

fn timestamp_field(timestamp: Option(Int)) -> List(#(String, json.Json)) {
  case timestamp {
    Some(value) -> [#("timestamp", json.int(value))]
    None -> []
  }
}

fn user_event(
  text: String,
  source: String,
  client_id: Option(String),
  timestamp: Option(Int),
  fields: List(#(String, json.Json)),
) -> String {
  let client_fields = case client_id {
    Some(value) -> [#("clientId", json.string(value))]
    None -> []
  }
  event("user", [
    #("text", json.string(text)),
    #("source", json.string(source)),
    #("triggeredAt", json.string("")),
    ..list.append(
      fields,
      list.append(client_fields, timestamp_field(timestamp)),
    )
  ])
}

pub fn user(
  text: String,
  source: String,
  client_id: Option(String),
  timestamp: Option(Int),
) -> String {
  user_event(text, source, client_id, timestamp, [])
}

/// User-facing streams carry safe image metadata; the durable base64 payload
/// stays in the transcript and is sent only to the selected model provider.
pub fn user_image(
  text: String,
  source: String,
  client_id: Option(String),
  timestamp: Option(Int),
  image: types.Image,
) -> String {
  user_event(text, source, client_id, timestamp, [
    #("image", image_metadata(image)),
  ])
}

/// What clients show of an image: never its payload.
fn image_metadata(image: types.Image) -> json.Json {
  let #(mime_type, width, height, bytes) = types.image_meta(image)
  json.object([
    #("mimeType", json.string(mime_type)),
    #("width", json.int(width)),
    #("height", json.int(height)),
    #("bytes", json.int(bytes)),
  ])
}

pub fn assistant_message(
  input: types.Input,
  timestamp: Option(Int),
) -> List(String) {
  case visible_assistant_text(input) {
    Some(value) -> [
      event("message", [
        #("role", json.string("assistant")),
        #("text", json.string(value)),
        ..timestamp_field(timestamp)
      ]),
    ]
    None -> []
  }
}

pub fn snapshot(
  store: store.Store,
  entries: List(transcript.Entry),
  latest_usage: Option(usage.Metadata),
) -> List(String) {
  let tool_calls = calls_by_id(entries)
  let rendered = list.flat_map(entries, render(store, tool_calls, _))
  case latest_usage {
    Some(metadata) -> list.append(rendered, [usage.event(metadata)])
    None -> rendered
  }
}

/// Rendered transcript rows, each followed by a `committed` marker naming
/// its row: a client stamps what it shows with the rows it came from, and so
/// knows where to resume when it asks for older history.
pub fn rows(
  store: store.Store,
  entries: List(transcript.SourcedEntry),
) -> List(String) {
  let tool_calls = calls_by_id(list.map(entries, fn(item) { item.entry }))
  list.flat_map(entries, fn(item) {
    case render(store, tool_calls, item.entry) {
      [] -> []
      events -> list.append(events, [committed(item.source.seq)])
    }
  })
}

/// Where a rendered page starts: `before` is its first row, the cursor for
/// the next older page, and `more` says whether one exists.
pub fn page_fields(
  entries: List(transcript.SourcedEntry),
  more: Bool,
) -> List(#(String, json.Json)) {
  case entries {
    [first, ..] -> [
      #("before", json.int(first.source.seq)),
      #("more", json.bool(more)),
    ]
    [] -> [#("more", json.bool(False))]
  }
}

/// Everything shown so far is covered by transcript rows up to `seq`.
pub fn committed(seq: Int) -> String {
  event("committed", [#("seq", json.int(seq))])
}

fn calls_by_id(
  entries: List(transcript.Entry),
) -> dict.Dict(String, types.ToolCall) {
  list.flat_map(entries, fn(entry) { calls(entry.input) })
  |> list.map(fn(call) { #(call.id, call) })
  |> dict.from_list
}

fn render(
  store: store.Store,
  tool_calls: dict.Dict(String, types.ToolCall),
  entry: transcript.Entry,
) -> List(String) {
  case entry.input {
    types.User(value) ->
      case note.parse(value) {
        Some(#(origin, body)) -> [user(body, origin, None, entry.timestamp)]
        None -> [user(value, "chat", None, entry.timestamp)]
      }
    types.UserImage(value, image) -> [
      user_image(value, "user", None, entry.timestamp, image),
    ]
    types.Assistant(_) -> assistant_message(entry.input, entry.timestamp)
    types.ToolOutput(id, output, images) ->
      case dict.get(tool_calls, id) {
        Ok(call) -> [tool(store, call, output, images)]
        Error(_) -> []
      }
    types.Replay(item) -> {
      let thinking = thinking_text(item)
      list.append(
        case thinking {
          "" -> []
          _ -> [event("thinking", [#("text", json.string(thinking))])]
        },
        assistant_message(entry.input, entry.timestamp),
      )
    }
  }
}

pub fn output_text(item: types.ReplayItem) -> String {
  case types.replay_protocol(item) {
    types.ChatCompletions ->
      types.inspect_item(
        item,
        decode.field("content", decode.optional(decode.string), decode.success),
      )
      |> result.unwrap(None)
      |> fn(value) {
        case value {
          Some(text) -> text
          None -> ""
        }
      }
    types.Responses -> {
      let part = decode.field("text", decode.string, decode.success)
      types.inspect_item(
        item,
        decode.field(
          "content",
          decode.list(decode.one_of(part, [decode.success("")])),
          decode.success,
        ),
      )
      |> result.unwrap([])
      |> list.fold("", fn(a, b) { a <> b })
    }
  }
}

/// Reasoning text saved with a provider item, rendered apart from the answer.
pub fn thinking_text(item: types.ReplayItem) -> String {
  case types.replay_protocol(item) {
    types.ChatCompletions -> chat_thinking(item)
    types.Responses -> responses_thinking(item)
  }
}

fn optional_text(item: types.ReplayItem, name: String) -> Option(String) {
  types.inspect_item(
    item,
    decode.field(name, decode.optional(decode.string), decode.success),
  )
  |> result.unwrap(None)
}

fn chat_thinking(item: types.ReplayItem) -> String {
  case
    optional_text(item, "reasoning_content"),
    optional_text(item, "reasoning")
  {
    Some(value), _ if value != "" -> value
    _, Some(value) if value != "" -> value
    _, _ -> ""
  }
}

fn item_kind(item: types.ReplayItem) -> String {
  types.inspect_item(item, decode.field("type", decode.string, decode.success))
  |> result.unwrap("")
}

fn responses_thinking(item: types.ReplayItem) -> String {
  case item_kind(item) {
    "reasoning" -> {
      let part = decode.field("text", decode.string, decode.success)
      let fragments = fn(name: String) {
        types.inspect_item(
          item,
          decode.field(name, decode.list(part), decode.success),
        )
        |> result.unwrap([])
      }
      // Prefer the human-readable summary; raw reasoning_text is a fallback.
      let parts = case fragments("summary") {
        [] -> fragments("content")
        summary -> summary
      }
      string.join(parts, "\n\n")
    }
    _ -> ""
  }
}

pub fn calls(input: types.Input) -> List(types.ToolCall) {
  let function = {
    use name <- decode.field("name", decode.string)
    use arguments <- decode.field("arguments", decode.string)
    decode.success(#(name, arguments))
  }
  case input {
    types.Replay(item) ->
      case types.replay_protocol(item) {
        types.Responses -> {
          let decoder = {
            use kind <- decode.field("type", decode.string)
            use id <- decode.field("call_id", decode.string)
            use pair <- decode.then(function)
            case kind {
              "function_call" ->
                decode.success(types.ToolCall(id, pair.0, pair.1))
              _ -> decode.failure(types.ToolCall("", "", ""), "function_call")
            }
          }
          case types.inspect_item(item, decoder) {
            Ok(call) -> [call]
            Error(_) -> []
          }
        }
        types.ChatCompletions -> {
          let decoder = {
            use id <- decode.field("id", decode.string)
            use pair <- decode.field("function", function)
            decode.success(types.ToolCall(id, pair.0, pair.1))
          }
          types.inspect_item(
            item,
            decode.field("tool_calls", decode.list(decoder), decode.success),
          )
          |> result.unwrap([])
        }
      }
    _ -> []
  }
}
