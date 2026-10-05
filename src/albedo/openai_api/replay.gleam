//// The fields a portable chat-shaped assistant message may carry. A new
//// an assistant turn, with room for provider detail blocks, that a provider
//// reads back verbatim on replay.

/// compatible-provider reasoning field must be added here and to reasoning's
/// decoders, or replayed messages that carry it are rejected as non-portable.
pub const portable_fields = [
  "role", "content", "refusal", "tool_calls", "reasoning", "reasoning_content",
  "reasoning_details",
]

import albedo/openai_api/types
import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/option.{type Option, None, Some}

/// A chat-completions tool call: id, type, and its function envelope.
pub fn tool_call(call: types.ToolCall) -> Json {
  json.object(tool_call_fields(call))
}

/// The fields of `tool_call`, for callers that add their own, such as an index.
pub fn tool_call_fields(call: types.ToolCall) -> List(#(String, Json)) {
  let types.ToolCall(id, name, arguments) = call
  [
    #("id", json.string(id)),
    #("type", json.string("function")),
    #(
      "function",
      json.object([
        #("name", json.string(name)),
        #("arguments", json.string(arguments)),
      ]),
    ),
  ]
}

/// A chat-shaped assistant replay message: content, then reasoning text and
/// provider details, then whole tool calls. Every optional field is omitted
/// when empty, and later fields encode first.
pub fn message(
  content: Json,
  thinking: String,
  details: Option(Json),
  calls: List(types.ToolCall),
) -> Json {
  let fields = [
    #("role", json.string("assistant")),
    #("content", content),
  ]
  let fields = case thinking {
    "" -> fields
    thinking -> [#("reasoning_content", json.string(thinking)), ..fields]
  }
  let fields = case details {
    Some(details) -> [#("reasoning_details", details), ..fields]
    None -> fields
  }
  let fields = case calls {
    [] -> fields
    calls -> [#("tool_calls", json.array(calls, tool_call)), ..fields]
  }
  json.object(fields)
}

/// A tool call as chat-completions messages carry it.
pub fn tool_call_decoder() -> decode.Decoder(types.ToolCall) {
  use id <- decode.field("id", decode.string)
  use name <- decode.subfield(["function", "name"], decode.string)
  use arguments <- decode.subfield(["function", "arguments"], decode.string)
  decode.success(types.ToolCall(id, name, arguments))
}

/// A Responses function_call output item, complete with its identity.
pub fn function_call_decoder() -> decode.Decoder(types.ToolCall) {
  use id <- decode.field("call_id", decode.string)
  use name <- decode.field("name", decode.string)
  use arguments <- decode.field("arguments", decode.string)
  use status <- decode.optional_field("status", "completed", decode.string)
  case id != "" && name != "" && status == "completed" {
    True -> decode.success(types.ToolCall(id, name, arguments))
    False ->
      decode.failure(
        types.ToolCall(id, name, arguments),
        "completed function call with identity",
      )
  }
}

/// A replayed assistant message's portable parts: its text, its whole tool
/// calls, and every provider detail `detail` matched, in arrival order.
pub type Message(a) {
  Message(text: String, calls: List(types.ToolCall), details: List(a))
}

pub fn message_decoder(
  detail: decode.Decoder(Option(a)),
) -> decode.Decoder(Message(a)) {
  use text <- decode.optional_field(
    "content",
    None,
    decode.optional(decode.string),
  )
  use calls <- decode.optional_field(
    "tool_calls",
    [],
    decode.optional(decode.list(tool_call_decoder()))
      |> decode.map(option.unwrap(_, [])),
  )
  use details <- decode.optional_field(
    "reasoning_details",
    [],
    decode.optional(decode.list(detail)) |> decode.map(option.unwrap(_, [])),
  )
  decode.success(Message(option.unwrap(text, ""), calls, option.values(details)))
}
