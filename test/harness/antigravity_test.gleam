import albedo/daemon/configuration
import albedo/daemon/projection
import albedo/daemon/transcript
import albedo/harness/extensions/antigravity/catalog
import albedo/harness/extensions/antigravity/extension as antigravity
import albedo/harness/extensions/antigravity/stream
import albedo/harness/extensions/antigravity/wire
import albedo/harness/oauth
import albedo/openai_api
import albedo/openai_api/types
import gleam/dynamic
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/string_tree

const gemini = "gemini-3.1-pro-low"

const claude = "claude-sonnet-4-6"

/// No discovery cache here, so the built-in table answers.
fn model(id: String) -> catalog.Model {
  catalog.model("/nonexistent/albedo-home", id, None)
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
    types.ArgumentsDelta(0, arguments),
  ] = events
  assert arguments == "{\"command\":\"ls\"}"
  assert turn.finish == types.ToolCalls
  assert turn.usage == Some(types.Usage(10, 5, Some(4)))
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

pub fn envelope_carries_project_identity_and_thinking_test() {
  let request =
    types.Request(
      gemini,
      Some("be brief"),
      [types.User("hi")],
      [],
      None,
      types.defaults,
    )
  let value = body(gemini, request)
  assert at(value, ["project"], decode.string) == "project-1"
  assert at(value, ["model"], decode.string) == gemini
  assert at(value, ["requestType"], decode.string) == "agent"
  assert at(
      value,
      ["request", "systemInstruction", "parts"],
      decode.list(decode.at(["text"], decode.string)),
    )
    == ["be brief"]
  assert at(value, ["request", "labels", "model_enum"], decode.string)
    == "MODEL_PLACEHOLDER_M36"
  assert at(value, ["request", "labels", "used_claude"], decode.string)
    == "false"
  assert at(
      value,
      ["request", "generationConfig", "thinkingConfig", "thinkingBudget"],
      decode.int,
    )
    == 10_001
  let session = at(value, ["request", "sessionId"], decode.string)
  assert string.starts_with(session, "-")
  assert session
    == at(body(gemini, request), ["request", "sessionId"], decode.string)
  // Gemini without tools leaves tool mode to the backend.
  let assert Error(_) =
    decode.run(value, decode.at(["request", "toolConfig"], decode.dynamic))
}

