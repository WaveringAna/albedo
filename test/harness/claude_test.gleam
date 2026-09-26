import albedo/harness/extensions/claude/extension as claude
import albedo/harness/extensions/claude/stream
import albedo/harness/extensions/claude/wire
import albedo/harness/oauth
import albedo/openai_api
import albedo/openai_api/stream as reducer
import albedo/openai_api/types
import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/string_tree

pub fn claude_login_uses_claude_code_pkce_and_fixed_callback_test() {
  let login = claude.login()
  assert login.provider == "claude"
  assert login.protocol == types.ChatCompletions
  assert login.callback
    == oauth.Callback("localhost", 53_692, "/callback", True)
  let url =
    login.authorize(oauth.Grant(
      "http://localhost:53692/callback",
      "state",
      "verifier",
      "challenge",
    ))
  assert string.contains(url, "client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e")
  assert string.contains(url, "code_challenge=challenge")
  assert string.contains(url, "code_challenge_method=S256")
  assert string.contains(url, "state=state")
}

pub fn claude_catalog_reads_current_and_fallback_models_from_models_dev_test() {
  let #(root, _, home) = fixture()
  let file =
    write(
      home,
      "models.json",
      "{\"anthropic\":{\"models\":{\"claude-opus-5-5\":{\"id\":\"claude-opus-5-5\",\"limit\":{\"context\":1000000,\"output\":128000},\"modalities\":{\"input\":[\"text\",\"image\",\"pdf\"]},\"reasoning_options\":[{\"type\":\"effort\",\"values\":[\"low\",\"medium\",\"high\",\"max\"]}]},\"claude-fable-5-1\":{\"id\":\"claude-fable-5-1\"},\"claude-sonnet-5\":{\"id\":\"claude-sonnet-5\"},\"claude-opus-5\":{\"id\":\"claude-opus-5\"},\"claude-opus-4-8\":{\"id\":\"claude-opus-4-8\"},\"claude-haiku-4-5\":{\"id\":\"claude-haiku-4-5\"},\"claude-sonnet-4-6\":{\"id\":\"claude-sonnet-4-6\"}}},\"mirror\":{\"models\":{\"claude-opus-5-5\":{\"id\":\"claude-opus-5-5\",\"limit\":{\"context\":4000}}}}}",
    )
  assert claude.available_models(file)
    == [
      "claude-opus-5-5", "claude-fable-5-1", "claude-sonnet-5", "claude-opus-5",
      "claude-opus-4-8", "claude-haiku-4-5",
    ]
  assert claude.model_at(file, "claude-sonnet-4-6", claude.endpoint) == None
  assert claude.model_at(file, "claude-opus-5-5", "https://example.com") == None
  let assert Some(info) =
    claude.model_at(file, "claude-opus-5-5", claude.endpoint)
  assert info.provider == "claude"
  assert info.context_tokens == Some(1_000_000)
  assert info.max_output_tokens == Some(128_000)
  assert info.input_modalities == ["text", "image"]
  assert info.efforts == ["low", "medium", "high", "max"]
  assert info.environment == []
  cleanup(root)
}

pub fn claude_saved_account_is_listed_and_accessed_without_network_test() {
  let #(root, _, home) = fixture()
  let _ =
    write(
      home,
      "auth.json",
      "{\"anthropic\":{\"type\":\"oauth\",\"access\":\"sk-ant-oat-test\",\"refresh\":\"private-refresh\",\"accountId\":\"stable-account\",\"expires\":9999999999999}}",
    )
  let assert [account] = oauth.accounts(home, claude.login())
  assert account.id == "stable-account"
  let assert Ok("sk-ant-oat-test") = access(home, "session")
  cleanup(root)
}

