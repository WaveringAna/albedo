import albedo/openai_api as openai
import albedo/openai_api/request
import albedo/openai_api/types
import gleam/dynamic/decode
import gleam/json
import gleam/option.{Some}
import gleam/result
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
      types.ToolOutput("call1", "file contents", []),
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
      types.ToolOutput("call1", "done", []),
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

fn test_image() -> types.Image {
  let assert Ok(image) = types.image("image/png", "aGVsbG8=", 2, 3, 5)
  image
}

pub fn responses_image_input_shape_test() {
  let encoded =
    openai.request("vision-model", [
      types.UserImage("describe this", test_image()),
    ])
    |> body(types.Responses, _)
  let assert Ok([user]) =
    json.parse(encoded, decode.at(["input"], decode.list(decode.dynamic)))
  assert decode.run(
      user,
      decode.at(["content"], decode.list(decode.at(["type"], decode.string))),
    )
    == Ok(["input_text", "input_image"])
  let assert Ok([_, image]) =
    decode.run(user, decode.at(["content"], decode.list(decode.dynamic)))
  assert decode.run(image, decode.at(["image_url"], decode.string))
    == Ok("data:image/png;base64,aGVsbG8=")
}

pub fn chat_completions_image_input_shape_test() {
  let encoded =
    openai.request("vision-model", [
      types.UserImage("describe this", test_image()),
    ])
    |> body(types.ChatCompletions, _)
  let assert Ok([user]) =
    json.parse(encoded, decode.at(["messages"], decode.list(decode.dynamic)))
  assert decode.run(
      user,
      decode.at(["content"], decode.list(decode.at(["type"], decode.string))),
    )
    == Ok(["text", "image_url"])
  let assert Ok([_, image]) =
    decode.run(user, decode.at(["content"], decode.list(decode.dynamic)))
  assert decode.run(image, decode.at(["image_url", "url"], decode.string))
    == Ok("data:image/png;base64,aGVsbG8=")
}

pub fn validates_image_metadata_bounds_test() {
  let assert Error(types.InvalidRequest(_)) =
    types.image("image/gif", "aGVsbG8=", 2, 3, 5)
  let assert Error(types.InvalidRequest(_)) =
    types.image("image/png", "aGVsbG8=", 10_000, 5000, 5)
  let assert Error(types.InvalidRequest(_)) =
    types.image("image/png", "aGVsbG8=", 2, 3, types.max_image_bytes + 1)
}

pub fn codex_request_policy_adds_subscription_fields_test() {
  let request = types.Request(..openai.request("model", []), tools: [tool()])
  let assert Ok(tree) =
    request.encode_with_policy(
      types.Responses,
      types.Codex("account", "session"),
      request,
    )
  let encoded = string_tree.to_string(tree)
  assert json.parse(encoded, decode.at(["tool_choice"], decode.string))
    == Ok("auto")
  assert json.parse(encoded, decode.at(["parallel_tool_calls"], decode.bool))
    == Ok(True)
  assert json.parse(encoded, decode.at(["text", "verbosity"], decode.string))
    == Ok("low")
  assert json.parse(encoded, decode.at(["reasoning", "effort"], decode.string))
    == Ok("medium")
  assert json.parse(encoded, decode.at(["reasoning", "summary"], decode.string))
    == Ok("auto")
  assert json.parse(encoded, decode.at(["prompt_cache_key"], decode.string))
    == Ok("session")
  assert json.parse(encoded, decode.at(["max_output_tokens"], decode.int))
    |> result.is_error
  assert json.parse(
      encoded,
      decode.at(["tools"], decode.list(decode.at(["strict"], decode.dynamic))),
    )
    |> result.is_ok
}

fn tool_image() -> types.Image {
  let assert Ok(image) =
    types.image("image/png", "iVBORw0KGgoAAAANSUhEUgAAAAIAAAAD", 2, 3, 24)
  image
}

pub fn responses_tool_images_ride_in_the_function_call_output_test() {
  let request =
    openai.request("model", [
      types.ToolOutput("call1", "rendered", [tool_image()]),
      types.ToolOutput("call2", "plain", []),
    ])
  let encoded = body(types.Responses, request)
  let assert Ok([with_image, plain]) =
    json.parse(encoded, decode.at(["input"], decode.list(decode.dynamic)))
  let part = {
    use kind <- decode.field("type", decode.string)
    use text <- decode.optional_field("text", "", decode.string)
    use url <- decode.optional_field("image_url", "", decode.string)
    decode.success(#(kind, text, url))
  }
  assert decode.run(with_image, decode.at(["output"], decode.list(part)))
    == Ok([
      #("input_text", "rendered", ""),
      #(
        "input_image",
        "",
        "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAIAAAAD",
      ),
    ])
  assert decode.run(plain, decode.at(["output"], decode.string)) == Ok("plain")
}

