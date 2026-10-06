// Signed Claude SSE replay, schema unions, billing hashes, and stored-credential enumeration have edge cases absent from the fake E2E provider.
import albedo/daemon/message_content as events
import albedo/daemon/projection
import albedo/daemon/transcript
import albedo/harness/extensions/claude/schema as schemas
import albedo/harness/extensions/claude/stream
import albedo/harness/extensions/claude/wire
import albedo/harness/loop
import albedo/openai_api
import albedo/openai_api/request
import albedo/openai_api/stream as reducer
import albedo/openai_api/transport
import albedo/openai_api/types
import gleam/bit_array
import gleam/dict
import gleam/dynamic.{type Dynamic}
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

const subscription =
  wire.Subscription(
    "token",
    "11111111-2222-4333-8444-555555555555",
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
  )

pub fn claude_tool_schemas_flatten_only_top_level_combiners_test() -> Result(
  Dynamic,
  List(decode.DecodeError),
) {
  let assert Ok(schema) =
    json.parse(
      "{
  \"type\": \"object\",
  \"properties\": {
    \"urls\": {
      \"type\": \"array\",
      \"items\": {
        \"type\": \"string\"
      }
    },
    \"ids\": {
      \"type\": \"array\",
      \"items\": {
        \"type\": \"string\"
      }
    }
  },
  \"oneOf\": [
    {
      \"required\": [
        \"urls\"
      ]
    },
    {
      \"required\": [
        \"ids\"
      ]
    }
  ],
  \"allOf\": [
    {
      \"required\": [
        \"mode\"
      ],
      \"properties\": {
        \"mode\": {
          \"oneOf\": [
            {
              \"type\": \"string\"
            },
            {
              \"type\": \"integer\"
            }
          ]
        }
      }
    }
  ]
}",
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
          types.encode_value(schema),
          False,
        ),
      ],
      None,
      types.defaults,
    )
  let assert Ok(openai_api.Exchange(body: body, ..)) =
    wire.encode(no_files_home, subscription, request)
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

pub fn claude_tool_schema_accepts_branch_only_root_union_test() -> Nil {
  let assert Ok(schema) =
    json.parse(
      "{
  \"oneOf\": [
    {
      \"type\": \"object\",
      \"properties\": {
        \"urls\": {
          \"type\": \"array\"
        }
      },
      \"required\": [
        \"urls\"
      ]
    },
    {
      \"type\": \"object\",
      \"properties\": {
        \"ids\": {
          \"type\": \"array\"
        }
      },
      \"required\": [
        \"ids\"
      ]
    }
  ]
}",
      decode.dynamic,
    )
  let normalized = schemas.normalize(types.encode_value(schema))
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

