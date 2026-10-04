// Vertex's generateContent request body, its SSE decoding, and ADC
// credential-shape branching (service-account vs. plain and
// workforce-federated refresh tokens) have edge cases a fake E2E provider
// can't exercise without a Vertex-shaped loopback server and real Google
// credentials.

import albedo/harness/extensions/vertex/auth
import albedo/harness/extensions/vertex/stream
import albedo/harness/extensions/vertex/wire
import albedo/openai_api
import albedo/openai_api/types
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/string_tree

const project = "my-project"

const location = "us-central1"

fn request(model: String, input: List(types.Input)) -> types.Request {
  types.Request(model, None, input, [], Some(100), types.defaults)
}

fn gemini_request(input: List(types.Input)) -> types.Request {
  request("gemini-2.5-flash", input)
}

fn body(input: List(types.Input)) -> Dynamic {
  let assert Ok(openai_api.Exchange(body: body, ..)) =
    wire.encode("token", project, location, gemini_request(input))
  let assert Ok(value) = json.parse(string_tree.to_string(body), decode.dynamic)
  value
}

fn at(value: Dynamic, path: List(String), decoder: decode.Decoder(a)) -> a {
  let assert Ok(found) = decode.run(value, decode.at(path, decoder))
  found
}

pub fn encode_rejects_models_outside_the_gemini_family_test() -> Nil {
  let assert Error(types.InvalidRequest(message)) =
    wire.encode(
      "token",
      project,
      location,
      request("claude-opus-5@default", [types.User("hi")]),
    )
  assert string.contains(message, "Gemini")
}