pub fn claude_messages_request_carries_client_identity_and_tools_test() {
  let request =
    types.Request(
      "claude-opus-5-5",
      Some("local instructions"),
      [types.User("hello")],
      [types.Tool("Bash", "Run command", json.object([]), False)],
      None,
      types.defaults,
    )
  let assert Ok(openai_api.Exchange(headers: headers, body: body, ..)) =
    wire.encode("sk-ant-oat-test", request)
  assert list_key(headers, "anthropic-beta")
    == Ok("claude-code-20250219,oauth-2025-04-20")
  assert list_key(headers, "user-agent") == Ok("claude-cli/2.1.283")
  let assert Ok(value) = json.parse(string_tree.to_string(body), decode.dynamic)
  let assert Ok(system) =
    decode.run(
      value,
      decode.at(["system"], decode.list(decode.at(["text"], decode.string))),
    )
  let assert [billing, identity, local] = system
  assert identity == "You are Claude Code, Anthropic's official CLI for Claude."
  assert local == "local instructions"
  assert string.starts_with(
    billing,
    "x-anthropic-billing-header: cc_version=2.1.283.79f; cc_entrypoint=cli; cch=",
  )
  let assert [_, hash_with_end] = string.split(billing, "cch=")
  let assert [hash, ""] = string.split(hash_with_end, ";")
  let unsigned =
    string.replace(string_tree.to_string(body), "cch=" <> hash, "cch=00000")
  assert hash == billing_hash(unsigned)
  let assert Ok(name) =
    decode.run(
      value,
      decode.at(["tools"], decode.list(decode.at(["name"], decode.string))),
    )
  assert name == ["Bash"]
}

fn list_key(
  pairs: List(#(String, String)),
  key: String,
) -> Result(String, Nil) {
  list.key_find(pairs, key)
}

pub fn claude_tool_schemas_flatten_only_top_level_combiners_test() {
  let assert Ok(schema) =
    json.parse(
      "{\"type\":\"object\",\"properties\":{\"urls\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}},\"ids\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}}},\"oneOf\":[{\"required\":[\"urls\"]},{\"required\":[\"ids\"]}],\"allOf\":[{\"required\":[\"mode\"],\"properties\":{\"mode\":{\"oneOf\":[{\"type\":\"string\"},{\"type\":\"integer\"}]}}}]}",
      decode.dynamic,
    )
  let request =
    types.Request(
      "claude-opus-5-5",
      None,
      [types.User("hi")],
      [
        types.Tool(
          "contents",
          "Fetch URLs or IDs",
          wire.encode_value(schema),
          False,
        ),
      ],
      None,
      types.defaults,
    )
  let assert Ok(openai_api.Exchange(body: body, ..)) =
    wire.encode("token", request)
  let assert Ok(value) = json.parse(string_tree.to_string(body), decode.dynamic)
  let assert Ok([tool]) =
    decode.run(value, decode.at(["tools"], decode.list(decode.dynamic)))
  let assert Ok("object") =
    decode.run(tool, decode.at(["input_schema", "type"], decode.string))
  let assert Ok(props) =
    decode.run(
      tool,
      decode.at(
        ["input_schema", "properties"],
        decode.dict(decode.string, decode.dynamic),
      ),
    )
  assert list.length(dict.to_list(props)) == 3
  let assert Ok(["mode"]) =
    decode.run(
      tool,
      decode.at(["input_schema", "required"], decode.list(decode.string)),
    )
  let assert Ok(hint) =
    decode.run(tool, decode.at(["input_schema", "description"], decode.string))
  assert string.contains(hint, "urls or ids")
  let assert Ok([_, _]) =
    decode.run(
      tool,
      decode.at(
        ["input_schema", "properties", "mode", "oneOf"],
        decode.list(decode.dynamic),
      ),
    )
  let assert Error(_) =
    decode.run(tool, decode.at(["input_schema", "oneOf"], decode.dynamic))
  let assert Error(_) =
    decode.run(tool, decode.at(["input_schema", "allOf"], decode.dynamic))
}

pub fn claude_tool_schema_accepts_branch_only_root_union_test() {
  let assert Ok(schema) =
    json.parse(
      "{\"oneOf\":[{\"type\":\"object\",\"properties\":{\"urls\":{\"type\":\"array\"}},\"required\":[\"urls\"]},{\"type\":\"object\",\"properties\":{\"ids\":{\"type\":\"array\"}},\"required\":[\"ids\"]}]}",
      decode.dynamic,
    )
  let normalized = wire.normalize_schema(wire.encode_value(schema))
  let assert Ok(value) = json.parse(json.to_string(normalized), decode.dynamic)
  let assert Ok(props) =
    decode.run(
      value,
      decode.at(["properties"], decode.dict(decode.string, decode.dynamic)),
    )
  assert list.length(dict.to_list(props)) == 2
  let assert Ok("object") =
    decode.run(value, decode.at(["type"], decode.string))
  let assert Ok(hint) =
    decode.run(value, decode.at(["description"], decode.string))
  assert string.contains(hint, "urls or ids")
}

pub fn current_claude_effort_uses_adaptive_thinking_test() {
  let options = types.Options(..types.defaults, effort: Some("max"))
  let request =
    types.Request(
      "claude-opus-5-5",
      None,
      [types.User("hello")],
      [],
      None,
      options,
    )
  let assert Ok(openai_api.Exchange(body: body, ..)) =
    wire.encode("token", request)
  let assert Ok(value) = json.parse(string_tree.to_string(body), decode.dynamic)
  let assert Ok("adaptive") =
    decode.run(value, decode.at(["thinking", "type"], decode.string))
  let assert Ok("max") =
    decode.run(value, decode.at(["output_config", "effort"], decode.string))
}

pub fn claude_stream_preserves_tool_calls_and_replay_test() {
  let chunks = [
    "{\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"usage\":{\"input_tokens\":12,\"output_tokens\":0}}}",
    "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}",
    "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"hello\"}}",
    "{\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tool_1\",\"name\":\"Bash\",\"input\":{}}}",
    "{\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"command\\\":\\\"pwd\\\"}\"}}",
    "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":7}}",
    "{\"type\":\"message_stop\"}",
  ]
  let reducer =
    stream.reducer("claude-opus-5-5", [
      types.Tool("bash", "run", json.object([]), False),
    ])
  let assert Ok(turn) = feed_all(reducer, chunks)
  let assert [call] = turn.tool_calls
  assert call.name == "bash"
  assert call.arguments == "{\"command\":\"pwd\"}"
  assert turn.finish == types.ToolCalls
  let assert Some(usage) = turn.usage
  assert usage.input_tokens == 12
  assert usage.output_tokens == 7
  let request =
    types.Request(
      "claude-opus-5-5",
      None,
      [
        types.User("start"),
        types.Replay(list_first(turn.output)),
        types.ToolOutput("tool_1", "ok", []),
      ],
      [],
      None,
      types.defaults,
    )
  let assert Ok(openai_api.Exchange(body: body, ..)) =
    wire.encode("token", request)
  let assert Ok(value) = json.parse(string_tree.to_string(body), decode.dynamic)
  let assert Ok(names) =
    decode.run(
      value,
      decode.at(["messages"], decode.list(decode.at(["role"], decode.string))),
    )
  assert names == ["user", "assistant", "user"]
  let encoded = string_tree.to_string(body)
  assert string.contains(encoded, "tool_result")
  assert string.contains(encoded, "tool_use")
  assert string.contains(encoded, "hello")
}

