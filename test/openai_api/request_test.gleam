import albedo/openai_api as openai
import albedo/openai_api/request
import albedo/openai_api/types
import gleam/dynamic/decode
import gleam/json
import gleam/option.{Some}
import gleam/string_tree

fn tool() {
  types.Tool(
    "read_file",
    "read a file",
    json.object([#("type", json.string("object"))]),
    True,
  )
}

fn body(protocol, request) {
  let assert Ok(body) = request.encode(protocol, request)
  string_tree.to_string(body)
}

pub fn responses_request_shape_test() {
  let request =
    openai.request("model", [
      types.User("hello"),
      types.ToolOutput("call1", "file contents"),
    ])
  let request =
    types.Request(
      ..request,
      instructions: Some("be concise"),
      tools: [tool()],
      max_output_tokens: Some(42),
    )
  let encoded = body(types.Responses, request)
  assert json.parse(encoded, decode.at(["instructions"], decode.string))
    == Ok("be concise")
  assert json.parse(encoded, decode.at(["store"], decode.bool)) == Ok(False)
  assert json.parse(encoded, decode.at(["stream"], decode.bool)) == Ok(True)
  assert json.parse(encoded, decode.at(["max_output_tokens"], decode.int))
    == Ok(42)
  assert json.parse(encoded, decode.at(["include"], decode.list(decode.string)))
    == Ok(["reasoning.encrypted_content"])
  assert json.parse(
      encoded,
      decode.at(["tools"], decode.list(decode.at(["name"], decode.string))),
    )
    == Ok(["read_file"])
  let decoder = decode.at(["input"], decode.list(decode.dynamic))
  let assert Ok([_, result]) = json.parse(encoded, decoder)
  assert decode.run(result, decode.at(["call_id"], decode.string))
    == Ok("call1")
}

pub fn chat_request_shape_test() {
  let request =
    openai.request("model", [
      types.User("a \"quote\"\n"),
      types.ToolOutput("call1", "done"),
    ])
  let request =
    types.Request(..request, instructions: Some("system"), tools: [tool()])
  let encoded = body(types.ChatCompletions, request)
  assert json.parse(encoded, decode.at(["n"], decode.int)) == Ok(1)
  assert json.parse(
      encoded,
      decode.at(["stream_options", "include_usage"], decode.bool),
    )
    == Ok(True)
  assert json.parse(
      encoded,
      decode.at(
        ["tools"],
        decode.list(decode.at(["function", "strict"], decode.bool)),
      ),
    )
    == Ok([True])
  assert json.parse(
      encoded,
      decode.at(["messages"], decode.list(decode.at(["role"], decode.string))),
    )
    == Ok(["system", "user", "tool"])
  let assert Ok([_, user, output]) =
    json.parse(encoded, decode.at(["messages"], decode.list(decode.dynamic)))
  assert decode.run(user, decode.at(["content"], decode.string))
    == Ok("a \"quote\"\n")
  assert decode.run(output, decode.at(["tool_call_id"], decode.string))
    == Ok("call1")
}

pub fn replay_preserves_unknown_fields_and_refuses_other_protocol_test() {
  let assert Ok(item) =
    json.parse(
      "{\"type\":\"reasoning\",\"encrypted_content\":\"opaque\",\"future\":{\"x\":1}}",
      types.replay_decoder(types.Responses),
    )
  let request = openai.request("model", [types.Replay(item)])
  let encoded = body(types.Responses, request)
  assert json.parse(
      encoded,
      decode.at(["input"], decode.list(decode.at(["future", "x"], decode.int))),
    )
    == Ok([1])
  let assert Error(types.InvalidRequest(_)) =
    request.encode(types.ChatCompletions, request)
}

pub fn validates_request_configuration_test() {
  let assert Error(types.InvalidRequest(_)) =
    request.encode(types.Responses, openai.request("  ", []))
  let request = openai.request("model", [])
  let assert Error(types.InvalidRequest(_)) =
    request.encode(
      types.Responses,
      types.Request(..request, max_output_tokens: Some(0)),
    )
  let assert Error(types.InvalidRequest(_)) =
    request.encode(
      types.Responses,
      types.Request(..request, tools: [tool(), tool()]),
    )
}
