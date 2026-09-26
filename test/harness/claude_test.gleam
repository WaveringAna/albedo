import albedo/daemon/events
import albedo/harness/extensions/claude/extension as claude
import albedo/harness/extensions/claude/stream
import albedo/harness/extensions/claude/wire
import albedo/harness/oauth
import albedo/openai_api
import albedo/openai_api/stream as reducer
import albedo/openai_api/transport
import albedo/openai_api/types
import gleam/bit_array
import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/string_tree.{type StringTree}

// 2x3 PNG header, enough for dimension decoding.
const png = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAAD"

const no_files_home = "/nonexistent"

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
    wire.encode(
      no_files_home,
      "sk-ant-oat-test",
      "11111111-2222-4333-8444-555555555555",
      string.repeat("a", 64),
      "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
      request,
    )
  let assert Ok(betas) = list_key(headers, "anthropic-beta")
  assert string.split(betas, ",")
    == [
      "claude-code-20250219", "oauth-2025-04-20",
      "interleaved-thinking-2025-05-14", "thinking-token-count-2026-05-13",
      "context-management-2025-06-27", "prompt-caching-scope-2026-01-05",
      "mid-conversation-system-2026-04-07", "per-turn-control-2026-07-01",
      "mid-conversation-tool-changes-2026-07-01",
      "extended-cache-ttl-2025-04-11",
    ]
  assert list_key(headers, "user-agent")
    == Ok("claude-cli/2.1.283 (external, cli)")
  assert list_key(headers, "x-stainless-lang") == Ok("js")
  assert list_key(headers, "x-stainless-runtime") == Ok("node")
  assert list_key(headers, "x-stainless-package-version") == Ok("0.112.1")
  assert list_key(headers, "x-stainless-retry-count") == Ok("0")
  assert list_key(headers, "x-stainless-timeout") == Ok("600")
  assert list_key(headers, "x-stainless-arch") == Ok("arm64")
  assert list_key(headers, "x-stainless-os") == Ok("MacOS")
  assert list_key(headers, "x-stainless-runtime-version") == Ok("v26.3.0")
  assert list_key(headers, "x-claude-code-session-id")
    == Ok("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")
  let assert Ok(value) = json.parse(sent(body), decode.dynamic)
  let assert Ok(system) =
    decode.run(
      value,
      decode.at(["system"], decode.list(decode.at(["text"], decode.string))),
    )
  let assert Ok(user_id) =
    decode.run(value, decode.at(["metadata", "user_id"], decode.string))
  let assert Ok(identity_fields) = json.parse(user_id, decode.dynamic)
  let assert Ok("11111111-2222-4333-8444-555555555555") =
    decode.run(identity_fields, decode.at(["account_uuid"], decode.string))
  let assert Ok("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee") =
    decode.run(identity_fields, decode.at(["session_id"], decode.string))
  let assert Ok(device) =
    decode.run(identity_fields, decode.at(["device_id"], decode.string))
  assert device == string.repeat("a", 64)
  let assert Ok(["all"]) =
    decode.run(
      value,
      decode.at(
        ["context_management", "edits"],
        decode.list(decode.at(["keep"], decode.string)),
      ),
    )
  let assert Ok(ttls) =
    decode.run(
      value,
      decode.at(
        ["system"],
        decode.list(
          decode.one_of(decode.at(["cache_control", "ttl"], decode.string), or: [
            decode.success("none"),
          ]),
        ),
      ),
    )
  assert ttls == ["none", "none", "1h"]
  let assert [billing, identity, local] = system
  assert identity == "You are Claude Code, Anthropic's official CLI for Claude."
  assert local == "local instructions"
  assert string.starts_with(
    billing,
    "x-anthropic-billing-header: cc_version=2.1.283.79f; cc_entrypoint=cli; cch=",
  )
  let assert [_, hash_with_end] = string.split(billing, "cch=")
  let assert [hash, ""] = string.split(hash_with_end, ";")
  let unsigned = string.replace(sent(body), "cch=" <> hash, "cch=00000")
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
    wire.encode(
      no_files_home,
      "token",
      "11111111-2222-4333-8444-555555555555",
      string.repeat("a", 64),
      "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
      request,
    )
  let assert Ok(value) = json.parse(sent(body), decode.dynamic)
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
  let assert Ok(openai_api.Exchange(headers: headers, body: body, ..)) =
    wire.encode(
      no_files_home,
      "token",
      "11111111-2222-4333-8444-555555555555",
      string.repeat("a", 64),
      "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
      request,
    )
  let assert Ok(betas) = list_key(headers, "anthropic-beta")
  assert string.contains(betas, "effort-2025-11-24")
  let assert Ok(value) = json.parse(sent(body), decode.dynamic)
  let assert Ok("adaptive") =
    decode.run(value, decode.at(["thinking", "type"], decode.string))
  let assert Ok("summarized") =
    decode.run(value, decode.at(["thinking", "display"], decode.string))
  let assert Ok("max") =
    decode.run(value, decode.at(["output_config", "effort"], decode.string))
}

