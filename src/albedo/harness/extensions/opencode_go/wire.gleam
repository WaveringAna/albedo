//// OpenCode Go wire dispatch across Chat Completions (`/chat/completions`),
//// OpenAI Responses (`/responses`), Anthropic Messages (`/messages`), and
//// Google Gemini (`:streamGenerateContent?alt=sse`). Every route converts from
//// and reduces back to portable ChatCompletions replay items, reusing the
//// shared OpenAI, Bedrock/Claude, and Vertex wire/stream encoders and reducers.

import albedo/harness/extensions/bedrock/wire as bedrock_wire
import albedo/harness/extensions/vertex/wire as vertex_wire
import albedo/openai_api
import albedo/openai_api/decoding
import albedo/openai_api/replay
import albedo/openai_api/request as openai_request
import albedo/openai_api/stream as reducer
import albedo/openai_api/types.{
  type Client, type Error, type Input, type Request, Assistant, ChatCompletions,
  InvalidRequest, Replay, Responses,
}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub type Route {
  ChatRoute
  ResponsesRoute
  MessagesRoute
  GeminiRoute
}

/// Which upstream route OpenCode Go uses for `model`.
pub fn route(model: String) -> Route {
  let id = string.lowercase(string.trim(model))
  case
    string.starts_with(id, "gemini-"),
    string.starts_with(id, "claude-") || id == "minimax-m2.7",
    string.starts_with(id, "gpt-")
    || string.starts_with(id, "grok-")
    || string.starts_with(id, "muse-spark-")
  {
    True, _, _ -> GeminiRoute
    _, True, _ -> MessagesRoute
    _, _, True -> ResponsesRoute
    False, False, False -> ChatRoute
  }
}

/// Canonical inference base URL; `/zen/go/v1` is rewritten to `/inference/go/v1`
/// so Gemini's `/models/{id}:streamGenerateContent` route resolves on the
/// direct inference gateway.
pub fn base_url(url: String) -> String {
  let trimmed = string.remove_suffix(string.trim(url), "/")
  case trimmed {
    "https://opencode.ai/zen/go/v1" -> "https://opencode.ai/inference/go/v1"
    _ -> trimmed
  }
}

/// Encodes a ChatCompletions-projected request into an OpenAI `/responses`
/// exchange for OpenCode Go models backed by Responses (GPT, Grok, Muse Spark).
pub fn encode_responses(
  client: Client,
  request: Request,
) -> Result(openai_api.Exchange, Error) {
  use inputs <- result.try(
    list.try_fold(request.input, [], fn(acc, input) {
      use items <- result.map(responses_input(input))
      list.append(list.reverse(items), acc)
    }),
  )
  let rewritten = types.Request(..request, input: list.reverse(inputs))
  use body <- result.map(openai_request.encode_with_policy(
    Responses,
    client.policy,
    rewritten,
  ))
  openai_api.Exchange(
    base_url(client.base_url) <> "/responses",
    openai_api.headers(client, request.model),
    body,
    client.timeout_ms,
    None,
    client.max_event_bytes,
    True,
  )
}

/// Encodes a ChatCompletions-projected request into an Anthropic `/messages`
/// exchange via `bedrock_wire.encode_body`.
pub fn encode_messages(
  client: Client,
  request: Request,
) -> Result(openai_api.Exchange, Error) {
  use body <- result.map(bedrock_wire.encode_body(request))
  let headers = [
    #("anthropic-version", "2023-06-01"),
    #("x-api-key", client.api_key),
    ..openai_api.headers(client, request.model)
  ]
  openai_api.Exchange(
    base_url(client.base_url) <> "/messages",
    headers,
    body,
    120_000,
    None,
    client.max_event_bytes,
    True,
  )
}

/// Encodes a ChatCompletions-projected request into a Gemini
/// `:streamGenerateContent?alt=sse` exchange via `vertex_wire.encode_body`.
pub fn encode_gemini(
  client: Client,
  request: Request,
) -> Result(openai_api.Exchange, Error) {
  use body <- result.map(vertex_wire.encode_body(request))
  let url =
    base_url(client.base_url)
    <> "/models/"
    <> request.model
    <> ":streamGenerateContent?alt=sse"
  openai_api.Exchange(
    url,
    openai_api.headers(client, request.model),
    body,
    120_000,
    None,
    client.max_event_bytes,
    True,
  )
}