pub fn encode_builds_the_project_and_location_scoped_url_and_bearer_header_test() -> Nil {
  let assert Ok(openai_api.Exchange(url: url, headers: headers, ..)) =
    wire.encode(
      "my-token",
      project,
      location,
      gemini_request([types.User("hi")]),
    )
  assert url
    == "https://us-central1-aiplatform.googleapis.com/v1/projects/my-project/locations/us-central1/publishers/google/models/gemini-2.5-flash:streamGenerateContent?alt=sse"
  let assert Ok(#(_, authorization)) =
    list.find(headers, fn(h) { h.0 == "authorization" })
  assert authorization == "Bearer my-token"
}

pub fn encode_uses_the_bare_host_for_the_global_location_test() -> Nil {
  let assert Ok(openai_api.Exchange(url: url, ..)) =
    wire.encode("t", project, "global", gemini_request([types.User("hi")]))
  assert string.starts_with(url, "https://aiplatform.googleapis.com/")
}

pub fn tool_output_looks_up_its_calls_name_from_the_replayed_history_test() -> Nil {
  let assert Ok(item) =
    json.parse(
      "{\"role\":\"assistant\",\"content\":null,\"tool_calls\":[{\"id\":\"c1\",\"type\":\"function\",\"function\":{\"name\":\"bash\",\"arguments\":\"{}\"}}]}",
      types.replay_decoder(types.ChatCompletions),
    )
  let value =
    body([
      types.User("a"),
      types.Replay(item),
      types.ToolOutput("c1", "done", []),
    ])
  let assert [user, model, result] =
    at(value, ["contents"], decode.list(decode.dynamic))
  assert at(user, ["role"], decode.string) == "user"
  assert at(model, ["role"], decode.string) == "model"
  assert at(result, ["role"], decode.string) == "user"
  let assert [part] = at(result, ["parts"], decode.list(decode.dynamic))
  assert at(part, ["functionResponse", "name"], decode.string) == "bash"
  assert at(part, ["functionResponse", "response", "output"], decode.string)
    == "done"
}

pub fn tool_output_without_a_preceding_call_is_refused_test() -> Nil {
  let assert Error(types.InvalidRequest(message)) =
    wire.encode(
      "t",
      project,
      location,
      gemini_request([types.ToolOutput("missing", "x", [])]),
    )
  assert string.contains(message, "no preceding call")
}

pub fn replayed_calls_always_carry_the_foreign_signature_placeholder_test() -> Nil {
  let assert Ok(item) =
    json.parse(
      "{\"role\":\"assistant\",\"content\":null,\"tool_calls\":[{\"id\":\"c1\",\"type\":\"function\",\"function\":{\"name\":\"bash\",\"arguments\":\"{}\"}}]}",
      types.replay_decoder(types.ChatCompletions),
    )
  let value = body([types.User("a"), types.Replay(item)])
  let assert [_, model] = at(value, ["contents"], decode.list(decode.dynamic))
  let assert [call] = at(model, ["parts"], decode.list(decode.dynamic))
  assert at(call, ["thoughtSignature"], decode.string)
    == "skip_thought_signature_validator"
}

pub fn tool_choice_modes_map_to_function_calling_config_test() -> Nil {
  let tool = types.Tool("bash", "run", json.object([]), False)
  let named =
    types.Request(
      "gemini-2.5-flash",
      None,
      [types.User("hi")],
      [tool],
      Some(100),
      types.Options(
        ..types.defaults,
        tool_choice: Some(types.NamedTool("bash")),
      ),
    )
  let assert Ok(openai_api.Exchange(body: raw, ..)) =
    wire.encode("t", project, location, named)
  let assert Ok(value) = json.parse(string_tree.to_string(raw), decode.dynamic)
  assert at(
      value,
      ["toolConfig", "functionCallingConfig", "mode"],
      decode.string,
    )
    == "ANY"
  assert at(
      value,
      ["toolConfig", "functionCallingConfig", "allowedFunctionNames"],
      decode.list(decode.string),
    )
    == ["bash"]
}

/// Feeds every chunk, then ends the body: Gemini chunks carry no explicit
/// terminal event, so `finish` (not `feed`) settles the turn.
fn reduce(chunks: List(String)) -> Result(types.Turn, types.Error) {
  let final =
    list.fold(chunks, stream.reducer(), fn(state, data) {
      let assert Ok(#(next, _, None)) = state.feed(data)
      next
    })
  final.finish()
}

pub fn stream_decodes_text_thought_and_usage_test() -> Nil {
  let chunks = [
    "{\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"thinking\",\"thought\":true}]}}]}",
    "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"pong\"}]},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":3,\"candidatesTokenCount\":1,\"thoughtsTokenCount\":2}}",
  ]
  let assert Ok(turn) = reduce(chunks)
  assert turn.finish == types.Complete
  let assert [item] = turn.output
  let assert Ok(value) =
    json.parse(json.to_string(types.replay_json(item)), decode.dynamic)
  assert at(value, ["content"], decode.string) == "pong"
  assert at(value, ["reasoning_content"], decode.string) == "thinking"
  let assert Some(usage) = turn.usage
  assert usage.input_tokens == 3
  assert usage.output_tokens == 1
  assert usage.reasoning_tokens == Some(2)
}

pub fn stream_decodes_a_function_call_with_an_indexed_id_test() -> Nil {
  let chunks = [
    "{\"candidates\":[{\"content\":{\"parts\":[{\"functionCall\":{\"name\":\"bash\",\"args\":{\"cmd\":\"ls\"}}}]},\"finishReason\":\"STOP\"}]}",
  ]
  let assert Ok(turn) = reduce(chunks)
  assert turn.finish == types.ToolCalls
  let assert [call] = turn.tool_calls
  assert call.id == "call_0"
  assert call.name == "bash"
  assert call.arguments == "{\"cmd\":\"ls\"}"
}

pub fn stream_maps_finish_reasons_to_albedo_finish_values_test() -> Nil {
  let finish = fn(reason) {
    let assert Ok(turn) =
      reduce([
        "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"x\"}]},\"finishReason\":\""
        <> reason
        <> "\"}]}",
      ])
    turn.finish
  }
  assert finish("MAX_TOKENS") == types.LengthLimit
  assert finish("SAFETY") == types.ContentFiltered
  assert finish("WEIRD") == types.OtherFinish("WEIRD")
}

pub fn stream_errors_surface_the_provider_message_test() -> Nil {
  let assert Error(types.ProviderError(message)) =
    stream.reducer().feed("{\"error\":{\"message\":\"quota\"}}")
  assert message == "quota"
}

pub fn stream_reports_blocked_prompts_test() -> Nil {
  let assert Error(types.ProviderError(message)) =
    stream.reducer().feed("{\"promptFeedback\":{\"blockReason\":\"SAFETY\"}}")
  assert string.contains(message, "SAFETY")
}

pub fn from_text_recognizes_a_service_account_key_test() -> Nil {
  assert auth.from_text(
      "{\"type\":\"service_account\",\"client_email\":\"sa@example.com\",\"private_key\":\"-----BEGIN PRIVATE KEY-----\\nkey\\n-----END PRIVATE KEY-----\\n\"}",
    )
    == Ok(auth.ServiceAccount(
      "sa@example.com",
      "-----BEGIN PRIVATE KEY-----\nkey\n-----END PRIVATE KEY-----\n",
      "https://oauth2.googleapis.com/token",
    ))
}

pub fn from_text_recognizes_a_plain_refresh_token_and_defaults_its_endpoint_test() -> Nil {
  assert auth.from_text(
      "{\"type\":\"authorized_user\",\"client_id\":\"client-id\",\"client_secret\":\"client-secret\",\"refresh_token\":\"refresh\"}",
    )
    == Ok(auth.RefreshToken(
      "client-id",
      "client-secret",
      "refresh",
      "https://oauth2.googleapis.com/token",
      False,
    ))
}

pub fn from_text_uses_basic_auth_only_when_the_file_names_its_own_token_url_test() -> Nil {
  assert auth.from_text(
      "{\"type\":\"external_account_authorized_user\",\"client_id\":\"id\",\"client_secret\":\"secret\",\"refresh_token\":\"r\",\"token_url\":\"https://sts.example.com/token\"}",
    )
    == Ok(auth.RefreshToken(
      "id",
      "secret",
      "r",
      "https://sts.example.com/token",
      True,
    ))
}

pub fn from_text_rejects_a_credential_with_neither_shape_test() -> Nil {
  let assert Error(message) = auth.from_text("{\"type\":\"authorized_user\"}")
  assert string.contains(
    message,
    "neither a service-account key nor a refresh-token credential",
  )
}

pub fn from_text_rejects_malformed_json_test() -> Nil {
  assert result.is_error(auth.from_text("not json"))
}
