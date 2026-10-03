// Signed replay and provider schema policy are tested offline because Antigravity
// uses an authenticated fixed endpoint that the loopback E2E provider cannot reach.
import albedo/harness/extensions/antigravity/catalog
import albedo/harness/extensions/antigravity/stream
import albedo/harness/extensions/antigravity/wire
import albedo/openai_api
import albedo/openai_api/stream as provider_stream
import albedo/openai_api/types
import gleam/dynamic
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/string_tree

const gemini = "gemini-3.1-pro-low"

const claude = "claude-sonnet-4-6"

/// Test fixture models for wire encoding and streaming tests.
fn model(id: String) -> catalog.Model {
  case id {
    "gemini-3.1-pro-low" ->
      catalog.Model(
        id,
        "Gemini 3.1 Pro (Low)",
        1_048_576,
        65_535,
        True,
        catalog.Budget(1001, 8192, 10_001),
        Some("MODEL_PLACEHOLDER_M36"),
        True,
      )
    "claude-sonnet-4-6" ->
      catalog.Model(
        id,
        "Claude Sonnet 4.6",
        250_000,
        64_000,
        True,
        catalog.Budget(4096, 8192, 16_384),
        None,
        True,
      )
    _ -> catalog.model("/nonexistent/albedo-home", id, None)
  }
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

fn at(
  value: dynamic.Dynamic,
  path: List(String),
  decoder: decode.Decoder(a),
) -> a {
  let assert Ok(found) = decode.run(value, decode.at(path, decoder))
  found
}

fn schema_json(source: String) -> json.Json {
  let assert Ok(value) = json.parse(source, decode.dynamic)
  types.encode_value(value)
}

fn schema_request(id: String, schema: json.Json) -> types.Request {
  types.Request(
    ..openai_api.request(id, [types.User("hi")]),
    tools: [types.Tool("inputs", "Choose inputs", schema, False)],
    options: types.Options(
      ..types.defaults,
      format: Some(types.JsonSchema("answer", schema, True)),
    ),
  )
}

fn tool_schema(value: dynamic.Dynamic) -> dynamic.Dynamic {
  let assert [tool] =
    at(value, ["request", "tools"], decode.list(decode.dynamic))
  let assert [declaration] =
    at(tool, ["functionDeclarations"], decode.list(decode.dynamic))
  at(declaration, ["parameters"], decode.dynamic)
}

pub fn schema_resolves_references_and_merges_object_requirements_test() -> Result(
  dynamic.Dynamic,
  List(decode.DecodeError),
) {
  let schema =
    schema_json(
      "{
    \"definitions\": {\"child\": {\"type\": \"boolean\"}},
    \"$defs\": {\"child\": {\"type\": \"object\", \"properties\": {
      \"value\": {\"type\": \"integer\"}
    }, \"required\": [\"value\", \"missing\", 12]}},
    \"properties\": {\"shared\": {\"type\": \"string\"}},
    \"required\": [\"shared\", \"absent\", false],
    \"allOf\": [
      {\"title\": \"earlier\", \"properties\": {
        \"shared\": {\"type\": \"number\"},
        \"branch\": {\"type\": \"boolean\"},
        \"children\": {\"type\": \"array\", \"items\": {\"$ref\": \"#/arbitrary/path/child\"}}
      }, \"required\": [\"children\", \"branch\"]},
      {\"title\": \"later\", \"properties\": {\"branch\": {\"type\": \"string\"}},
       \"required\": [\"shared\", \"branch\", null]}
    ]
  }",
    )
  let actual = tool_schema(body(gemini, schema_request(gemini, schema)))
  assert at(actual, ["type"], decode.string) == "object"
  assert at(actual, ["title"], decode.string) == "later"
  assert at(actual, ["properties", "shared", "type"], decode.string) == "string"
  assert at(actual, ["properties", "branch", "type"], decode.string)
    == "boolean"
  assert at(actual, ["required"], decode.list(decode.string))
    == ["branch", "children", "shared"]
  let child = at(actual, ["properties", "children", "items"], decode.dynamic)
  assert at(child, ["type"], decode.string) == "object"
  assert at(child, ["properties", "value", "type"], decode.string) == "integer"
  assert at(child, ["required"], decode.list(decode.string)) == ["value"]
  let assert Error(_) = decode.run(actual, decode.at(["allOf"], decode.dynamic))
}

