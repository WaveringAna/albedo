// Signed Claude SSE replay, schema unions, and billing hashes have edge cases absent from the fake E2E provider.
import albedo/daemon/events
import albedo/harness/extensions/claude/stream
import albedo/harness/extensions/claude/wire
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

pub fn claude_token_encodes_to_a_decodable_binary_test() {
  // OTP's json:encode leaves `colon | value' unflattened, and a number value
  // encodes to a bare binary, so the encoded credential is an improper list
  // that json:decode rejects; token/1 must hand back a flat binary. This
  // crashed the session actor on every token refresh.
  let assert Ok(credential) =
    claude_token(
      "{\"access_token\":\"tok\",\"refresh_token\":\"r\",\"expires_in\":86400}",
    )
  let assert Ok(value) = json.parse(credential, decode.dynamic)
  let assert Ok("oauth") = decode.run(value, decode.at(["type"], decode.string))
  let assert Ok("tok") = decode.run(value, decode.at(["access"], decode.string))
  let assert Ok(expires) = decode.run(value, decode.at(["expires"], decode.int))
  assert expires > 0
  let assert Ok(account) =
    decode.run(value, decode.at(["accountId"], decode.string))
  assert string.byte_size(account) == 16
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

@external(erlang, "albedo_claude_auth", "token")
fn claude_token(response: String) -> Result(String, String)

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
