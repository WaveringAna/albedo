//// Provider replay content inspection shared by durable projections and workers.

import albedo/openai_api/replay
import albedo/openai_api/types
import gleam/dynamic/decode
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

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

/// The fields for `key` when `value` is present: absent optional fields are
/// omitted from objects, not sent null.
pub fn opt(
  key: String,
  value: Option(a),
  encode: fn(a) -> json.Json,
) -> List(#(String, json.Json)) {
  case value {
    Some(val) -> [#(key, encode(val))]
    None -> []
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
      |> option.unwrap("")
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
      |> string.concat
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
        types.ChatCompletions ->
          types.inspect_item(
            item,
            decode.field(
              "tool_calls",
              decode.list(replay.tool_call_decoder()),
              decode.success,
            ),
          )
          |> result.unwrap([])
      }
    _ -> []
  }
}