pub fn chat_tool_images_follow_the_whole_run_of_results_test() {
  let request =
    openai.request("model", [
      types.ToolOutput("call1", "", [tool_image()]),
      types.ToolOutput("call2", "plain", []),
      types.ToolOutput("call3", "more", [tool_image()]),
      types.User("next"),
    ])
  let encoded = body(types.ChatCompletions, request)
  assert json.parse(
      encoded,
      decode.at(["messages"], decode.list(decode.at(["role"], decode.string))),
    )
    == Ok(["tool", "tool", "tool", "user", "user"])
  let assert Ok([empty, _, _, images, _]) =
    json.parse(encoded, decode.at(["messages"], decode.list(decode.dynamic)))
  assert decode.run(empty, decode.at(["content"], decode.string))
    == Ok("(see attached image)")
  let part = {
    use kind <- decode.field("type", decode.string)
    use text <- decode.optional_field("text", "", decode.string)
    decode.success(#(kind, text))
  }
  assert decode.run(images, decode.at(["content"], decode.list(part)))
    == Ok([
      #("text", "Images from tool call call1:"),
      #("image_url", ""),
      #("text", "Images from tool call call3:"),
      #("image_url", ""),
    ])
}

fn options() -> types.Options {
  types.Options(
    Some(0.2),
    Some(0.9),
    ["END"],
    Some(types.NamedTool("read_file")),
    Some(False),
    Some("low"),
    Some(types.JsonSchema(
      "answer",
      json.object([#("type", json.string("object"))]),
      True,
    )),
  )
}

fn with_options(tools) {
  types.Request(
    ..openai.request("model", [types.User("hi")]),
    tools: tools,
    options: options(),
  )
}

fn field(encoded: String, path: List(String), decoder) {
  json.parse(encoded, decode.at(path, decoder))
}

pub fn chat_encodes_generation_options_test() {
  let encoded = body(types.ChatCompletions, with_options([tool()]))
  assert field(encoded, ["temperature"], decode.float) == Ok(0.2)
  assert field(encoded, ["top_p"], decode.float) == Ok(0.9)
  assert field(encoded, ["stop"], decode.list(decode.string)) == Ok(["END"])
  assert field(encoded, ["tool_choice", "function", "name"], decode.string)
    == Ok("read_file")
  assert field(encoded, ["parallel_tool_calls"], decode.bool) == Ok(False)
  assert field(encoded, ["reasoning_effort"], decode.string) == Ok("low")
  assert field(
      encoded,
      ["response_format", "json_schema", "name"],
      decode.string,
    )
    == Ok("answer")
  // Without tools OpenAI rejects parallel_tool_calls, so it is left out.
  let bare = body(types.ChatCompletions, with_options([]))
  let assert Error(_) = field(bare, ["parallel_tool_calls"], decode.bool)
}

pub fn responses_encodes_generation_options_test() {
  let encoded = body(types.Responses, with_options([tool()]))
  assert field(encoded, ["reasoning", "effort"], decode.string) == Ok("low")
  assert field(encoded, ["tool_choice", "name"], decode.string)
    == Ok("read_file")
  assert field(encoded, ["text", "format", "name"], decode.string)
    == Ok("answer")
  assert field(encoded, ["temperature"], decode.float) == Ok(0.2)
  // Responses has no stop sequences.
  let assert Error(_) = field(encoded, ["stop"], decode.dynamic)
}

pub fn codex_overrides_only_what_its_backend_accepts_test() {
  let assert Ok(encoded) =
    request.encode_with_policy(
      types.Responses,
      types.Codex("account", "session"),
      with_options([tool()]),
    )
  let encoded = string_tree.to_string(encoded)
  assert field(encoded, ["reasoning", "effort"], decode.string) == Ok("low")
  assert field(encoded, ["reasoning", "summary"], decode.string) == Ok("auto")
  assert field(encoded, ["parallel_tool_calls"], decode.bool) == Ok(False)
  assert field(encoded, ["text", "verbosity"], decode.string) == Ok("low")
  assert field(encoded, ["text", "format", "type"], decode.string)
    == Ok("json_schema")
  let assert Error(_) = field(encoded, ["temperature"], decode.float)
  let assert Ok(defaults) =
    request.encode_with_policy(
      types.Responses,
      types.Codex("account", "session"),
      openai.request("model", [types.User("hi")]),
    )
  let defaults = string_tree.to_string(defaults)
  assert field(defaults, ["reasoning", "effort"], decode.string) == Ok("medium")
  assert field(defaults, ["tool_choice"], decode.string) == Ok("auto")
}