pub fn tool_schemas_are_flattened_for_cloud_code_assist_test() {
  let assert Ok(schema) =
    json.parse(
      "{\"type\":\"object\",\"$defs\":{\"mode\":{\"enum\":[\"a\",\"b\"]}},\"additionalProperties\":false,\"properties\":{\"mode\":{\"$ref\":\"#/$defs/mode\"},\"count\":{\"type\":[\"integer\",\"null\"],\"minimum\":1},\"either\":{\"anyOf\":[{\"type\":\"string\"},{\"type\":\"null\"}]},\"level\":{\"const\":3}},\"required\":[\"mode\",\"ghost\"]}",
      decode.dynamic,
    )
  let tool = types.Tool("t", "d", wire.encode_value(schema), False)
  let value =
    body(
      gemini,
      types.Request(
        gemini,
        None,
        [types.User("hi")],
        [tool],
        None,
        types.defaults,
      ),
    )
  let parameters =
    at(
      value,
      ["request", "tools"],
      decode.list(decode.at(
        ["functionDeclarations"],
        decode.list(decode.at(["parameters"], decode.dynamic)),
      )),
    )
  let assert [[parameters]] = parameters
  assert at(
      parameters,
      ["properties", "mode", "enum"],
      decode.list(decode.string),
    )
    == ["a", "b"]
  assert at(parameters, ["properties", "count", "type"], decode.string)
    == "integer"
  assert string.contains(
    at(parameters, ["properties", "count", "description"], decode.string),
    "minimum: 1",
  )
  assert at(parameters, ["properties", "either", "type"], decode.string)
    == "string"
  assert at(
      parameters,
      ["properties", "level", "enum"],
      decode.list(decode.string),
    )
    == ["3"]
  assert at(parameters, ["required"], decode.list(decode.string)) == ["mode"]
  let assert Error(_) =
    decode.run(parameters, decode.at(["additionalProperties"], decode.dynamic))
  assert at(
      value,
      ["request", "toolConfig", "functionCallingConfig", "mode"],
      decode.string,
    )
    == "VALIDATED"
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

pub fn antigravity_output_projects_to_other_providers_test() {
  let #(outcome, _) = reduce(gemini, signed_turn_payloads())
  let assert Ok(turn) = outcome
  let assert [item] = turn.output
  let entry = fn(input) { transcript.Entry(input, None, Some("antigravity")) }
  let assert Ok(inputs) =
    projection.for_model(
      [entry(types.Replay(item)), entry(types.User("hi"))],
      "openai",
      types.Responses,
    )
  assert list.length(inputs) == 3
}

pub fn rejected_sign_in_expires_the_token_for_a_refresh_test() {
  let #(root, _, home) = fixture()
  let _ =
    write(
      home,
      "auth.json",
      "{\"google-antigravity\":{\"type\":\"oauth\",\"access\":\"a1\",\"refresh\":\"r1\",\"expires\":9999999999999,\"projectId\":\"p1\"}}",
    )
  let access = antigravity.Access("a1", "p1", "me@example.com")
  let assert Some(message) =
    antigravity.explain(home, access, types.HttpError(401, ""))
  assert string.ends_with(message, "run /login")
  assert string.contains(message, "me@example.com")
  let assert Ok(store) = read_store(home <> "/auth.json")
  assert decode.run(
      store,
      decode.at(["google-antigravity", "expires"], decode.int),
    )
    == Ok(0)
  cleanup(root)
}

pub fn failures_tell_the_user_what_to_do_test() {
  let access = antigravity.Access("a", "p", "")
  let body =
    "{\"error\":{\"code\":403,\"message\":\"verify\",\"details\":[{\"reason\":\"VALIDATION_REQUIRED\",\"metadata\":{\"validation_url\":\"https://accounts.google.com/v\"}}]}}"
  let assert Some(message) =
    antigravity.explain("/nonexistent", access, types.HttpError(403, body))
  assert string.contains(message, "https://accounts.google.com/v")
  assert antigravity.explain("/nonexistent", access, types.Timeout) == None
}

pub fn antigravity_profiles_require_chat_completions_test() {
  let #(root, _, home) = fixture()
  let _ =
    write(
      home,
      "config.json",
      "{\"active\":\"ok\",\"providers\":{\"ok\":{\"extension\":\"antigravity\",\"model\":\"gemini-3-flash-agent\",\"protocol\":\"chat_completions\"},\"bad\":{\"extension\":\"antigravity\",\"model\":\"gemini-3-flash-agent\",\"protocol\":\"responses\"}}}",
    )
  let assert Ok(_) = configuration.named(home, "ok")
  let assert Error(_) = configuration.named(home, "bad")
  cleanup(root)
}

pub fn access_prefers_the_selected_fresh_account_test() {
  let #(root, _, home) = fixture()
  let assert Error(_) = native_access(home)
  let _ =
    write(
      home,
      "auth.json",
      "{\"google-antigravity\":[{\"type\":\"oauth\",\"access\":\"a1\",\"refresh\":\"r1\",\"expires\":9999999999999,\"projectId\":\"p1\"},{\"type\":\"oauth\",\"access\":\"a2\",\"refresh\":\"r2\",\"expires\":9999999999999,\"projectId\":\"p2\",\"email\":\"b@example.com\",\"selected\":true}]}",
    )
  let assert Ok(encoded) = native_access(home)
  assert json.parse(encoded, decode.at(["access"], decode.string)) == Ok("a2")
  assert json.parse(encoded, decode.at(["projectId"], decode.string))
    == Ok("p2")
  cleanup(root)
}

@external(erlang, "albedo_antigravity", "access")
fn native_access(home: String) -> Result(String, String)

@external(erlang, "albedo_skills_test_support", "fixture")
fn fixture() -> #(String, String, String)

@external(erlang, "albedo_skills_test_support", "write")
fn write(base: String, relative: String, content: String) -> String

@external(erlang, "albedo_skills_test_support", "cleanup")
fn cleanup(root: String) -> Nil

pub fn discovery_supplies_ids_and_model_enums_test() {
  let #(root, _, home) = fixture()
  let _ =
    write(
      home,
      "antigravity.json",
      "{\"version\":\"9.9.9\",\"models\":[{\"id\":\"gemini-3-flash-agent\",\"name\":\"Gemini 3.5 Flash (High)\",\"context\":1048576,\"output\":65536,\"images\":true,\"modelEnum\":\"MODEL_PLACEHOLDER_M84\"},{\"id\":\"gemini-9-flash-high\",\"name\":\"Gemini 9\",\"context\":1000,\"output\":100,\"images\":false}],\"renamed\":{\"gemini-3.1-pro-high\":\"gemini-9-flash-high\"}}",
    )
  assert list.map(catalog.models(home), fn(model) { model.id })
    == ["gemini-3-flash-agent", "gemini-9-flash-high"]
  let known = catalog.model(home, "gemini-3-flash-agent", None)
  assert known.model_enum == Some("MODEL_PLACEHOLDER_M84")
  assert known.thinking == catalog.Budget(1000, 4000, 10_000)
  let fresh = catalog.model(home, "gemini-9-flash-high", None)
  assert fresh.context_tokens == 1000
  assert !fresh.images
  assert catalog.model(home, "gemini-3.1-pro-high", None).id
    == "gemini-9-flash-high"
  assert string.contains(native_user_agent(home), "antigravity/hub/9.9.9 ")
  cleanup(root)
}

@external(erlang, "albedo_antigravity", "user_agent")
fn native_user_agent(home: String) -> String

@external(erlang, "albedo_credentials", "read")
fn read_store(path: String) -> Result(dynamic.Dynamic, dynamic.Dynamic)

const token_ok = "{\"access_token\":\"at\",\"refresh_token\":\"rt\",\"expires_in\":3600}"

fn sign_in(routes: List(#(String, List(#(Int, String))))) {
  use base, log <- with_routes(routes)
  let endpoints =
    antigravity.Endpoints(base <> "/token", base <> "/userinfo", base)
  let login = antigravity.login(endpoints)
  let grant =
    oauth.Grant("http://127.0.0.1:51121/oauth-callback", "s", "v", "c")
  let outcome = login.exchange(grant, "code-1", fn(_) { Nil })
  #(
    outcome
      |> result.map(fn(credential) {
        let assert Ok(value) =
          json.parse(json.to_string(credential), decode.dynamic)
        value
      }),
    seen(log),
  )
}

pub fn sign_in_provisions_the_free_tier_and_stores_the_project_test() {
  let #(outcome, seen) =
    sign_in([
      #("/token", [#(200, token_ok)]),
      #("/userinfo", [#(200, "{\"email\":\"Me@Example.com\"}")]),
      #("/v1internal:loadCodeAssist", [
        #(200, "{\"allowedTiers\":[{\"id\":\"free-tier\"}]}"),
        #(
          200,
          "{\"currentTier\":{\"id\":\"free-tier\"},\"cloudaicompanionProject\":\"proj-9\"}",
        ),
      ]),
      #("/v1internal:onboardUser", [
        #(200, "{\"name\":\"operations/o1\",\"done\":false}"),
      ]),
      #("/v1internal/operations/o1", [
        #(200, "{\"name\":\"operations/o1\",\"done\":true,\"response\":{}}"),
      ]),
    ])
  let assert Ok(credential) = outcome
  assert decode.run(credential, decode.at(["projectId"], decode.string))
    == Ok("proj-9")
  assert decode.run(credential, decode.at(["email"], decode.string))
    == Ok("me@example.com")
  assert decode.run(credential, decode.at(["refresh"], decode.string))
    == Ok("rt")
  assert list.contains(seen, "/v1internal:onboardUser")
  assert list.contains(seen, "/v1internal/operations/o1")
  let account =
    antigravity.login(antigravity.Endpoints("", "", "")).account(credential)
  assert account
    == oauth.Account(
      "me@example.com",
      "me@example.com",
      "antigravity account",
      False,
    )
}

