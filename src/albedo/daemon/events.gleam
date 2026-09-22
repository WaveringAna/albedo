import albedo/daemon/store
import albedo/daemon/transcript
import albedo/daemon/usage
import albedo/harness/python/cells as journal
import albedo/openai_api/types
import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

pub fn event(kind: String, fields: List(#(String, json.Json))) -> String {
  json.object([#("type", json.string(kind)), ..fields]) |> json.to_string
}

pub fn text(kind: String, value: String) -> String {
  event(kind, [#("text", json.string(value))])
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
  let #(mime_type, _, width, height, bytes) = types.image_parts(image)
  user_event(text, source, client_id, timestamp, [
    #(
      "image",
      json.object([
        #("mimeType", json.string(mime_type)),
        #("width", json.int(width)),
        #("height", json.int(height)),
        #("bytes", json.int(bytes)),
      ]),
    ),
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
  let tool_calls =
    list.flat_map(entries, fn(entry) { calls(entry.input) })
    |> list.map(fn(call) { #(call.id, call) })
    |> dict.from_list
  let rendered =
    list.flat_map(entries, fn(entry) {
      case entry.input {
        types.User(value) -> [user(value, "user", None, entry.timestamp)]
        types.UserImage(value, image) -> [
          user_image(value, "user", None, entry.timestamp, image),
        ]
        types.Assistant(_) -> assistant_message(entry.input, entry.timestamp)
        types.ToolOutput(id, output) -> {
          let call = dict.get(tool_calls, id)
          case call {
            Ok(call) -> [tool(store, call, output)]
            Error(_) -> []
          }
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
    })
  case latest_usage {
    Some(metadata) -> list.append(rendered, [usage.event(metadata)])
    None -> rendered
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
    Some(value), _ -> value
    None, Some(value) -> value
    None, None -> ""
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
      list.fold(parts, "", fn(text, part) { text <> part })
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