fn responses_input(input: Input) -> Result(List(Input), Error) {
  case input {
    Replay(item) ->
      case types.replay_protocol(item) {
        Responses -> Ok([Replay(item)])
        ChatCompletions -> {
          use message <- result.try(
            types.inspect_item(item, replay.message_decoder(detail_decoder()))
            |> result.replace_error(InvalidRequest(
              "replayed assistant message is not portable",
            )),
          )
          let text_inputs = case message.text {
            "" -> []
            text -> [Assistant(text)]
          }
          use call_inputs <- result.map(list.try_map(
            message.calls,
            responses_call_item,
          ))
          list.append(text_inputs, call_inputs)
        }
      }
    other -> Ok([other])
  }
}

fn detail_decoder() -> decode.Decoder(Option(Nil)) {
  decode.success(None)
}

fn responses_call_item(call: types.ToolCall) -> Result(Input, Error) {
  let raw =
    json.object([
      #("type", json.string("function_call")),
      #("call_id", json.string(call.id)),
      #("name", json.string(call.name)),
      #("arguments", json.string(call.arguments)),
    ])
    |> json.to_string
  json.parse(raw, types.replay_decoder(Responses))
  |> result.map(Replay)
  |> result.replace_error(InvalidRequest(
    "could not encode tool call for Responses route",
  ))
}

type ResponsesTurnState {
  ResponsesTurnState(inner: reducer.Reducer, thinking: List(String))
}

/// Reduces an OpenAI `/responses` SSE stream into a Turn whose replay item is a
/// single portable `ChatCompletions` assistant message.
pub fn responses_reducer() -> reducer.Reducer {
  reducer.wrap(
    ResponsesTurnState(reducer.reducer(Responses), []),
    responses_step,
    fn(_) { Error(types.UnexpectedEnd) },
  )
}

fn responses_step(
  state: ResponsesTurnState,
  data: String,
) -> Result(
  #(ResponsesTurnState, List(types.Event), Option(types.Turn)),
  types.Error,
) {
  use #(next_inner, events, turn) <- result.try(state.inner.feed(data))
  let thinking =
    list.fold(events, state.thinking, fn(acc, event) {
      case event {
        types.ThinkingDelta(delta) -> [delta, ..acc]
        _ -> acc
      }
    })
  let next_state = ResponsesTurnState(next_inner, thinking)
  case turn {
    None -> Ok(#(next_state, events, None))
    Some(turn) -> {
      use converted <- result.map(responses_turn_to_chat(turn, thinking))
      #(next_state, events, Some(converted))
    }
  }
}

fn responses_turn_to_chat(
  turn: types.Turn,
  thinking_chunks: List(String),
) -> Result(types.Turn, types.Error) {
  let text =
    turn.output
    |> list.map(responses_item_text)
    |> string.concat
  let thinking = case thinking_chunks {
    [] ->
      turn.output
      |> list.map(responses_item_thinking)
      |> list.filter(fn(s) { s != "" })
      |> string.join("\n\n")
    chunks -> chunks |> list.reverse |> string.concat
  }
  let calls = case turn.finish {
    types.ToolCalls -> turn.tool_calls
    _ -> []
  }
  let content = case text {
    "" -> json.null()
    _ -> json.string(text)
  }
  use item <- result.map(
    json.parse(
      json.to_string(replay.message(content, thinking, None, calls)),
      types.replay_decoder(ChatCompletions),
    )
    |> result.map_error(fn(error) {
      types.InvalidEvent(
        "could not build OpenCode Go replay message: "
        <> decoding.json_error(error),
      )
    }),
  )
  let call_indices =
    list.index_map(calls, fn(call, index) { #(call.id, index) })
  types.Turn(..turn, output: [item], tool_calls: calls, call_indices:)
}

fn responses_item_text(item: types.ReplayItem) -> String {
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

fn responses_item_thinking(item: types.ReplayItem) -> String {
  let kind =
    types.inspect_item(
      item,
      decode.field("type", decode.string, decode.success),
    )
    |> result.unwrap("")
  case kind {
    "reasoning" -> {
      let part = decode.field("text", decode.string, decode.success)
      let fragments = fn(name: String) {
        types.inspect_item(
          item,
          decode.field(name, decode.list(part), decode.success),
        )
        |> result.unwrap([])
      }
      let parts = case fragments("summary") {
        [] -> fragments("content")
        summary -> summary
      }
      string.join(parts, "\n\n")
    }
    _ -> ""
  }
}
