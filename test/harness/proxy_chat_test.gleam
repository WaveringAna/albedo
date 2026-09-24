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

pub fn model_names_a_profile_and_optionally_its_model_test() {
  let assert Ok(named) =
    parse("{\"model\":\"agy/vendor/model-1\",\"messages\":[]}")
  assert #(named.profile, named.model) == #("agy", "vendor/model-1")
  let assert Ok(bare) = parse("{\"model\":\"agy\",\"messages\":[]}")
  assert #(bare.profile, bare.model) == #("agy", "")
}

pub fn leading_system_messages_are_instructions_and_later_ones_notes_test() {
  let assert Ok(completion) =
    parse(
      "{\"model\":\"p/m\",\"max_tokens\":64,\"messages\":[{\"role\":\"system\",\"content\":\"a\"},{\"role\":\"developer\",\"content\":[{\"type\":\"text\",\"text\":\"b\"}]},{\"role\":\"user\",\"content\":\"hi\"},{\"role\":\"system\",\"content\":\"late\"}]}",
    )
  assert completion.request.instructions == Some("a\n\nb")
  assert completion.request.max_output_tokens == Some(64)
  assert inputs(completion)
    == [types.User("hi"), types.User("<system>\nlate\n</system>")]
}

pub fn tool_history_becomes_replay_and_tool_output_test() {
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

pub fn the_conversation_seed_is_stable_across_turns_test() {
  let assert Ok(first) =
    parse(
      "{\"model\":\"p/m\",\"messages\":[{\"role\":\"user\",\"content\":\"q\"}]}",
    )
  let assert Ok(later) =
    parse(
      "{\"model\":\"p/m\",\"messages\":[{\"role\":\"user\",\"content\":\"q\"},{\"role\":\"assistant\",\"content\":\"a\"},{\"role\":\"user\",\"content\":\"q2\"}]}",
    )
  assert first.conversation == later.conversation
}

pub fn remote_images_are_refused_test() {
  let assert Error(message) =
    parse(
      "{\"model\":\"p/m\",\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"image_url\",\"image_url\":{\"url\":\"https://x/y.png\"}}]}]}",
    )
  assert string.contains(message, "data urls")
}

pub fn a_turn_becomes_a_completion_and_closing_chunks_test() {
  let assert Ok(item) =
    json.parse(
      "{\"role\":\"assistant\",\"content\":\"hi\",\"reasoning_content\":\"think\"}",
      types.replay_decoder(types.ChatCompletions),
    )
  let turn =
    types.Turn(
      Some("r"),
      [item],
      [types.ToolCall("c1", "bash", "{}")],
      Some(types.Usage(3, 2, None)),
      types.ToolCalls,
    )
  let reply = chat.Reply("chatcmpl-1", 7, "p/m")
  let completion = json.to_string(chat.completion(reply, turn))
  let assert Ok(message) =
    json.parse(
      completion,
      decode.at(
        ["choices"],
        decode.list(decode.at(["message"], decode.dynamic)),
      ),
    )
  let assert [message] = message
  assert decode.run(message, decode.at(["content"], decode.string)) == Ok("hi")
  assert decode.run(message, decode.at(["reasoning_content"], decode.string))
    == Ok("think")
  assert string.contains(completion, "\"finish_reason\":\"tool_calls\"")
  assert string.contains(completion, "\"total_tokens\":5")
  let closing = list.map(chat.closing(reply, turn, True), json.to_string)
  let assert [calls, finish, usage] = closing
  assert string.contains(calls, "\"index\":0,\"id\":\"c1\"")
  assert string.contains(finish, "\"finish_reason\":\"tool_calls\"")
  assert string.contains(usage, "\"choices\":[]")
  assert chat.delta(reply, types.ArgumentsDelta(0, "{")) == None
}

pub fn client_generation_options_are_kept_test() {
  let assert Ok(completion) =
    parse(
      "{\"model\":\"p/m\",\"messages\":[],\"temperature\":1,\"top_p\":0.5,\"stop\":\"END\",\"tool_choice\":{\"type\":\"function\",\"function\":{\"name\":\"bash\"}},\"parallel_tool_calls\":false,\"reasoning\":{\"effort\":\"high\"},\"response_format\":{\"type\":\"json_schema\",\"json_schema\":{\"name\":\"a\",\"schema\":{\"type\":\"object\"}}}}",
    )
  let options = completion.request.options
  assert options.temperature == Some(1.0)
  assert options.top_p == Some(0.5)
  assert options.stop == ["END"]
  assert options.tool_choice == Some(types.NamedTool("bash"))
  assert options.parallel_tool_calls == Some(False)
  assert options.effort == Some("high")
  let assert Some(types.JsonSchema("a", _, False)) = options.format
  let assert Ok(plain) =
    parse(
      "{\"model\":\"p/m\",\"messages\":[],\"tool_choice\":\"required\",\"reasoning_effort\":\"low\",\"response_format\":{\"type\":\"text\"}}",
    )
  assert plain.request.options.tool_choice == Some(types.AnyTool)
  assert plain.request.options.effort == Some("low")
  assert plain.request.options.format == None
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

pub fn provider_state_rides_back_in_the_first_call_id_test() {
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

pub fn damaged_state_falls_back_to_portable_history_test() {
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
pub fn a_shortened_carried_id_replays_portably_test() {
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