pub fn an_ineligible_account_fails_with_googles_reason_test() {
  let #(outcome, _) =
    sign_in([
      #("/token", [#(200, token_ok)]),
      #("/userinfo", [#(500, "{}")]),
      #("/v1internal:loadCodeAssist", [
        #(
          200,
          "{\"ineligibleTiers\":[{\"tierId\":\"free-tier\",\"reasonMessage\":\"not in your region\",\"validationUrl\":\"https://g.co/v\"}]}",
        ),
      ]),
    ])
  assert outcome == Error("not in your region\nhttps://g.co/v")
}

pub fn a_grant_without_a_refresh_token_is_rejected_test() {
  let #(outcome, seen) =
    sign_in([
      #("/token", [#(200, "{\"access_token\":\"at\",\"expires_in\":3600}")]),
    ])
  assert outcome == Error("no refresh token received; sign in again")
  assert seen == ["/token"]
}

pub fn antigravity_authorizes_on_its_loopback_redirect_test() {
  let login = antigravity.login(antigravity.Endpoints("", "", ""))
  assert login.callback
    == oauth.Callback("127.0.0.1", 51_121, "/oauth-callback", False)
  assert login.store == "google-antigravity"
  let url =
    login.authorize(oauth.Grant(
      "http://127.0.0.1:51121/oauth-callback",
      "st",
      "v",
      "c",
    ))
  assert string.starts_with(
    url,
    "https://accounts.google.com/o/oauth2/v2/auth?",
  )
  assert string.contains(url, "access_type=offline")
  assert string.contains(url, "state=st")
  assert string.contains(url, "apps.googleusercontent.com")
}