fn feed_all(
  reducer: reducer.Reducer,
  chunks: List(String),
) -> Result(types.Turn, types.Error) {
  case chunks {
    [] -> Error(types.UnexpectedEnd)
    [chunk, ..rest] -> {
      use #(next, _, turn) <- result.try(reducer.feed(chunk))
      case turn {
        Some(turn) -> Ok(turn)
        None -> feed_all(next, rest)
      }
    }
  }
}

fn list_first(items: List(types.ReplayItem)) -> types.ReplayItem {
  let assert [first, ..] = items
  first
}

pub fn claude_billing_hash_matches_reference_vectors_test() {
  assert billing_hash("cch=00000") == "a47f7"
  assert billing_hash("{\"messages\":[],\"cch=00000\",\"x\":1}") == "3073d"
  assert billing_hash(
      "x-anthropic-billing-header: cc_version=2.1.158; cc_entrypoint=cli; cch=00000;",
    )
    == "f2b0b"
}

@external(erlang, "albedo_claude_billing", "hash")
fn billing_hash(body: String) -> String

@external(erlang, "albedo_claude_auth", "access")
fn access(home: String, session: String) -> Result(String, String)

@external(erlang, "albedo_skills_test_support", "fixture")
fn fixture() -> #(String, String, String)

@external(erlang, "albedo_skills_test_support", "write")
fn write(home: String, relative: String, content: String) -> String

@external(erlang, "albedo_skills_test_support", "cleanup")
fn cleanup(root: String) -> Nil