pub fn schema_reduces_unions_and_keeps_constraint_guidance_test() -> Result(
  dynamic.Dynamic,
  List(decode.DecodeError),
) {
  let schema =
    schema_json(
      "{\"type\": \"object\", \"properties\": {
    \"nullable\": {\"anyOf\": [{\"type\": \"null\"}, {\"type\": \"integer\"}]},
    \"typed\": {\"type\": [null, \"null\", \"boolean\", \"string\"]},
    \"choice\": {\"oneOf\": [{\"const\": 7}, {\"enum\": [true, \"seven\", null, 7]}]},
    \"constant\": {\"const\": false},
    \"mixed\": {\"description\": \"Pick\", \"anyOf\": [{\"type\": \"string\"}, {\"type\": \"number\"}]},
    \"limited\": {\"type\": \"string\", \"description\": \"Name\", \"pattern\": \"^[a-z]+$\", \"minLength\": 2}
  }}",
    )
  let actual = tool_schema(body(gemini, schema_request(gemini, schema)))
  let properties = at(actual, ["properties"], decode.dynamic)
  assert at(properties, ["nullable", "type"], decode.string) == "integer"
  assert at(properties, ["typed", "type"], decode.string) == "boolean"
  assert at(properties, ["choice", "type"], decode.string) == "string"
  assert at(properties, ["choice", "enum"], decode.list(decode.string))
    == ["7", "seven", "true"]
  assert at(properties, ["constant", "enum"], decode.list(decode.string))
    == ["false"]
  assert at(properties, ["mixed", "type"], decode.string) == "string"
  assert at(properties, ["mixed", "description"], decode.string)
    == "Pick (one of: string, number)"
  let limited = at(properties, ["limited"], decode.dynamic)
  let guidance = at(limited, ["description"], decode.string)
  assert string.contains(guidance, "Name")
  assert string.contains(guidance, "pattern: \"^[a-z]+$\"")
  assert string.contains(guidance, "minLength: 2")
  let assert Error(_) =
    decode.run(limited, decode.at(["pattern"], decode.dynamic))
}

fn item_depth(schema: dynamic.Dynamic) -> Int {
  case decode.run(schema, decode.at(["items"], decode.dynamic)) {
    Ok(items) -> 1 + item_depth(items)
    Error(_) -> 0
  }
}

