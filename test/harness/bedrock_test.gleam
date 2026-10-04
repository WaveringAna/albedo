// Bedrock's SigV4 header construction, the Anthropic-shaped request body it
// shares with bedrock-mantle, and the AWS config/credentials file resolution
// have edge cases a fake E2E provider can't exercise without either a
// SigV4-verifying loopback server or real AWS credentials.

import albedo/harness/extensions/bedrock/aws_profile
import albedo/harness/extensions/bedrock/extension
import albedo/harness/extensions/bedrock/sigv4
import albedo/harness/extensions/bedrock/wire
import albedo/harness/extensions/claude/stream as claude_stream
import albedo/openai_api
import albedo/openai_api/stream as reducer
import albedo/openai_api/types
import gleam/bit_array
import gleam/crypto
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/string_tree

pub fn effective_base_url_defaults_to_runtime_in_the_given_region_test() -> Nil {
  assert extension.effective_base_url("", "us-east-1")
    == Ok("https://bedrock-runtime.us-east-1.amazonaws.com")
}

pub fn effective_base_url_keeps_an_explicit_url_regardless_of_region_test() -> Nil {
  let mantle = "https://bedrock-mantle.eu-west-1.api.aws"
  assert extension.effective_base_url(mantle, "us-east-1") == Ok(mantle)
  assert extension.effective_base_url(mantle, "") == Ok(mantle)
}

pub fn effective_base_url_fails_with_neither_a_url_nor_a_region_test() -> Nil {
  let assert Error(message) = extension.effective_base_url("", "")
  assert string.contains(message, "AWS_REGION")
}

// An arbitrary fixed instant; independently cross-checked against the OS
// calendar (`date -u -r 1700000000`), not derived from this code.
const epoch = 1_700_000_000

const runtime_host = "bedrock-runtime.us-east-1.amazonaws.com"

const runtime_url = "https://bedrock-runtime.us-east-1.amazonaws.com"

fn creds() -> sigv4.Credentials {
  sigv4.Credentials("AKIATEST", "topsecret", None)
}