@external(erlang, "albedo_antigravity_test_support", "with_routes")
fn with_routes(
  routes: List(#(String, List(#(Int, String)))),
  run: fn(String, dynamic.Dynamic) -> a,
) -> a

@external(erlang, "albedo_antigravity_test_support", "seen")
fn seen(log: dynamic.Dynamic) -> List(String)

pub fn effort_and_forced_tools_reach_the_envelope_test() {
  let tool =
    types.Tool(
      "bash",
      "run",
      json.object([#("type", json.string("object"))]),
      False,
    )
  let options =
    types.Options(
      ..types.defaults,
      temperature: Some(0.5),
      effort: Some("low"),
      tool_choice: Some(types.NamedTool("bash")),
      format: Some(types.JsonObject),
    )
  let request =
    types.Request(gemini, None, [types.User("hi")], [tool], None, options)
  let value = body(gemini, request)
  assert at(
      value,
      ["request", "generationConfig", "thinkingConfig", "thinkingBudget"],
      decode.int,
    )
    == 1001
  assert at(value, ["request", "generationConfig", "temperature"], decode.float)
    == 0.5
  assert at(
      value,
      ["request", "generationConfig", "responseMimeType"],
      decode.string,
    )
    == "application/json"
  assert at(
      value,
      ["request", "toolConfig", "functionCallingConfig", "allowedFunctionNames"],
      decode.list(decode.string),
    )
    == ["bash"]
  // Gemini routes drop toolConfig, so the choice is restated last.
  let contents = at(value, ["request", "contents"], decode.list(decode.dynamic))
  let assert Ok(last) = list.last(contents)
  let assert [_, directive] =
    at(last, ["parts"], decode.list(decode.at(["text"], decode.string)))
  assert string.contains(directive, "Call bash.")
  // Level models take a named level; Claude always runs VALIDATED.
  let level =
    body(
      "gemini-3.7-flash-low",
      types.Request(
        ..request,
        model: "gemini-3.7-flash-low",
        options: types.Options(..options, effort: Some("medium")),
      ),
    )
  assert at(
      level,
      ["request", "generationConfig", "thinkingConfig", "thinkingLevel"],
      decode.string,
    )
    == "MEDIUM"
  let claude_body = body(claude, types.Request(..request, model: claude))
  assert at(
      claude_body,
      ["request", "toolConfig", "functionCallingConfig", "mode"],
      decode.string,
    )
    == "VALIDATED"
}

pub fn antigravity_collapses_effort_suffixes_to_base_models_test() {
  assert catalog.split_id("gemini-3.8-flash-high")
    == #("gemini-3.8-flash", Some("high"))
  assert catalog.split_id("gemini-3.8-flash-medium")
    == #("gemini-3.8-flash", Some("medium"))
  assert catalog.split_id("gemini-3.8-flash-low")
    == #("gemini-3.8-flash", Some("low"))
  assert catalog.split_id("gemini-pro-agent")
    == #("gemini-3.1-pro", Some("high"))
  assert catalog.split_id("gemini-3.1-pro-low")
    == #("gemini-3.1-pro", Some("low"))
  assert catalog.split_id("claude-sonnet-4-6") == #("claude-sonnet-4-6", None)

  let #(root, _, home) = fixture()
  let _ =
    write(
      home,
      "antigravity.json",
      "{\"version\":\"2.17.0\",\"models\":[{\"id\":\"gemini-3.8-flash-high\",\"name\":\"Gemini 3.8 Flash (High)\",\"context\":1048576,\"output\":65536,\"images\":true,\"modelEnum\":\"MODEL_PLACEHOLDER_M318\"},{\"id\":\"gemini-3.8-flash-medium\",\"name\":\"Gemini 3.8 Flash (Medium)\",\"context\":1048576,\"output\":65536,\"images\":true,\"modelEnum\":\"MODEL_PLACEHOLDER_M319\"},{\"id\":\"gemini-3.8-flash-low\",\"name\":\"Gemini 3.8 Flash (Low)\",\"context\":1048576,\"output\":65536,\"images\":true,\"modelEnum\":\"MODEL_PLACEHOLDER_M320\"},{\"id\":\"gemini-pro-agent\",\"name\":\"Gemini 3.1 Pro (High)\",\"context\":1048576,\"output\":65535,\"images\":true,\"modelEnum\":\"MODEL_PLACEHOLDER_M16\"},{\"id\":\"gemini-3.1-pro-low\",\"name\":\"Gemini 3.1 Pro (Low)\",\"context\":1048576,\"output\":65535,\"images\":true,\"modelEnum\":\"MODEL_PLACEHOLDER_M36\"},{\"id\":\"claude-sonnet-4-6\",\"name\":\"Claude Sonnet 4.6\",\"context\":250000,\"output\":64000,\"images\":true}],\"renamed\":{\"gemini-3.1-pro-high\":\"gemini-pro-agent\"}}",
    )

  assert catalog.base_model_ids(home)
    == ["gemini-3.8-flash", "gemini-3.1-pro", "claude-sonnet-4-6"]

  assert catalog.available_efforts(home, "gemini-3.8-flash")
    == ["low", "medium", "high"]
  assert catalog.available_efforts(home, "gemini-3.1-pro") == ["low", "high"]
  assert catalog.available_efforts(home, "claude-sonnet-4-6") == []

  // Resolving variants with effort
  let high_var = catalog.resolve_variant(home, "gemini-3.8-flash", Some("high"))
  assert high_var.id == "gemini-3.8-flash-high"
  assert high_var.model_enum == Some("MODEL_PLACEHOLDER_M318")

  let med_var =
    catalog.resolve_variant(home, "gemini-3.8-flash", Some("medium"))
  assert med_var.id == "gemini-3.8-flash-medium"
  assert med_var.model_enum == Some("MODEL_PLACEHOLDER_M319")

  // Default effort for flash is medium
  let def_var = catalog.resolve_variant(home, "gemini-3.8-flash", None)
  assert def_var.id == "gemini-3.8-flash-medium"

  // Default effort for 3.1 pro (which has only low and high) is high
  let pro_var = catalog.resolve_variant(home, "gemini-3.1-pro", None)
  assert pro_var.id == "gemini-pro-agent"
  assert pro_var.model_enum == Some("MODEL_PLACEHOLDER_M16")

  cleanup(root)
}