pub fn claude_stream_preserves_tool_calls_and_replay_test() {
  let chunks = [
    "{\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"usage\":{\"input_tokens\":12,\"output_tokens\":0,\"cache_read_input_tokens\":200,\"cache_creation_input_tokens\":14}}}",
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
  assert usage.input_tokens == 226
  assert usage.output_tokens == 7
  assert usage.cached_input_tokens == Some(200)
  assert usage.cache_creation_tokens == Some(14)
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
    wire.encode(
      no_files_home,
      "token",
      "11111111-2222-4333-8444-555555555555",
      string.repeat("a", 64),
      "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
      request,
    )
  let assert Ok(value) = json.parse(sent(body), decode.dynamic)
  let assert Ok(names) =
    decode.run(
      value,
      decode.at(["messages"], decode.list(decode.at(["role"], decode.string))),
    )
  assert names == ["user", "assistant", "user"]
  let encoded = sent(body)
  assert string.contains(encoded, "tool_result")
  assert string.contains(encoded, "tool_use")
  assert string.contains(encoded, "hello")
}

pub fn claude_stream_shows_thinking_and_replays_it_signed_test() {
  let chunks = [
    "{\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"usage\":{\"input_tokens\":3,\"output_tokens\":0}}}",
    "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\"}}",
    "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"weighing \"}}",
    "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"options\"}}",
    "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"signature_delta\",\"signature\":\"sig_1\"}}",
    "{\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}",
    "{\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"text_delta\",\"text\":\"done\"}}",
    "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}",
    "{\"type\":\"message_stop\"}",
  ]
  let #(deltas, turn) =
    feed_thinking(stream.reducer("claude-opus-5-5", []), chunks, [])
  assert deltas == ["weighing ", "options"]
  let item = list_first(turn.output)
  assert events.thinking_text(item) == "weighing options"
  let request =
    types.Request(
      "claude-opus-5-5",
      None,
      [types.User("start"), types.Replay(item), types.User("next")],
      [],
      None,
      types.defaults,
    )
  let assert Ok(openai_api.Exchange(body: body, ..)) =
    wire.encode(
      no_files_home,
      "token",
      "11111111-2222-4333-8444-555555555555",
      string.repeat("a", 64),
      "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
      request,
    )
  let assert Ok(value) = json.parse(sent(body), decode.dynamic)
  let block = fn(name) {
    decode.at(
      ["messages"],
      decode.list(decode.at(
        ["content"],
        decode.list(decode.optional_field(
          name,
          "",
          decode.string,
          decode.success,
        )),
      )),
    )
  }
  let assert Ok([_, [thinking, _], _]) = decode.run(value, block("thinking"))
  assert thinking == "weighing options"
  let assert Ok([_, [signature, _], _]) = decode.run(value, block("signature"))
  assert signature == "sig_1"
}

/// Feeds every chunk and keeps the thinking deltas the stream emitted.
fn feed_thinking(
  reducer: reducer.Reducer,
  chunks: List(String),
  deltas: List(String),
) -> #(List(String), types.Turn) {
  let assert [chunk, ..rest] = chunks
  let assert Ok(#(next, emitted, turn)) = reducer.feed(chunk)
  let deltas =
    list.fold(emitted, deltas, fn(deltas, event) {
      case event {
        types.ThinkingDelta(text) -> [text, ..deltas]
        _ -> deltas
      }
    })
  case turn {
    Some(turn) -> #(list.reverse(deltas), turn)
    None -> feed_thinking(next, rest, deltas)
  }
}

pub fn claude_mcp_tools_use_subscription_namespace_and_round_trip_test() {
  let name = "mcp_web_extract_web_search_9cdda7e075"
  let alias = "mcp__albedo__web_extract_web_search_9_be5f1c469f2fb0ae"
  assert wire.claude_name(name) == alias
  let long = "mcp_" <> string.repeat("a", 49) <> "_0123456789"
  assert string.length(wire.claude_name(long)) <= 64
  assert wire.claude_name(long) != wire.claude_name(long <> "b")
  let tool =
    types.Tool(
      name,
      "Search",
      json.object([#("type", json.string("object"))]),
      False,
    )
  let request =
    types.Request(
      "claude-opus-5-5",
      None,
      [types.User("search")],
      [tool],
      None,
      types.defaults,
    )
  let assert Ok(openai_api.Exchange(body: body, ..)) =
    wire.encode(
      no_files_home,
      "token",
      "11111111-2222-4333-8444-555555555555",
      string.repeat("a", 64),
      "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
      request,
    )
  let assert Ok(value) = json.parse(sent(body), decode.dynamic)
  let assert Ok([declared]) =
    decode.run(
      value,
      decode.at(["tools"], decode.list(decode.at(["name"], decode.string))),
    )
  assert declared == alias
  let chunks = [
    "{\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"usage\":{\"input_tokens\":12,\"output_tokens\":0,\"cache_read_input_tokens\":200,\"cache_creation_input_tokens\":14}}}",
    "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tool_1\",\"name\":\""
      <> alias
      <> "\",\"input\":{}}}",
    "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"}}",
    "{\"type\":\"message_stop\"}",
  ]
  let assert Ok(turn) =
    feed_all(stream.reducer("claude-opus-5-5", [tool]), chunks)
  let assert [call] = turn.tool_calls
  assert call.name == name
  let replay =
    types.Request(
      "claude-opus-5-5",
      None,
      [
        types.User("search"),
        types.Replay(list_first(turn.output)),
        types.ToolOutput("tool_1", "ok", []),
      ],
      [tool],
      None,
      types.defaults,
    )
  let assert Ok(openai_api.Exchange(body: replay_body, ..)) =
    wire.encode(
      no_files_home,
      "token",
      "11111111-2222-4333-8444-555555555555",
      string.repeat("a", 64),
      "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
      replay,
    )
  let assert Ok(replayed) = json.parse(sent(replay_body), decode.dynamic)
  let assert Ok(names) =
    decode.run(
      replayed,
      decode.at(
        ["messages"],
        decode.list(decode.at(
          ["content"],
          decode.list(
            decode.one_of(decode.at(["name"], decode.string), or: [
              decode.success(""),
            ]),
          ),
        )),
      ),
    )
  assert list.any(names, fn(items) { list.contains(items, alias) })
}

pub fn claude_cache_breakpoints_anchor_head_and_tail_test() {
  let tool = types.Tool("Bash", "Run command", json.object([]), False)
  let request =
    types.Request(
      "claude-opus-5-5",
      Some("local instructions"),
      [types.User("start"), types.Assistant("hi"), types.User("finish")],
      [tool, types.Tool("Read", "Read file", json.object([]), False)],
      None,
      types.defaults,
    )
  let assert Ok(openai_api.Exchange(body: body, ..)) =
    wire.encode(
      no_files_home,
      "token",
      "11111111-2222-4333-8444-555555555555",
      string.repeat("a", 64),
      "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
      request,
    )
  let text = sent(body)
  let count =
    text
    |> string.split("cache_control")
    |> list.length
  assert count == 4
  assert string.contains(text, "\"ttl\":\"1h\"")
  let assert Ok(value) = json.parse(text, decode.dynamic)
  let assert Ok(tool_ttls) =
    decode.run(
      value,
      decode.at(
        ["tools"],
        decode.list(
          decode.one_of(decode.at(["cache_control", "ttl"], decode.string), or: [
            decode.success(""),
          ]),
        ),
      ),
    )
  assert tool_ttls == ["", "1h"]
  let assert Ok(blocks) =
    decode.run(
      value,
      decode.at(
        ["messages"],
        decode.list(decode.at(
          ["content"],
          decode.list(
            decode.one_of(
              decode.at(["cache_control", "type"], decode.string),
              or: [decode.success("")],
            ),
          ),
        )),
      ),
    )
  assert blocks == [[""], [""], ["ephemeral"]]
}

pub fn claude_stored_image_is_read_and_the_signed_body_carries_it_test() {
  let image =
    stored_image(
      "image/png",
      string.repeat("ab", 32),
      string.byte_size(png),
      fn() { Ok(png) },
      2,
      3,
      24,
    )
  let request =
    types.Request(
      "claude-opus-5-5",
      None,
      [types.UserImage("what is this", image)],
      [],
      None,
      types.defaults,
    )
  let assert Ok(openai_api.Exchange(body: body, ..)) =
    wire.encode(
      no_files_home,
      "token",
      "11111111-2222-4333-8444-555555555555",
      string.repeat("a", 64),
      "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
      request,
    )
  let assert Ok(value) = json.parse(sent(body), decode.dynamic)
  let assert Ok([data]) =
    decode.run(
      value,
      decode.at(
        ["messages"],
        decode.list(decode.at(
          ["content"],
          decode.list(
            decode.one_of(decode.at(["source", "data"], decode.string), or: [
              decode.success(""),
            ]),
          ),
        )),
      ),
    )
  assert data == ["", png]
  let assert Ok([billing, _]) =
    decode.run(
      value,
      decode.at(["system"], decode.list(decode.at(["text"], decode.string))),
    )
  let assert [_, hash_with_end] = string.split(billing, "cch=")
  let assert [hash, ""] = string.split(hash_with_end, ";")
  let unsigned = string.replace(sent(body), "cch=" <> hash, "cch=00000")
  assert hash == billing_hash(unsigned)
}

pub fn claude_damaged_stored_image_fails_when_the_body_is_written_test() {
  let image =
    stored_image(
      "image/png",
      string.repeat("ab", 32),
      string.byte_size(png),
      fn() { Error(Nil) },
      2,
      3,
      24,
    )
  let request =
    types.Request(
      "claude-opus-5-5",
      None,
      [types.UserImage("what is this", image)],
      [],
      None,
      types.defaults,
    )
  let assert Ok(openai_api.Exchange(body: body, ..)) =
    wire.encode(
      no_files_home,
      "token",
      "11111111-2222-4333-8444-555555555555",
      string.repeat("a", 64),
      "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
      request,
    )
  let assert Error("a stored image payload is missing or damaged") =
    materialize(body)
}

pub fn claude_billing_hash_agrees_across_chunk_boundaries_test() {
  let body =
    string.repeat(
      "{\"messages\":[{\"role\":\"user\",\"content\":\"hello cch=00000\"}],",
      37,
    )
  assert billing_hash(body) == billing_hash_streamed([body])
  assert billing_hash(body) == billing_hash_streamed(split_every(body, 1))
  assert billing_hash(body) == billing_hash_streamed(split_every(body, 7))
  assert billing_hash(body) == billing_hash_streamed(split_every(body, 13))
  assert billing_hash(body) == billing_hash_streamed(split_every(body, 31))
  assert billing_hash(body) == billing_hash_streamed(split_every(body, 32))
  assert billing_hash(body) == billing_hash_streamed(split_every(body, 33))
  assert billing_hash(body)
    == billing_hash_streamed([
      string.slice(body, 0, 31),
      string.drop_start(body, 31),
    ])
  assert billing_hash(body)
    == billing_hash_streamed([
      string.slice(body, 0, 32),
      string.drop_start(body, 32),
    ])
}

fn split_every(text: String, size: Int) -> List(String) {
  case string.byte_size(text) <= size {
    True -> [text]
    False -> [
      string.slice(text, 0, size),
      ..split_every(string.drop_start(text, size), size)
    ]
  }
}

type Fixture

type ServerMode {
  Stream
}

@external(erlang, "albedo_openai_transport_test_server", "start")
fn start(mode: ServerMode) -> Fixture

@external(erlang, "albedo_openai_transport_test_server", "url")
fn url(fixture: Fixture) -> String

@external(erlang, "albedo_openai_transport_test_server", "await_body")
fn await_body(fixture: Fixture) -> BitArray

@external(erlang, "albedo_openai_transport_test_server", "stop")
fn stop(fixture: Fixture) -> Nil

pub fn claude_attested_body_streams_through_the_transport_test() {
  let fixture = start(Stream)
  let image =
    stored_image(
      "image/png",
      string.repeat("ab", 32),
      string.byte_size(png),
      fn() { Ok(png) },
      2,
      3,
      24,
    )
  let request =
    types.Request(
      "claude-opus-5-5",
      None,
      [types.UserImage("what is this", image)],
      [],
      None,
      types.defaults,
    )
  let assert Ok(openai_api.Exchange(body: body, ..)) =
    wire.encode(
      no_files_home,
      "token",
      "11111111-2222-4333-8444-555555555555",
      string.repeat("a", 64),
      "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
      request,
    )
  let assert Ok(connection) = transport.open(url(fixture), [], body, 2000)
  let received = await_body(fixture)
  transport.close(connection)
  stop(fixture)
  let assert Ok(on_the_wire) = bit_array.to_string(received)
  let assert Ok(materialized) = materialize(body)
  assert on_the_wire == materialized
  assert string.contains(on_the_wire, png)
  let assert Ok(value) = json.parse(on_the_wire, decode.dynamic)
  let assert Ok([billing, _]) =
    decode.run(
      value,
      decode.at(["system"], decode.list(decode.at(["text"], decode.string))),
    )
  let assert [_, hash_with_end] = string.split(billing, "cch=")
  let assert [hash, ""] = string.split(hash_with_end, ";")
  let unsigned = string.replace(on_the_wire, "cch=" <> hash, "cch=00000")
  assert hash == billing_hash(unsigned)
}

fn image_request(image: types.Image) -> types.Request {
  types.Request(
    "claude-opus-5-5",
    None,
    [types.UserImage("what is this", image)],
    [],
    None,
    types.defaults,
  )
}

type FilesFixture

@external(erlang, "albedo_claude_files_test_server", "start")
fn files_start() -> FilesFixture

@external(erlang, "albedo_claude_files_test_server", "url")
fn files_url(fixture: FilesFixture) -> String

@external(erlang, "albedo_claude_files_test_server", "captured")
fn files_captured(fixture: FilesFixture) -> Result(#(String, BitArray), Nil)

@external(erlang, "albedo_claude_files_test_server", "stop")
fn files_stop(fixture: FilesFixture) -> Nil

@external(erlang, "albedo_claude_files", "ensure")
fn ensure_files(
  home: String,
  access: String,
  account: String,
  endpoint: String,
  request: types.Request,
) -> Nil

@external(erlang, "albedo_claude_files", "reject")
fn reject_files(home: String, account: String, body: String) -> Nil

@external(erlang, "albedo_claude_test_support", "bytes_contain")
fn bytes_contain(haystack: BitArray, needle: BitArray) -> Bool

pub fn claude_images_upload_once_and_are_referenced_by_file_id_test() {
  let #(root, _, home) = fixture()
  let server = files_start()
  let image =
    stored_image(
      "image/png",
      string.repeat("ab", 32),
      string.byte_size(png),
      fn() { Ok(png) },
      2,
      3,
      24,
    )
  let request = image_request(image)
  ensure_files(home, "token", "acct-upload", files_url(server), request)
  let assert Ok(#(head, body)) = files_captured(server)
  files_stop(server)
  let lower = string.lowercase(head)
  assert string.contains(lower, "authorization: bearer token")
  assert string.contains(lower, "anthropic-beta: files-api-2025-04-14")
  assert string.contains(lower, "anthropic-version: 2023-06-01")
  assert string.contains(lower, "multipart/form-data")
  let assert Ok(decoded) = bit_array.base64_decode(png)
  assert bytes_contain(body, decoded)
  ensure_files(home, "token", "acct-upload", "http://127.0.0.1:9", request)
  let assert Ok(openai_api.Exchange(body: wire_body, ..)) =
    wire.encode(
      home,
      "token",
      "acct-upload",
      string.repeat("a", 64),
      "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
      request,
    )
  let text = sent(wire_body)
  assert string.contains(
    text,
    "\"type\":\"file\",\"file_id\":\"file-test-123\"",
  )
  assert !string.contains(text, png)
  let assert Ok(value) = json.parse(text, decode.dynamic)
  let assert Ok([kinds]) =
    decode.run(
      value,
      decode.at(
        ["messages"],
        decode.list(decode.at(
          ["content"],
          decode.list(
            decode.one_of(decode.at(["source", "type"], decode.string), or: [
              decode.success(""),
            ]),
          ),
        )),
      ),
    )
  assert kinds == ["", "file"]
  cleanup(root)
}

pub fn claude_file_handles_are_account_scoped_and_rejected_test() {
  let #(root, _, home) = fixture()
  let _ =
    write(
      home,
      "claude-files.json",
      "{\"acct-mine\":{\""
        <> string.repeat("ab", 32)
        <> "\":{\"id\":\"file-mine\",\"bytes\":24}}}",
    )
  let image =
    stored_image(
      "image/png",
      string.repeat("ab", 32),
      string.byte_size(png),
      fn() { Ok(png) },
      2,
      3,
      24,
    )
  let request = image_request(image)
  let assert Ok(mine) =
    wire.encode(
      home,
      "token",
      "acct-mine",
      string.repeat("a", 64),
      "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
      request,
    )
  assert string.contains(sent(mine.body), "file-mine")
  let assert Ok(other) =
    wire.encode(
      home,
      "token",
      "acct-other",
      string.repeat("a", 64),
      "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
      request,
    )
  assert string.contains(sent(other.body), png)
  reject_files(
    home,
    "acct-mine",
    "{\"error\":{\"message\":\"file_id not found\"}}",
  )
  // A live server stands by: only the process-local quarantine can explain
  // it seeing no upload and the wire staying inline.
  let server = files_start()
  ensure_files(home, "token", "acct-mine", files_url(server), request)
  let assert Error(Nil) = files_captured(server)
  files_stop(server)
  let assert Ok(healed) =
    wire.encode(
      home,
      "token",
      "acct-mine",
      string.repeat("a", 64),
      "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
      request,
    )
  assert string.contains(sent(healed.body), png)
  cleanup(root)
}

/// Frame-style images carry no text block; consecutive user images merge.
pub fn claude_empty_text_image_emits_no_text_block_test() {
  let image =
    stored_image(
      "image/png",
      string.repeat("ab", 32),
      string.byte_size(png),
      fn() { Ok(png) },
      2,
      3,
      24,
    )
  let request =
    types.Request(
      "claude-opus-5-5",
      None,
      [types.UserImage("", image), types.UserImage("", image)],
      [],
      None,
      types.defaults,
    )
  let assert Ok(exchange) =
    wire.encode(
      no_files_home,
      "token",
      "11111111-2222-4333-8444-555555555555",
      string.repeat("a", 64),
      "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
      request,
    )
  let body = sent(exchange.body)
  assert string.contains(body, "\"text\":\"\"") == False
  // Two images in one user message: no empty text blocks between them.
  assert list.length(string.split(body, "\"type\":\"image\"")) == 3
}

/// An astral first-user message lands a lone surrogate on the sampled utf16
/// unit: the sample falls back to the absent-character default instead of
/// crashing the turn before it reaches the wire.
pub fn claude_first_user_surrogates_do_not_crash_the_billing_sample_test() {
  let request =
    types.Request(
      "claude-opus-5-5",
      None,
      [types.User("abcd🚀 let's look at 🌟 and 🎉 together")],
      [],
      None,
      types.defaults,
    )
  let assert Ok(exchange) =
    wire.encode(
      no_files_home,
      "token",
      "11111111-2222-4333-8444-555555555555",
      string.repeat("a", 64),
      "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
      request,
    )
  let text = sent(exchange.body)
  let assert Ok(value) = json.parse(text, decode.dynamic)
  let assert Ok([billing, _]) =
    decode.run(
      value,
      decode.at(["system"], decode.list(decode.at(["text"], decode.string))),
    )
  let assert [_, hash_with_end] = string.split(billing, "cch=")
  let assert [hash, ""] = string.split(hash_with_end, ";")
  let unsigned = string.replace(text, "cch=" <> hash, "cch=00000")
  assert hash == billing_hash(unsigned)
}

/// Without instructions the identity block carries the system breakpoint.
pub fn claude_system_breakpoint_without_instructions_test() {
  let request =
    types.Request(
      "claude-opus-5-5",
      None,
      [types.User("hi")],
      [],
      None,
      types.defaults,
    )
  let assert Ok(exchange) =
    wire.encode(
      no_files_home,
      "token",
      "11111111-2222-4333-8444-555555555555",
      string.repeat("a", 64),
      "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
      request,
    )
  let assert Ok(value) = json.parse(sent(exchange.body), decode.dynamic)
  let assert Ok(ttls) =
    decode.run(
      value,
      decode.at(
        ["system"],
        decode.list(
          decode.one_of(decode.at(["cache_control", "ttl"], decode.string), or: [
            decode.success("none"),
          ]),
        ),
      ),
    )
  assert ttls == ["none", "1h"]
}

pub fn claude_expired_file_handles_fall_back_inline_test() {
  let #(root, _, home) = fixture()
  let _ =
    write(
      home,
      "claude-files.json",
      "{\"acct-old\":{\""
        <> string.repeat("ab", 32)
        <> "\":{\"id\":\"file-old\",\"bytes\":24,\"expires_at\":1000}}}",
    )
  let image =
    stored_image(
      "image/png",
      string.repeat("ab", 32),
      string.byte_size(png),
      fn() { Ok(png) },
      2,
      3,
      24,
    )
  let assert Ok(exchange) =
    wire.encode(
      home,
      "token",
      "acct-old",
      string.repeat("a", 64),
      "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
      image_request(image),
    )
  let text = sent(exchange.body)
  assert string.contains(text, png)
  assert !string.contains(text, "file-old")
  cleanup(root)
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
  assert billing_hash("") == "b46c5"
  assert billing_hash(string.repeat("a", 31)) == "ef013"
  assert billing_hash(string.repeat("a", 32)) == "86567"
  assert billing_hash(string.repeat("a", 33)) == "5bea8"
  assert billing_hash(string.repeat("b", 63)) == "9f9d8"
  assert billing_hash(string.repeat("c", 64)) == "2742b"
  assert billing_hash(string.repeat("d", 65)) == "92299"
  assert billing_hash(string.repeat("0123456789", 100)) == "827e8"
}

@external(erlang, "albedo_claude_billing", "hash")
fn billing_hash(body: String) -> String

@external(erlang, "albedo_claude_billing", "hash_streamed")
fn billing_hash_streamed(chunks: List(String)) -> String

@external(erlang, "albedo_openai_transport", "materialize")
fn materialize(body: StringTree) -> Result(String, String)

fn sent(body: StringTree) -> String {
  let assert Ok(text) = materialize(body)
  text
}

@external(erlang, "albedo_claude_auth", "access")
fn access(home: String, session: String) -> Result(String, String)

@external(erlang, "albedo_claude_test_support", "stored_image")
fn stored_image(
  mime: String,
  hash: String,
  size: Int,
  read: fn() -> Result(String, Nil),
  width: Int,
  height: Int,
  bytes: Int,
) -> types.Image

@external(erlang, "albedo_skills_test_support", "fixture")
fn fixture() -> #(String, String, String)

@external(erlang, "albedo_skills_test_support", "write")
fn write(home: String, relative: String, content: String) -> String

@external(erlang, "albedo_skills_test_support", "cleanup")
fn cleanup(root: String) -> Nil