pub fn claude_schema_preserves_metadata_and_merge_precedence_in_requests_test() -> Nil {
  let assert Ok(schema) =
    json.parse(
      "{
  \"$schema\": \"https://json-schema.org/draft/2020-12/schema\",
  \"$defs\": {
    \"choice\": {
      \"anyOf\": [
        {
          \"type\": \"string\"
        },
        {
          \"type\": \"null\"
        }
      ]
    }
  },
  \"x-metadata\": {
    \"values\": [
      null,
      true,
      2.5,
      {
        \"nested\": [
          \"keep\"
        ]
      }
    ]
  },
  \"additionalProperties\": false,
  \"description\": \"Choose inputs\",
  \"properties\": {
    \"shared\": {
      \"$ref\": \"#/$defs/choice\",
      \"x-custom\": [
        false,
        null
      ]
    }
  },
  \"required\": [
    \"root\",
    \"root\"
  ],
  \"allOf\": [
    {
      \"properties\": {
        \"shared\": {
          \"type\": \"integer\"
        },
        \"mode\": {
          \"oneOf\": [
            {
              \"const\": \"a\"
            },
            {
              \"const\": \"b\"
            }
          ]
        }
      },
      \"required\": [
        \"mode\"
      ]
    }
  ],
  \"oneOf\": [
    {
      \"properties\": {
        \"left\": {
          \"type\": \"string\"
        },
        \"collision\": {
          \"const\": \"first\"
        }
      },
      \"required\": [
        \"common\",
        \"left\"
      ]
    },
    {
      \"properties\": {
        \"right\": {
          \"type\": \"string\"
        },
        \"collision\": {
          \"const\": \"second\"
        }
      },
      \"required\": [
        \"right\",
        \"common\"
      ]
    }
  ],
  \"anyOf\": [
    {
      \"properties\": {
        \"extra\": {
          \"type\": \"boolean\"
        }
      },
      \"required\": [
        \"common\",
        \"extra\"
      ]
    },
    {
      \"properties\": {
        \"other\": false
      },
      \"required\": [
        \"other\",
        \"common\"
      ]
    }
  ]
}",
      decode.dynamic,
    )
  let request =
    types.Request(
      "claude-opus-5-5",
      None,
      [types.User("hi")],
      [types.Tool("inputs", "Choose inputs", types.encode_value(schema), False)],
      None,
      types.defaults,
    )
  let assert Ok(openai_api.Exchange(body: body, ..)) =
    wire.encode(no_files_home, subscription, request)
  let assert Ok(value) = json.parse(sent(body), decode.dynamic)
  let assert Ok([tool]) =
    decode.run(value, decode.at(["tools"], decode.list(decode.dynamic)))
  let assert Ok(actual) =
    decode.run(tool, decode.at(["input_schema"], decode.dynamic))
  let assert Ok(expected) =
    json.parse(
      "{
  \"$schema\": \"https://json-schema.org/draft/2020-12/schema\",
  \"$defs\": {
    \"choice\": {
      \"anyOf\": [
        {
          \"type\": \"string\"
        },
        {
          \"type\": \"null\"
        }
      ]
    }
  },
  \"x-metadata\": {
    \"values\": [
      null,
      true,
      2.5,
      {
        \"nested\": [
          \"keep\"
        ]
      }
    ]
  },
  \"additionalProperties\": false,
  \"description\": \"Choose inputs; Exactly one of: common + left or right + common; At least one of: common + extra or other + common\",
  \"properties\": {
    \"shared\": {
      \"$ref\": \"#/$defs/choice\",
      \"x-custom\": [
        false,
        null
      ]
    },
    \"mode\": {
      \"oneOf\": [
        {
          \"const\": \"a\"
        },
        {
          \"const\": \"b\"
        }
      ]
    },
    \"left\": {
      \"type\": \"string\"
    },
    \"collision\": {
      \"const\": \"first\"
    },
    \"right\": {
      \"type\": \"string\"
    },
    \"extra\": {
      \"type\": \"boolean\"
    },
    \"other\": false
  },
  \"required\": [
    \"common\",
    \"mode\",
    \"root\"
  ],
  \"type\": \"object\"
}",
      decode.dynamic,
    )
  assert actual == expected
}