pub fn schema_bounds_recursion_and_handles_malformed_keywords_test() -> Nil {
  let malformed =
    schema_json(
      "{
    \"type\": \"object\", \"description\": false, \"title\": [], \"required\": true,
    \"definitions\": [], \"$defs\": {\"loop\": {\"$ref\": \"#/$defs/loop\"}},
    \"allOf\": [null, false, {\"properties\": [], \"required\": false}],
    \"properties\": {
      \"cycle\": {\"$ref\": \"#/$defs/loop\"},
      \"object\": {\"type\": \"object\", \"properties\": [], \"required\": true},
      \"array\": {\"type\": \"array\", \"items\": [false, {\"type\": \"string\"}]},
      \"union\": {\"oneOf\": [3, {\"title\": false}, {\"title\": []}]},
      \"enum\": {\"type\": \"string\", \"enum\": false},
      \"combiner\": {\"anyOf\": false, \"allOf\": {}, \"oneOf\": 2}
    }
  }",
    )
  let actual = tool_schema(body(gemini, schema_request(gemini, malformed)))
  let assert Ok(empty) = json.parse("{}", decode.dynamic)
  assert at(actual, ["properties", "cycle"], decode.dynamic) == empty
  assert at(actual, ["properties", "object", "properties"], decode.dynamic)
    == empty
  let assert Error(_) =
    decode.run(actual, decode.at(["required"], decode.dynamic))
  assert at(actual, ["title"], decode.string) == ""
  assert at(actual, ["description"], decode.string) == ""
  let assert Error(_) =
    decode.run(
      actual,
      decode.at(["properties", "enum", "enum"], decode.dynamic),
    )
  assert at(actual, ["properties", "combiner"], decode.dynamic) == empty
  assert at(actual, ["properties", "union", "description"], decode.string)
    == "one of: schema, schema"
  assert at(actual, ["properties", "array", "items", "type"], decode.string)
    == "string"
  let deep =
    list.fold(list.repeat(Nil, 40), json.object([]), fn(items, _) {
      json.object([#("type", json.string("array")), #("items", items)])
    })
  let schema =
    json.object([
      #("type", json.string("object")),
      #("properties", json.object([#("deep", deep)])),
    ])
  let actual = tool_schema(body(gemini, schema_request(gemini, schema)))
  let depth = item_depth(at(actual, ["properties", "deep"], decode.dynamic))
  assert depth > 0
  assert depth <= 32
  let definitions =
    int.range(0, 41, [], fn(definitions, index) {
      let target = case index {
        40 ->
          json.object([
            #("type", json.string("object")),
            #(
              "properties",
              json.object([
                #(
                  "unreachable",
                  json.object([#("type", json.string("string"))]),
                ),
              ]),
            ),
          ])
        _ ->
          json.object([
            #("$ref", json.string("#/$defs/" <> int.to_string(index + 1))),
          ])
      }
      [#(int.to_string(index), target), ..definitions]
    })
  let schema =
    json.object([
      #("$ref", json.string("#/$defs/0")),
      #("$defs", json.object(definitions)),
    ])
  let actual = tool_schema(body(gemini, schema_request(gemini, schema)))
  assert at(actual, ["type"], decode.string) == "object"
  assert at(actual, ["properties"], decode.dynamic) == empty
}

pub fn both_model_families_normalize_tools_and_structured_responses_test() -> Nil {
  let schemas = [
    #(
      schema_json(
        "{\"properties\": {\"answer\": {\"const\": 42}}, \"required\": [\"answer\", \"missing\"]}",
      ),
      True,
    ),
    #(json.bool(True), False),
    #(
      schema_json("{\"type\": \"array\", \"items\": {\"type\": \"string\"}}"),
      False,
    ),
  ]
  list.each([gemini, claude], fn(id) {
    list.each(schemas, fn(entry) {
      let #(schema, has_answer) = entry
      let value = body(id, schema_request(id, schema))
      let parameters = tool_schema(value)
      let response =
        at(
          value,
          ["request", "generationConfig", "responseSchema"],
          decode.dynamic,
        )
      assert parameters == response
      assert at(response, ["type"], decode.string) == "object"
      assert at(
          value,
          ["request", "generationConfig", "responseMimeType"],
          decode.string,
        )
        == "application/json"
      case has_answer {
        True -> {
          assert at(
              response,
              ["properties", "answer", "enum"],
              decode.list(decode.string),
            )
            == ["42"]
          assert at(response, ["required"], decode.list(decode.string))
            == ["answer"]
        }
        False -> {
          let assert Ok(empty) = json.parse("{}", decode.dynamic)
          assert at(response, ["properties"], decode.dynamic) == empty
        }
      }
    })
  })
}

fn chunk(json: String) -> String {
  "{\"response\":" <> json <> ",\"traceId\":\"t\"}"
}

/// Feeds each payload, then ends the body.
fn reduce(
  id: String,
  payloads: List(String),
) -> #(Result(types.Turn, types.Error), List(types.Event)) {
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

fn signed_turn_payloads() -> List(String) {
  list.map(signed_turn, chunk)
}