fn header(headers: List(#(String, String)), name: String) -> String {
  let assert Ok(#(_, value)) = list.find(headers, fn(h) { h.0 == name })
  value
}

fn sha256_hex(text: String) -> String {
  crypto.hash(crypto.Sha256, bit_array.from_string(text))
  |> bit_array.base16_encode
  |> string.lowercase
}

pub fn sigv4_dates_the_request_and_lists_signed_headers_in_order_test() -> Result(
  #(String, String),
  Nil,
) {
  let headers =
    sigv4.headers(creds(), "us-east-1", "bedrock", runtime_host, epoch, "{}")
  assert header(headers, "x-amz-date") == "20231114T221320Z"
  assert header(headers, "x-amz-content-sha256") == sha256_hex("{}")
  let authorization = header(headers, "authorization")
  assert string.starts_with(
    authorization,
    "AWS4-HMAC-SHA256 Credential=AKIATEST/20231114/us-east-1/bedrock/aws4_request, SignedHeaders=content-type;host;x-amz-content-sha256;x-amz-date, Signature=",
  )
  let assert Error(Nil) =
    list.find(headers, fn(h) { h.0 == "x-amz-security-token" })
}

pub fn sigv4_adds_the_security_token_header_only_when_one_is_given_test() -> Nil {
  let with_token =
    sigv4.headers(
      sigv4.Credentials("ak", "sk", Some("tok")),
      "us-east-1",
      "bedrock",
      runtime_host,
      epoch,
      "",
    )
  assert header(with_token, "x-amz-security-token") == "tok"
  assert string.contains(
    header(with_token, "authorization"),
    "x-amz-security-token",
  )
  let without =
    sigv4.headers(
      sigv4.Credentials("ak", "sk", None),
      "us-east-1",
      "bedrock",
      runtime_host,
      epoch,
      "",
    )
  assert !string.contains(
    header(without, "authorization"),
    "x-amz-security-token",
  )
  assert list.find(without, fn(h) { h.0 == "x-amz-security-token" })
    == Error(Nil)
}

pub fn sigv4_signature_is_sensitive_to_the_body_and_the_secret_test() -> Nil {
  let base =
    sigv4.headers(creds(), "us-east-1", "bedrock", runtime_host, epoch, "one")
  let different_body =
    sigv4.headers(creds(), "us-east-1", "bedrock", runtime_host, epoch, "two")
  let different_secret =
    sigv4.headers(
      sigv4.Credentials("AKIATEST", "othersecret", None),
      "us-east-1",
      "bedrock",
      runtime_host,
      epoch,
      "one",
    )
  assert header(base, "authorization")
    != header(different_body, "authorization")
  assert header(base, "authorization")
    != header(different_secret, "authorization")
  assert header(base, "x-amz-content-sha256")
    != header(different_body, "x-amz-content-sha256")
}

fn request(model: String, input: List(types.Input)) -> types.Request {
  types.Request(model, None, input, [], Some(100), types.defaults)
}

fn exchange(
  auth: wire.Auth,
  base_url: String,
  input: List(types.Input),
) -> Result(openai_api.Exchange, types.Error) {
  wire.encode(
    auth,
    base_url,
    epoch,
    request("anthropic.claude-sonnet-5", input),
  )
}

fn body(input: List(types.Input)) -> Dynamic {
  let assert Ok(openai_api.Exchange(body: body, ..)) =
    exchange(wire.Bearer("key"), runtime_url, input)
  let assert Ok(value) = json.parse(string_tree.to_string(body), decode.dynamic)
  value
}

fn at(value: Dynamic, path: List(String), decoder: decode.Decoder(a)) -> a {
  let assert Ok(found) = decode.run(value, decode.at(path, decoder))
  found
}

pub fn encode_rejects_a_host_that_is_not_bedrock_runtime_or_mantle_test() -> Nil {
  let assert Error(types.InvalidRequest(message)) =
    exchange(wire.Bearer("key"), "https://example.com", [types.User("hi")])
  assert string.contains(message, "bedrock-runtime")
}

pub fn encode_accepts_both_bedrock_endpoints_and_keeps_their_region_test() -> Nil {
  let assert Ok(openai_api.Exchange(url: on_runtime, ..)) =
    exchange(wire.Bearer("key"), runtime_url, [types.User("hi")])
  assert on_runtime == runtime_url <> "/anthropic/v1/messages"
  let assert Ok(openai_api.Exchange(url: on_mantle, ..)) =
    exchange(wire.Bearer("key"), "https://bedrock-mantle.eu-west-1.api.aws", [
      types.User("hi"),
    ])
  assert on_mantle
    == "https://bedrock-mantle.eu-west-1.api.aws/anthropic/v1/messages"
}

pub fn encode_rejects_models_outside_the_claude_family_test() -> Nil {
  let assert Error(types.InvalidRequest(message)) =
    wire.encode(
      wire.Bearer("key"),
      runtime_url,
      epoch,
      request("meta.llama4-maverick-17b-instruct-v1:0", [types.User("hi")]),
    )
  assert string.contains(message, "Claude")
}

pub fn encode_sends_the_bearer_key_as_x_api_key_and_signs_with_sigv4_otherwise_test() -> Nil {
  let assert Ok(openai_api.Exchange(headers: bearer_headers, ..)) =
    exchange(wire.Bearer("my-key"), runtime_url, [types.User("hi")])
  assert header(bearer_headers, "x-api-key") == "my-key"
  assert list.find(bearer_headers, fn(h) { h.0 == "authorization" })
    == Error(Nil)
  let assert Ok(openai_api.Exchange(headers: sigv4_headers, ..)) =
    exchange(wire.SigV4(creds()), runtime_url, [types.User("hi")])
  assert string.starts_with(
    header(sigv4_headers, "authorization"),
    "AWS4-HMAC-SHA256",
  )
}

pub fn adjacent_same_role_turns_merge_into_one_message_test() -> Nil {
  let value =
    body([
      types.User("a"),
      types.Assistant("b"),
      types.ToolOutput("call-1", "ok", []),
      types.ToolOutput("call-2", "ok2", []),
    ])
  let assert [first, second, third] =
    at(value, ["messages"], decode.list(decode.dynamic))
  assert at(first, ["role"], decode.string) == "user"
  assert at(second, ["role"], decode.string) == "assistant"
  assert at(third, ["role"], decode.string) == "user"
  let assert [block_one, block_two] =
    at(third, ["content"], decode.list(decode.dynamic))
  assert at(block_one, ["tool_use_id"], decode.string) == "call-1"
  assert at(block_two, ["tool_use_id"], decode.string) == "call-2"
}

pub fn user_image_with_no_caption_carries_no_text_block_test() -> Nil {
  let assert Ok(image) = types.image("image/png", "aGk=", 2, 3, 2)
  let value = body([types.UserImage("", [image])])
  let assert [message] = at(value, ["messages"], decode.list(decode.dynamic))
  let assert [block] = at(message, ["content"], decode.list(decode.dynamic))
  assert at(block, ["type"], decode.string) == "image"
  assert at(block, ["source", "media_type"], decode.string) == "image/png"
}

pub fn replay_keeps_text_and_tool_calls_but_drops_thinking_test() -> Nil {
  let assert Ok(item) =
    json.parse(
      "{\"role\":\"assistant\",\"content\":\"done\",\"reasoning_content\":\"secret thoughts\",\"tool_calls\":[{\"id\":\"call-1\",\"type\":\"function\",\"function\":{\"name\":\"bash\",\"arguments\":\"{\\\"cmd\\\":\\\"ls\\\"}\"}}]}",
      types.replay_decoder(types.ChatCompletions),
    )
  let value = body([types.User("go"), types.Replay(item)])
  let assert [_, assistant] =
    at(value, ["messages"], decode.list(decode.dynamic))
  let assert [text, call] =
    at(assistant, ["content"], decode.list(decode.dynamic))
  assert at(text, ["text"], decode.string) == "done"
  assert at(call, ["type"], decode.string) == "tool_use"
  assert at(call, ["id"], decode.string) == "call-1"
  assert at(call, ["name"], decode.string) == "bash"
  assert at(call, ["input", "cmd"], decode.string) == "ls"
  let assert Ok(openai_api.Exchange(body: raw, ..)) =
    exchange(wire.Bearer("key"), runtime_url, [
      types.User("go"),
      types.Replay(item),
    ])
  assert !string.contains(string_tree.to_string(raw), "secret thoughts")
}

pub fn tool_choice_and_effort_encode_as_documented_fields_test() -> Nil {
  let tool =
    types.Tool(
      "bash",
      "run",
      json.object([#("type", json.string("object"))]),
      False,
    )
  let configured =
    types.Request(
      "anthropic.claude-sonnet-5",
      Some("be nice"),
      [types.User("hi")],
      [tool],
      Some(100),
      types.Options(
        ..types.defaults,
        tool_choice: Some(types.NamedTool("bash")),
        effort: Some("high"),
      ),
    )
  let assert Ok(openai_api.Exchange(body: raw, ..)) =
    wire.encode(wire.Bearer("key"), runtime_url, epoch, configured)
  let assert Ok(value) = json.parse(string_tree.to_string(raw), decode.dynamic)
  assert at(value, ["system"], decode.string) == "be nice"
  assert at(value, ["tool_choice", "type"], decode.string) == "tool"
  assert at(value, ["tool_choice", "name"], decode.string) == "bash"
  assert at(value, ["output_config", "effort"], decode.string) == "high"
  let assert [tool_entry] = at(value, ["tools"], decode.list(decode.dynamic))
  assert at(tool_entry, ["name"], decode.string) == "bash"
}

pub fn tool_schemas_reuse_claudes_combinator_flattening_test() -> Nil {
  let assert Ok(schema) =
    json.parse(
      "{\"oneOf\":[{\"required\":[\"a\"]},{\"required\":[\"b\"]}],\"properties\":{\"a\":{\"type\":\"string\"},\"b\":{\"type\":\"string\"}}}",
      decode.dynamic,
    )
  let tool =
    types.Tool("pick", "pick a or b", types.encode_value(schema), False)
  let configured =
    types.Request(
      "anthropic.claude-sonnet-5",
      None,
      [types.User("hi")],
      [tool],
      Some(100),
      types.defaults,
    )
  let assert Ok(openai_api.Exchange(body: raw, ..)) =
    wire.encode(wire.Bearer("key"), runtime_url, epoch, configured)
  let assert Ok(parsed) = json.parse(string_tree.to_string(raw), decode.dynamic)
  let assert [tool_entry] = at(parsed, ["tools"], decode.list(decode.dynamic))
  assert at(tool_entry, ["input_schema", "type"], decode.string) == "object"
  assert result.is_error(decode.run(
    tool_entry,
    decode.at(["input_schema", "oneOf"], decode.dynamic),
  ))
}

fn feed_all(
  state: reducer.Reducer,
  chunks: List(String),
) -> Result(types.Turn, types.Error) {
  case chunks {
    [] -> Error(types.UnexpectedEnd)
    [chunk, ..rest] -> {
      use #(next, _, turn) <- result.try(state.feed(chunk))
      case turn {
        Some(turn) -> Ok(turn)
        None -> feed_all(next, rest)
      }
    }
  }
}

pub fn a_bedrock_turn_replays_through_claudes_own_reducer_test() -> Nil {
  let chunks = [
    "{\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"usage\":{\"input_tokens\":5,\"output_tokens\":0}}}",
    "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}",
    "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"pong\"}}",
    "{\"type\":\"content_block_stop\",\"index\":0}",
    "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}",
    "{\"type\":\"message_stop\"}",
  ]
  let assert Ok(turn) =
    feed_all(claude_stream.reducer("anthropic.claude-sonnet-5", []), chunks)
  assert turn.finish == types.Complete
  let assert [item] = turn.output
  let value = body([types.User("ping"), types.Replay(item)])
  let assert [_, assistant] =
    at(value, ["messages"], decode.list(decode.dynamic))
  let assert [text] = at(assistant, ["content"], decode.list(decode.dynamic))
  assert at(text, ["text"], decode.string) == "pong"
}

pub fn parse_section_finds_default_and_named_profile_headers_test() -> Result(
  Dict(String, String),
  Nil,
) {
  let text =
    "[default]\nregion = us-east-1\n\n[profile other]\ncredential_process = /bin/echo hi\n"
  let assert Ok(default_section) = aws_profile.parse_section(text, "default")
  assert dict.get(default_section, "region") == Ok("us-east-1")
  let assert Ok(other) = aws_profile.parse_section(text, "profile other")
  assert dict.get(other, "credential_process") == Ok("/bin/echo hi")
  aws_profile.parse_section(text, "profile missing")
}

pub fn parse_section_keeps_equals_signs_inside_values_test() -> Nil {
  let text = "[default]\naws_session_token = abc=def==\n"
  let assert Ok(section) = aws_profile.parse_section(text, "default")
  assert dict.get(section, "aws_session_token") == Ok("abc=def==")
}

pub fn config_header_only_prefixes_named_profiles_test() -> Nil {
  assert aws_profile.config_header("default") == "default"
  assert aws_profile.config_header("work") == "profile work"
}

pub fn credentials_from_section_names_the_missing_key_test() -> Nil {
  let assert Error(message) =
    aws_profile.credentials_from_section(dict.new(), "work")
  assert string.contains(message, "aws_access_key_id")
  let partial = dict.from_list([#("aws_access_key_id", "ak")])
  let assert Error(message) =
    aws_profile.credentials_from_section(partial, "work")
  assert string.contains(message, "aws_secret_access_key")
  let complete =
    dict.from_list([
      #("aws_access_key_id", "ak"),
      #("aws_secret_access_key", "sk"),
      #("aws_session_token", "tok"),
    ])
  assert aws_profile.credentials_from_section(complete, "work")
    == Ok(sigv4.Credentials("ak", "sk", Some("tok")))
}

pub fn credentials_from_process_output_decodes_the_documented_json_test() -> Nil {
  assert aws_profile.credentials_from_process_output(
      "{\"Version\":1,\"AccessKeyId\":\"AKIATEST\",\"SecretAccessKey\":\"topsecret\",\"SessionToken\":\"tok\"}",
    )
    == Ok(sigv4.Credentials("AKIATEST", "topsecret", Some("tok")))
  let assert Ok(sigv4.Credentials(_, _, None)) =
    aws_profile.credentials_from_process_output(
      "{\"Version\":1,\"AccessKeyId\":\"a\",\"SecretAccessKey\":\"b\"}",
    )
  assert result.is_error(aws_profile.credentials_from_process_output("not json"))
}