pub fn claude_stream_preserves_tool_calls_and_replay_test() -> Nil {
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
  assert turn.call_indices == [#("tool_1", 1)]
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
    wire.encode(no_files_home, subscription, request)
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

pub fn claude_refusal_details_and_text_reach_failure_message_test() -> Nil {
  let assert Ok(turn) =
    feed_all(stream.reducer("claude-opus-5-5", []), [
      "{\"type\":\"message_start\",\"message\":{\"id\":\"msg_refusal\"}}",
      "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}",
      "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"I can’t help with that request.\"}}",
      "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"refusal\",\"stop_details\":{\"type\":\"refusal\",\"category\":\"policy\",\"explanation\":\"private credentials\"}}}",
      "{\"type\":\"message_stop\"}",
    ])
  let failure = loop.stopped_message(turn.finish, turn.output)
  assert string.contains(failure, "refusal (policy): private credentials")
  assert string.contains(failure, "I can’t help with that request.")
}

pub fn claude_stream_shows_thinking_and_replays_it_signed_test() -> Nil {
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
    wire.encode(no_files_home, subscription, request)
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

  let entry =
    transcript.Entry(types.Replay(item), None, Some("claude"), None, None)
  let assert Ok([types.Assistant("done"), types.Assistant(summary)]) =
    projection.for_model([entry], "codex", types.Responses)
  assert summary == "[Reasoning summary]\nweighing options"
  let assert Ok(codex_body) =
    request.encode(
      types.Responses,
      types.Request(
        "gpt-5",
        None,
        [types.Assistant(summary)],
        [],
        None,
        types.defaults,
      ),
    )
  assert string.contains(sent(codex_body), "weighing options")

  let changed =
    types.Request(
      "claude-sonnet-4-6",
      None,
      [types.Replay(item)],
      [],
      None,
      types.defaults,
    )
  let assert Ok(openai_api.Exchange(body: switched, ..)) =
    wire.encode(no_files_home, subscription, changed)
  assert string.contains(sent(switched), "[Reasoning summary]")
  assert !string.contains(sent(switched), "sig_1")
}

pub fn codex_reasoning_summary_survives_transfer_to_claude_test() -> Nil {
  let assert Ok(item) =
    json.parse(
      "{\"type\":\"reasoning\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"first\"},{\"type\":\"summary_text\",\"text\":\"second\"}],\"encrypted_content\":\"sealed-reasoning\"}",
      types.replay_decoder(types.Responses),
    )
  let entry =
    transcript.Entry(types.Replay(item), None, Some("codex"), None, None)
  let assert Ok([types.Assistant(summary)]) =
    projection.for_model([entry], "other-codex", types.Responses)
  assert summary == "[Reasoning summary]\nfirst\n\nsecond"
  let assert Ok([types.Replay(projected)]) =
    projection.for_model([entry], "claude", types.ChatCompletions)
  let request =
    types.Request(
      "claude-opus-5-5",
      None,
      [types.Replay(projected)],
      [],
      None,
      types.defaults,
    )
  let assert Ok(openai_api.Exchange(body: body, ..)) =
    wire.encode(no_files_home, subscription, request)
  let sent = sent(body)
  assert string.contains(sent, "[Reasoning summary]")
  assert string.contains(sent, "first")
  assert string.contains(sent, "second")
  assert !string.contains(sent, "sealed-reasoning")
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

pub fn claude_billing_hash_agrees_across_chunk_boundaries_test() -> Nil {
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

pub fn claude_attested_body_streams_through_the_transport_test() -> Nil {
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
      [types.UserImage("what is this", [image])],
      [],
      None,
      types.defaults,
    )
  let assert Ok(openai_api.Exchange(body: body, ..)) =
    wire.encode(no_files_home, subscription, request)
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

pub fn claude_first_user_surrogates_do_not_crash_the_billing_sample_test() -> Nil {
  let request =
    types.Request(
      "claude-opus-5-5",
      None,
      [types.User("abcd🚀 let's look at 🌟 and 🎉 together")],
      [],
      None,
      types.defaults,
    )
  let assert Ok(exchange) = wire.encode(no_files_home, subscription, request)
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

pub fn claude_token_encodes_to_a_decodable_binary_test() -> Nil {
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

pub fn claude_billing_hash_matches_reference_vectors_test() -> Nil {
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

/// The ledger records `wire.cache_marks` as what a Claude request asked to
/// cache; it must name exactly the cache_control markers `encode` sends.
pub fn claude_cache_marks_match_the_encoded_markers_test() -> Nil {
  let requests = [
    types.Request(
      "claude-opus-5-5",
      Some("be brief"),
      [types.User("a"), types.Assistant("b"), types.User("c")],
      [
        types.Tool("read", "read", json.object([]), False),
        types.Tool("bash", "run", json.object([]), False),
      ],
      None,
      types.defaults,
    ),
    types.Request(
      "claude-opus-5-5",
      None,
      [types.User("hi")],
      [],
      None,
      types.defaults,
    ),
  ]
  use request <- list.each(requests)
  use auth <- list.each([subscription, wire.ApiKey("sk-ant-test")])
  {
    let assert Ok(openai_api.Exchange(body: body, ..)) =
      wire.encode(no_files_home, auth, request)
    let assert Ok(value) = json.parse(sent(body), decode.dynamic)
    // A request without tools sends no tools field at all.
    let markers = fn(field) {
      let assert Ok(blocks) =
        decode.run(
          value,
          decode.optional_field(
            field,
            [],
            decode.list(marker_decoder()),
            decode.success,
          ),
        )
      option.values(blocks)
    }
    let assert Ok(messages) =
      decode.run(
        value,
        decode.at(
          ["messages"],
          decode.list(decode.at(["content"], decode.list(marker_decoder()))),
        ),
      )
    let last_message = list.length(messages) - 1
    let input =
      messages
      |> list.index_map(fn(blocks, at) {
        let last_block = list.length(blocks) - 1
        list.index_map(blocks, fn(ttl, block) {
          case ttl, at == last_message && block == last_block {
            Some(ttl), True -> [
              #(types.InputSpan(list.length(request.input) - 1), ttl),
            ]
            // A marker anywhere but the final block matches no declared mark.
            Some(ttl), False -> [#(types.InputSpan(-1), ttl)]
            None, _ -> []
          }
        })
      })
      |> list.flatten
      |> list.flatten
    let encoded =
      list.flatten([
        list.map(markers("tools"), fn(ttl) { #(types.ToolsSpan, ttl) }),
        list.map(markers("system"), fn(ttl) { #(types.SystemSpan, ttl) }),
        input,
      ])
    let declared =
      wire.cache_marks(request)
      |> list.map(fn(mark) { #(mark.through, mark.ttl_seconds) })
    assert declared == encoded
  }
}

/// A block's cache_control TTL in seconds, when it carries one.
fn marker_decoder() -> decode.Decoder(option.Option(Int)) {
  let ttl = {
    use ttl <- decode.optional_field("ttl", "5m", decode.string)
    decode.success(case ttl {
      "1h" -> 3600
      _ -> 300
    })
  }
  decode.optional_field(
    "cache_control",
    None,
    decode.optional(ttl),
    decode.success,
  )
}

/// A Console key bills per token, so it drops the subscription's billing
/// block, metadata and OAuth shape, but premium models answer a headerless 429
/// unless the Claude Code identity still leads the system prompt.
pub fn claude_api_key_requests_keep_only_the_identity_test() -> Result(
  List(String),
  List(decode.DecodeError),
) {
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
    wire.encode(no_files_home, wire.ApiKey("sk-ant-test"), request)
  let assert Ok("sk-ant-test") = list.key_find(exchange.headers, "x-api-key")
  let assert Error(Nil) = list.key_find(exchange.headers, "authorization")
  let assert Error(Nil) = list.key_find(exchange.headers, "x-app")
  let assert Ok(betas) = list.key_find(exchange.headers, "anthropic-beta")
  assert !string.contains(betas, "claude-code")
  assert !string.contains(betas, "oauth")
  let text = sent(exchange.body)
  assert !string.contains(text, "cch=")
  let assert Ok(value) = json.parse(text, decode.dynamic)
  let absent = fn(field) {
    decode.run(
      value,
      decode.optional_field(field, True, decode.success(False), decode.success),
    )
  }
  let assert Ok(True) = absent("metadata")
  let assert Ok(["You are Claude Code, Anthropic's official CLI for Claude."]) =
    decode.run(
      value,
      decode.at(["system"], decode.list(decode.at(["text"], decode.string))),
    )
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

@external(erlang, "albedo_skills_test_support", "fixture")
fn fixture() -> #(String, String, String)

@external(erlang, "albedo_skills_test_support", "write")
fn write(base: String, path: String, contents: String) -> String

@external(erlang, "albedo_skills_test_support", "cleanup")
fn cleanup(root: String) -> Nil

@external(erlang, "albedo_claude_auth", "accounts")
fn claude_accounts(home: String) -> List(Dynamic)

// A legacy anthropic account stored without a refresh token crashed quota
// enumeration with `bad key: <<"refresh">>` in refresh_current/3, taking out
// every Claude account's readings; E2E only ever sees that crash as log noise
// from a background spawn, so the direct call is the only clean reach. Such an
// account is never refreshed and stays as stored, like a refresh that failed,
// beside its healthy sibling.
pub fn claude_accounts_without_a_refresh_token_stay_enumerable_test() -> Nil {
  let #(root, _, home) = fixture()
  let _ =
    write(
      home,
      "creds.json",
      "{\"accounts\":{\"anthropic\":[{\"type\":\"oauth\",\"access\":\"legacy-access\"},"
        <> "{\"type\":\"oauth\",\"access\":\"fresh-access\",\"refresh\":\"r\","
        <> "\"expires\":4102444800000}]}}",
    )
  let access = decode.at(["access"], decode.string)
  let assert [Ok("legacy-access"), Ok("fresh-access")] =
    list.map(claude_accounts(home), decode.run(_, access))
  cleanup(root)
}

// Claude's fixed authenticated endpoint cannot receive the E2E fixture payloads.
pub fn malformed_stream_diagnostics_preserve_types_without_payloads_test() -> Nil {
  let reducer = stream.reducer("claude-opus-5-5", [])
  let assert Error(types.InvalidEvent(message)) =
    reducer.feed(
      "{\"type\":\"content_block_delta\",\"index\":\"secret-provider-value\",\"delta\":{\"type\":\"text_delta\"}}",
    )
  assert string.contains(message, "$.index")
  assert string.contains(message, "expected Int, found String")
  assert !string.contains(message, "secret-provider-value")
  let assert Error(types.InvalidEvent(message)) =
    reducer.feed("{\"type\":\"secret-provider-value")
  assert string.contains(message, "unexpected end of JSON")
  assert !string.contains(message, "secret-provider-value")
}