pub fn stream_reduces_thoughts_text_and_calls_test() -> Nil {
  let #(outcome, events) = reduce(gemini, signed_turn_payloads())
  let assert Ok(turn) = outcome
  let assert [
    types.Started("r1"),
    types.ThinkingDelta("weigh"),
    types.ThinkingDelta("ing"),
    types.TextDelta(0, 0, "looking"),
    types.ArgumentsDelta(0, "bash", arguments),
  ] = events
  assert arguments == "{\"command\":\"ls\"}"
  assert turn.finish == types.ToolCalls
  // Output folds the 2 thought tokens in; reasoning carries the thought count.
  assert turn.usage
    == Some(types.Usage(10, 5, Some(4), None, None, None, Some(2)))
  let assert [types.ToolCall(id, "bash", "{\"command\":\"ls\"}")] =
    turn.tool_calls
  assert string.starts_with(id, "call_")
  assert turn.call_indices == [#(id, 0)]
  let assert [item] = turn.output
  assert types.inspect_item(item, decode.at(["content"], decode.string))
    == Ok("looking")
  assert types.inspect_item(
      item,
      decode.at(["reasoning_content"], decode.string),
    )
    == Ok("weighing")
}

pub fn stream_maps_multiple_calls_to_their_emitted_output_indices_test() -> Nil {
  let payload =
    chunk(
      "{\"candidates\":[{\"content\":{\"parts\":[{\"functionCall\":{\"name\":\"bash\",\"args\":{\"command\":\"ls\"}}},{\"functionCall\":{\"name\":\"bash\",\"args\":{\"command\":\"pwd\"}}}]},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":10,\"candidatesTokenCount\":3}}",
    )
  let #(outcome, events) = reduce(gemini, [payload])
  let assert Ok(turn) = outcome
  let assert [first, second] = turn.tool_calls
  assert turn.call_indices == [#(first.id, 0), #(second.id, 1)]
  assert events
    == [
      types.ArgumentsDelta(0, "bash", "{\"command\":\"ls\"}"),
      types.ArgumentsDelta(1, "bash", "{\"command\":\"pwd\"}"),
    ]
}

pub fn same_model_replay_keeps_signed_parts_test() -> Nil {
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

pub fn another_models_output_replays_portably_test() -> Nil {
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

pub fn foreign_calls_carry_the_skip_signature_on_gemini_test() -> Nil {
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

pub fn frame_archive_images_carry_no_empty_text_part_test() -> Nil {
  // Snapcompact's frame archive attaches images with no text after the
  // archive prompt; Cloud Code Assist's Claude translation rejected the
  // empty text part with "messages.0.content.2.text.text: Field required".
  let assert Ok(first) = types.image("image/png", "aGk=", 2, 3, 2)
  let assert Ok(second) = types.image("image/png", "aGk=", 2, 3, 2)
  let request =
    openai_api.request(claude, [
      types.UserImage("the archive prompt", first),
      types.UserImage("", second),
    ])
  let assert [user] =
    at(
      body(claude, request),
      ["request", "contents"],
      decode.list(decode.dynamic),
    )
  assert at(user, ["role"], decode.string) == "user"
  let assert [text, first_part, second_part] =
    at(user, ["parts"], decode.list(decode.dynamic))
  assert at(text, ["text"], decode.string) == "the archive prompt"
  assert at(first_part, ["inlineData", "mimeType"], decode.string)
    == "image/png"
  assert at(second_part, ["inlineData", "mimeType"], decode.string)
    == "image/png"
  let assert Error(_) =
    decode.run(second_part, decode.at(["text"], decode.string))
  Nil
}

pub fn empty_body_is_a_retryable_failure_test() -> Nil {
  let #(outcome, _) = reduce(gemini, [])
  assert outcome == Error(types.UnexpectedEnd)
}

pub fn stream_errors_surface_the_provider_message_test() -> Result(
  #(provider_stream.Reducer, List(types.Event), option.Option(types.Turn)),
  types.Error,
) {
  let reducer = stream.reducer(model(gemini))
  let assert Error(types.ProviderError("quota")) =
    reducer.feed("{\"error\":{\"code\":429,\"message\":\"quota\"}}")
}
