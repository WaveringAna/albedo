//// Converts durable provider output into the portable model-input subset.
//// Raw replay remains untouched only for the provider/protocol that produced it.

import albedo/daemon/transcript
import albedo/openai_api/replay
import albedo/openai_api/types
import gleam/dict.{type Dict}
import gleam/dynamic
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string

/// One provider-facing input and the durable transcript rows that produced it.
/// A transfer may combine several source rows or omit an opaque reasoning row.
pub type SourcedInput {
  SourcedInput(input: types.Input, sources: List(transcript.SourceRef))
}

pub fn for_model(
  newest_first: List(transcript.Entry),
  provider: String,
  protocol: types.Protocol,
) -> Result(List(types.Input), String) {
  newest_first
  |> list.reverse
  |> list.map(fn(entry) { #(entry, []) })
  |> project(provider, protocol, [], empty_chat())
  |> result.map(fn(inputs) { list.map(inputs, fn(input) { input.input }) })
}

pub fn for_model_with_sources(
  newest_first: List(transcript.SourcedEntry),
  provider: String,
  protocol: types.Protocol,
) -> Result(List(SourcedInput), String) {
  newest_first
  |> list.reverse
  |> list.map(fn(item) { #(item.entry, [item.source]) })
  |> project(provider, protocol, [], empty_chat())
}

fn project(
  entries: List(#(transcript.Entry, List(transcript.SourceRef))),
  provider: String,
  protocol: types.Protocol,
  projected: List(SourcedInput),
  pending_chat: ChatSemantic,
) -> Result(List(SourcedInput), String) {
  case entries {
    [] -> flush_chat(projected, pending_chat)
    [#(entry, sources), ..rest] -> {
      // Both continuations capture this row's position in the walk.
      let ahead = fn(inputs: List(types.Input)) {
        use projected <- result.try(flush_chat(projected, pending_chat))
        project(
          rest,
          provider,
          protocol,
          list.append(
            list.map(list.reverse(inputs), fn(input) {
              SourcedInput(input, sources)
            }),
            projected,
          ),
          empty_chat(),
        )
      }
      let carry = fn(chat: ChatSemantic) {
        project(rest, provider, protocol, projected, chat)
      }
      case entry.input {
        types.Replay(item) ->
          case
            types.replay_protocol(item) == protocol
            && entry.provider == Some(provider)
          {
            True -> ahead([entry.input])
            False ->
              case types.replay_protocol(item), protocol {
                types.Responses, types.ChatCompletions ->
                  case response_semantics(item) {
                    Ok(ResponseReasoning) -> carry(pending_chat)
                    Ok(ResponseCall(call)) ->
                      carry(add_call(pending_chat, call, sources))
                    Ok(ResponseText(text)) ->
                      carry(add_text(pending_chat, text, sources))
                    Error(error) -> Error(error)
                  }
                types.Responses, types.Responses -> {
                  use inputs <- result.try(canonical_response(item))
                  ahead(inputs)
                }
                types.ChatCompletions, target -> {
                  use semantics <- result.try(chat_semantics(item))
                  use inputs <- result.try(chat_inputs(semantics, target))
                  ahead(inputs)
                }
              }
          }
        input -> ahead([input])
      }
    }
  }
}

type ResponseSemantic {
  ResponseReasoning
  ResponseText(String)
  ResponseCall(types.ToolCall)
}

fn canonical_response(
  item: types.ReplayItem,
) -> Result(List(types.Input), String) {
  use semantic <- result.try(response_semantics(item))
  case semantic {
    ResponseReasoning -> Ok([])
    ResponseText(text) -> Ok([types.Assistant(text)])
    ResponseCall(call) ->
      response_call(call)
      |> result.map(fn(item) { [types.Replay(item)] })
  }
}

fn response_semantics(
  item: types.ReplayItem,
) -> Result(ResponseSemantic, String) {
  use kind <- result.try(inspect(
    item,
    decode.field("type", decode.string, decode.success),
    "Responses output item type",
  ))
  case kind {
    "reasoning" -> Ok(ResponseReasoning)
    "message" -> response_text(item) |> result.map(ResponseText)
    "function_call" -> response_call_semantics(item) |> result.map(ResponseCall)
    other ->
      Error(
        "cannot transfer Responses output item type "
        <> string.inspect(other)
        <> "; its semantics are not portable",
      )
  }
}

fn response_text(item: types.ReplayItem) -> Result(String, String) {
  let decoder = {
    use role <- decode.field("role", decode.string)
    use content <- decode.field("content", decode.list(response_part_decoder()))
    case role {
      "assistant" -> decode.success(string.concat(content))
      _ -> decode.failure("", "assistant response message")
    }
  }
  inspect(item, decoder, "Responses assistant message")
}

fn response_part_decoder() -> decode.Decoder(String) {
  use kind <- decode.field("type", decode.string)
  case kind {
    "output_text" -> {
      use text <- decode.field("text", decode.string)
      decode.success(text)
    }
    "refusal" -> {
      use text <- decode.field("refusal", decode.string)
      decode.success(text)
    }
    other -> decode.failure("", "portable response content part, got " <> other)
  }
}

fn response_call_semantics(
  item: types.ReplayItem,
) -> Result(types.ToolCall, String) {
  inspect(item, replay.function_call_decoder(), "Responses function call")
}

type ChatSemantic {
  ChatSemantic(
    text: List(String),
    calls: List(types.ToolCall),
    sources: List(transcript.SourceRef),
  )
}

fn chat_semantics(item: types.ReplayItem) -> Result(ChatSemantic, String) {
  let decoder = {
    use fields <- decode.then(decode.dict(decode.string, decode.dynamic))
    use _ <- decode.then(reject_chat_semantics(fields))
    use content <- decode.optional_field(
      "content",
      None,
      decode.optional(decode.string),
    )
    use refusal <- decode.optional_field(
      "refusal",
      None,
      decode.optional(decode.string),
    )
    use calls <- decode.optional_field(
      "tool_calls",
      [],
      decode.list(chat_call_decoder()),
    )
    let text =
      list.filter_map([content, refusal], fn(value) {
        case value {
          Some(text) -> Ok(text)
          None -> Error(Nil)
        }
      })
    decode.success(ChatSemantic(text, calls, []))
  }
  inspect(item, decoder, "Chat Completions assistant message")
}

fn reject_chat_semantics(
  fields: Dict(String, dynamic.Dynamic),
) -> decode.Decoder(Nil) {
  case
    fields
    |> dict.keys
    |> list.find(fn(name) { !list.contains(replay.portable_fields, name) })
  {
    Ok(name) ->
      decode.failure(Nil, "known portable assistant field, got " <> name)
    Error(_) -> decode.success(Nil)
  }
}

fn chat_call_decoder() -> decode.Decoder(types.ToolCall) {
  use id <- decode.field("id", decode.string)
  use kind <- decode.optional_field("type", "function", decode.string)
  use call <- decode.field("function", {
    use name <- decode.field("name", decode.string)
    use arguments <- decode.field("arguments", decode.string)
    decode.success(#(name, arguments))
  })
  case kind == "function" && id != "" && call.0 != "" {
    True -> decode.success(types.ToolCall(id, call.0, call.1))
    False ->
      decode.failure(
        types.ToolCall(id, call.0, call.1),
        "function tool call with identity",
      )
  }
}

fn empty_chat() -> ChatSemantic {
  ChatSemantic([], [], [])
}

/// A call joins the message being assembled, carrying its row's sources.
fn add_call(
  chat: ChatSemantic,
  call: types.ToolCall,
  sources: List(transcript.SourceRef),
) -> ChatSemantic {
  let ChatSemantic(text, calls, pending) = chat
  ChatSemantic(text, [call, ..calls], list.append(pending, sources))
}

/// Answer text joins the message being assembled, carrying its row's sources.
fn add_text(
  chat: ChatSemantic,
  text: String,
  sources: List(transcript.SourceRef),
) -> ChatSemantic {
  let ChatSemantic(texts, calls, pending) = chat
  ChatSemantic([text, ..texts], calls, list.append(pending, sources))
}

fn chat_inputs(
  semantic: ChatSemantic,
  protocol: types.Protocol,
) -> Result(List(types.Input), String) {
  let ChatSemantic(text, calls, _) = semantic
  case protocol {
    types.ChatCompletions ->
      case calls {
        [] -> Ok(list.map(text, types.Assistant))
        _ ->
          chat_message(text, calls)
          |> result.map(fn(item) { [types.Replay(item)] })
      }
    types.Responses -> {
      use tools <- result.try(
        list.try_map(calls, fn(call) {
          response_call(call) |> result.map(types.Replay)
        }),
      )
      Ok(list.append(list.map(text, types.Assistant), tools))
    }
  }
}

fn flush_chat(
  projected: List(SourcedInput),
  pending: ChatSemantic,
) -> Result(List(SourcedInput), String) {
  let ChatSemantic(text, calls, sources) = pending
  case text, calls {
    [], [] -> Ok(projected)
    _, _ -> {
      use item <- result.try(chat_message(
        list.reverse(text),
        list.reverse(calls),
      ))
      Ok([SourcedInput(types.Replay(item), sources), ..projected])
    }
  }
}

fn chat_message(
  text: List(String),
  calls: List(types.ToolCall),
) -> Result(types.ReplayItem, String) {
  replay_item(
    types.ChatCompletions,
    replay.message(
      case text {
        [] -> json.null()
        text -> json.string(string.concat(text))
      },
      "",
      None,
      calls,
    ),
  )
}

fn response_call(call: types.ToolCall) -> Result(types.ReplayItem, String) {
  replay_item(
    types.Responses,
    json.object([
      #("type", json.string("function_call")),
      #("call_id", json.string(call.id)),
      #("name", json.string(call.name)),
      #("arguments", json.string(call.arguments)),
      #("status", json.string("completed")),
    ]),
  )
}

fn replay_item(
  protocol: types.Protocol,
  value: json.Json,
) -> Result(types.ReplayItem, String) {
  json.parse(json.to_string(value), types.replay_decoder(protocol))
  |> result.map_error(fn(error) {
    "could not construct portable replay item: " <> string.inspect(error)
  })
}

fn inspect(
  item: types.ReplayItem,
  decoder: decode.Decoder(a),
  context: String,
) -> Result(a, String) {
  types.inspect_item(item, decoder)
  |> result.map_error(fn(error) { context <> ": " <> string.inspect(error) })
}
