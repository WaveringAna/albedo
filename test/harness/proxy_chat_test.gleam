// Proxy history and encoded provider-state IDs have malformed and truncated wire inputs the E2E flow cannot reliably generate.
import albedo/harness/extensions/proxy/chat
import albedo/openai_api/types
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string

fn parse(body: String) -> Result(chat.Completion, String) {
  chat.parse(<<body:utf8>>)
}

fn inputs(completion: chat.Completion) -> List(types.Input) {
  list.map(completion.history, fn(entry) { entry.input })
}

pub fn tool_history_becomes_replay_and_tool_output_test() -> List(types.Tool) {
  let assert Ok(completion) =
    parse(
      "{\"model\":\"p/m\",\"messages\":[{\"role\":\"user\",\"content\":\"go\"},{\"role\":\"assistant\",\"content\":null,\"tool_calls\":[{\"id\":\"c1\",\"type\":\"function\",\"function\":{\"name\":\"bash\",\"arguments\":\"{}\"}}]},{\"role\":\"tool\",\"tool_call_id\":\"c1\",\"content\":\"ok\"}],\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"bash\"}}]}",
    )
  let assert [
    types.User("go"),
    types.Replay(item),
    types.ToolOutput("c1", "ok", []),
  ] = inputs(completion)
  assert types.inspect_item(
      item,
      decode.at(["tool_calls"], decode.list(decode.at(["id"], decode.string))),
    )
    == Ok(["c1"])
  let assert [types.Tool("bash", "", _, False)] = completion.request.tools
}

pub fn remote_images_are_refused_test() -> Nil {
  let assert Error(message) =
    parse(
      "{\"model\":\"p/m\",\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"image_url\",\"image_url\":{\"url\":\"https://x/y.png\"}}]}]}",
    )
  assert string.contains(message, "data urls")
}

pub fn provider_state_rides_back_in_the_first_call_id_test() -> Nil {
  let carried = chat.carry(responses_turn(), "cx", types.Responses)
  let assert [first, second] = carried.tool_calls
  assert string.starts_with(first.id, "call_1__albedo__")
  assert second.id == "call_2"
  // Strict clients accept only [A-Za-z0-9_-] in ids.
  assert string.to_graphemes(first.id)
    |> list.all(fn(c) {
      string.contains(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-",
        c,
      )
    })
  let assert Ok(completion) = parse(echoed(carried))
  let assert [_, reasoning, call, first_result, second_result] =
    completion.history
  // The native items return tagged with the profile that produced them.
  assert reasoning.provider == Some("cx")
  let assert types.Replay(item) = reasoning.input
  assert types.replay_protocol(item) == types.Responses
  assert types.inspect_item(
      item,
      decode.at(["encrypted_content"], decode.string),
    )
    == Ok("opaque-state")
  assert call.provider == Some("cx")
  // Results point at the provider's own call ids again.
  assert first_result.input == types.ToolOutput("call_1", "ok", [])
  assert second_result.input == types.ToolOutput("call_2", "ok", [])
}

pub fn damaged_state_falls_back_to_portable_history_test() -> Nil {
  let assert Ok(completion) =
    parse(
      "{\"model\":\"cx/m\",\"messages\":[{\"role\":\"assistant\",\"content\":null,\"tool_calls\":[{\"id\":\"call_1__albedo__not-state\",\"type\":\"function\",\"function\":{\"name\":\"bash\",\"arguments\":\"{}\"}}]},{\"role\":\"tool\",\"tool_call_id\":\"call_1__albedo__not-state\",\"content\":\"ok\"}]}",
    )
  let assert [call, result] = completion.history
  assert call.provider == None
  let assert types.Replay(item) = call.input
  assert types.inspect_item(
      item,
      decode.at(["tool_calls"], decode.list(decode.at(["id"], decode.string))),
    )
    == Ok(["call_1"])
  assert result.input == types.ToolOutput("call_1", "ok", [])
}

/// Clients that normalize ids (LiteLLM #37849) must not corrupt a replay.
/// Short cuts can remove only the zlib checksum and leave complete JSON, so
/// every one replays portably instead of trusting unverified state.
pub fn a_shortened_carried_id_replays_portably_test() -> Nil {
  let carried = chat.carry(responses_turn(), "cx", types.Responses)
  let assert [first, second] = carried.tool_calls
  list.each([1, 2, 3, 4, 5, 6], fn(n) {
    let cut = string.drop_end(first.id, n)
    let shortened =
      types.Turn(..carried, tool_calls: [
        types.ToolCall(..first, id: cut),
        second,
      ])
    let assert Ok(completion) = parse(echoed(shortened))
    let assert [_, call, first_result, _] = completion.history
    assert call.provider == None
    assert first_result.input == types.ToolOutput("call_1", "ok", [])
  })
}

fn responses_turn() -> types.Turn {
  let assert Ok(reasoning) =
    json.parse(
      "{\"type\":\"reasoning\",\"id\":\"rs_1\",\"summary\":[],\"encrypted_content\":\"opaque-state\"}",
      types.replay_decoder(types.Responses),
    )
  let assert Ok(call) =
    json.parse(
      "{\"type\":\"function_call\",\"call_id\":\"call_1\",\"name\":\"bash\",\"arguments\":\"{}\",\"status\":\"completed\"}",
      types.replay_decoder(types.Responses),
    )
  types.Turn(
    Some("r"),
    [reasoning, call],
    [
      types.ToolCall("call_1", "bash", "{}"),
      types.ToolCall("call_2", "bash", "{}"),
    ],
    None,
    types.ToolCalls,
    None,
    [#("call_1", 0), #("call_2", 1)],
  )
}

/// What a client sends back after this turn: plain chat with our ids.
fn echoed(turn: types.Turn) -> String {
  let calls =
    turn.tool_calls
    |> list.map(fn(call) {
      "{\"id\":\""
      <> call.id
      <> "\",\"type\":\"function\",\"function\":{\"name\":\"bash\",\"arguments\":\"{}\"}}"
    })
    |> string.join(",")
  let results =
    turn.tool_calls
    |> list.map(fn(call) {
      ",{\"role\":\"tool\",\"tool_call_id\":\""
      <> call.id
      <> "\",\"content\":\"ok\"}"
    })
    |> string.concat
  "{\"model\":\"cx/m\",\"messages\":[{\"role\":\"user\",\"content\":\"go\"},{\"role\":\"assistant\",\"content\":null,\"tool_calls\":["
  <> calls
  <> "]}"
  <> results
  <> "]}"
}
