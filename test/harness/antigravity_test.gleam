// Signed Gemini and Claude replay must survive Antigravity stream reduction and cross-model projection.
import albedo/harness/extensions/antigravity/catalog
import albedo/harness/extensions/antigravity/stream
import albedo/harness/extensions/antigravity/wire
import albedo/openai_api
import albedo/openai_api/types
import gleam/dynamic
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/string_tree

const gemini = "gemini-3.1-pro-low"

const claude = "claude-sonnet-4-6"

/// Test fixture models for wire encoding and streaming tests.
fn model(id: String) -> catalog.Model {
  case id {
    "gemini-3.1-pro-low" ->
      catalog.Model(
        id,
        "Gemini 3.1 Pro (Low)",
        1_048_576,
        65_535,
        True,
        catalog.Budget(1001, 8192, 10_001),
        Some("MODEL_PLACEHOLDER_M36"),
        True,
      )
    "claude-sonnet-4-6" ->
      catalog.Model(
        id,
        "Claude Sonnet 4.6",
        250_000,
        64_000,
        True,
        catalog.Budget(4096, 8192, 16_384),
        None,
        True,
      )
    _ -> catalog.model("/nonexistent/albedo-home", id, None)
  }
}

fn context(id: String) -> wire.Context {
  wire.Context(
    "token-1",
    "project-1",
    "session-1",
    model(id),
    "antigravity/hub/test",
  )
}

fn body(model: String, request: types.Request) -> dynamic.Dynamic {
  let assert Ok(openai_api.Exchange(body: body, ..)) =
    wire.encode(context(model), request)
  let assert Ok(value) = json.parse(string_tree.to_string(body), decode.dynamic)
  value
}

fn at(value: dynamic.Dynamic, path: List(String), decoder: decode.Decoder(a)) {
  let assert Ok(found) = decode.run(value, decode.at(path, decoder))
  found
}

fn chunk(json: String) -> String {
  "{\"response\":" <> json <> ",\"traceId\":\"t\"}"
}

/// Feeds each payload, then ends the body.
fn reduce(id: String, payloads: List(String)) {
  let #(reducer, events) =
    list.fold(payloads, #(stream.reducer(model(id)), []), fn(acc, data) {
      let #(reducer, events) = acc
      let assert Ok(#(next, new, None)) = reducer.feed(data)
      #(next, list.append(events, new))
    })
  #(reducer.finish(), events)
}

const signed_turn = [
  "{\"responseId\":\"r1\",\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"weigh\",\"thought\":true},{\"text\":\"ing\",\"thought\":true,\"thoughtSignature\":\"c2ln\"}]}}]}",
  "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"looking\"},{\"functionCall\":{\"name\":\"bash\",\"args\":{\"command\":\"ls\"}},\"thoughtSignature\":\"Y2FsbA==\"}]},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":10,\"candidatesTokenCount\":3,\"thoughtsTokenCount\":2,\"cachedContentTokenCount\":4}}",
]

fn signed_turn_payloads() {
  list.map(signed_turn, chunk)
}

pub fn stream_reduces_thoughts_text_and_calls_test() {
  let #(outcome, events) = reduce(gemini, signed_turn_payloads())
  let assert Ok(turn) = outcome
  let assert [
    types.Started("r1"),
    types.ThinkingDelta("weigh"),
    types.ThinkingDelta("ing"),
    types.TextDelta(0, 0, "looking"),
    types.ArgumentsDelta(0, "bash", arguments),
  ] = events
  assert arguments == "{\"command\":\"ls\"}"
  assert turn.finish == types.ToolCalls
  // Output folds the 2 thought tokens in; reasoning carries the thought count.
  assert turn.usage
    == Some(types.Usage(10, 5, Some(4), None, None, None, Some(2)))
  let assert [types.ToolCall(id, "bash", "{\"command\":\"ls\"}")] =
    turn.tool_calls
  assert string.starts_with(id, "call_")
  let assert [item] = turn.output
  assert types.inspect_item(item, decode.at(["content"], decode.string))
    == Ok("looking")
  assert types.inspect_item(
      item,
      decode.at(["reasoning_content"], decode.string),
    )
    == Ok("weighing")
}

pub fn same_model_replay_keeps_signed_parts_test() {
  let #(outcome, _) = reduce(gemini, signed_turn_payloads())
  let assert Ok(turn) = outcome
  let assert [item] = turn.output
  let assert [call] = turn.tool_calls
  let request =
    openai_api.request(gemini, [
      types.User("hi"),
      types.Replay(item),
      types.ToolOutput(call.id, "a b", []),
    ])
  let contents =
    at(
      body(gemini, request),
      ["request", "contents"],
      decode.list(decode.dynamic),
    )
  let assert [_, model, result] = contents
  let parts = at(model, ["parts"], decode.list(decode.dynamic))
  let assert [thought, text, function] = parts
  assert at(thought, ["thought"], decode.bool)
  assert at(thought, ["text"], decode.string) == "weighing"
  assert at(thought, ["thoughtSignature"], decode.string) == "c2ln"
  assert at(text, ["text"], decode.string) == "looking"
  assert at(function, ["thoughtSignature"], decode.string) == "Y2FsbA=="
  assert at(function, ["functionCall", "args", "command"], decode.string)
    == "ls"
  // Gemini correlates by name; ids are only for Claude routes.
  let assert Error(_) =
    decode.run(function, decode.at(["functionCall", "id"], decode.string))
  assert at(result, ["role"], decode.string) == "user"
  assert at(
      result,
      ["parts"],
      decode.list(decode.at(["functionResponse", "name"], decode.string)),
    )
    == ["bash"]
}

pub fn another_models_output_replays_portably_test() {
  let #(outcome, _) = reduce(gemini, signed_turn_payloads())
  let assert Ok(turn) = outcome
  let assert [item] = turn.output
  let assert [call] = turn.tool_calls
  let request =
    openai_api.request(claude, [
      types.User("hi"),
      types.Replay(item),
      types.ToolOutput(call.id, "", []),
    ])
  let request_body = body(claude, request)
  let assert [_, model, result] =
    at(request_body, ["request", "contents"], decode.list(decode.dynamic))
  let assert [text, function] =
    at(model, ["parts"], decode.list(decode.dynamic))
  assert at(text, ["text"], decode.string) == "looking"
  assert at(function, ["functionCall", "id"], decode.string) == call.id
  let assert Error(_) =
    decode.run(function, decode.at(["thoughtSignature"], decode.string))
  assert at(
      result,
      ["parts"],
      decode.list(decode.at(["functionResponse", "id"], decode.string)),
    )
    == [call.id]
  assert at(
      request_body,
      ["request", "toolConfig", "functionCallingConfig", "mode"],
      decode.string,
    )
    == "VALIDATED"
}

pub fn foreign_calls_carry_the_skip_signature_on_gemini_test() {
  let assert Ok(item) =
    json.parse(
      "{\"role\":\"assistant\",\"content\":null,\"tool_calls\":[{\"id\":\"c1\",\"type\":\"function\",\"function\":{\"name\":\"bash\",\"arguments\":\"{}\"}}]}",
      types.replay_decoder(types.ChatCompletions),
    )
  let request =
    openai_api.request(gemini, [
      types.User("hi"),
      types.Replay(item),
      types.ToolOutput("c1", "ok", []),
    ])
  let assert [_, model, _] =
    at(
      body(gemini, request),
      ["request", "contents"],
      decode.list(decode.dynamic),
    )
  assert at(
      model,
      ["parts"],
      decode.list(decode.at(["thoughtSignature"], decode.string)),
    )
    == ["skip_thought_signature_validator"]
}

pub fn empty_body_is_a_retryable_failure_test() {
  let #(outcome, _) = reduce(gemini, [])
  assert outcome == Error(types.UnexpectedEnd)
}

pub fn stream_errors_surface_the_provider_message_test() {
  let reducer = stream.reducer(model(gemini))
  let assert Error(types.ProviderError("quota")) =
    reducer.feed("{\"error\":{\"code\":429,\"message\":\"quota\"}}")
}
