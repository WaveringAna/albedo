import albedo/daemon/projection
import albedo/daemon/transcript
import albedo/openai_api/request
import albedo/openai_api/types
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/string_tree
import gleeunit/should

fn replay(protocol: types.Protocol, value: String) -> types.Input {
  let assert Ok(item) = json.parse(value, types.replay_decoder(protocol))
  types.Replay(item)
}

fn entry(input: types.Input, provider: String) -> transcript.Entry {
  transcript.Entry(input, None, Some(provider))
}

fn sourced(input: types.Input, seq: Int) -> transcript.SourcedEntry {
  transcript.SourcedEntry(
    transcript.SourceRef("session", seq),
    entry(input, "source"),
  )
}

fn encode(protocol: types.Protocol, newest: List(transcript.Entry)) -> String {
  let assert Ok(inputs) = projection.for_model(newest, "target", protocol)
  let request = types.Request("model", None, list.reverse(inputs), [], None)
  let assert Ok(body) = request.encode(protocol, request)
  string_tree.to_string(body)
}

pub fn responses_span_becomes_one_valid_chat_assistant_message_test() {
  let chronological = [
    entry(types.User("before"), "source"),
    entry(
      replay(
        types.Responses,
        "{\"type\":\"function_call\",\"call_id\":\"a\",\"name\":\"first\",\"arguments\":\"{\\\"n\\\":1}\",\"status\":\"completed\"}",
      ),
      "source",
    ),
    entry(
      replay(
        types.Responses,
        "{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"between\"}]}",
      ),
      "source",
    ),
    entry(
      replay(
        types.Responses,
        "{\"type\":\"reasoning\",\"encrypted_content\":\"opaque\"}",
      ),
      "source",
    ),
    entry(
      replay(
        types.Responses,
        "{\"type\":\"function_call\",\"call_id\":\"b\",\"name\":\"second\",\"arguments\":\"{}\",\"status\":\"completed\"}",
      ),
      "source",
    ),
    entry(types.ToolOutput("a", "result-a", []), "source"),
    entry(types.ToolOutput("b", "result-b", []), "source"),
    entry(types.User("after"), "source"),
  ]
  let body = encode(types.ChatCompletions, list.reverse(chronological))
  let assert Ok(messages) =
    json.parse(body, decode.at(["messages"], decode.list(decode.dynamic)))
  list.map(messages, fn(message) {
    decode.run(message, decode.field("role", decode.string, decode.success))
  })
  |> should.equal([
    Ok("user"),
    Ok("assistant"),
    Ok("tool"),
    Ok("tool"),
    Ok("user"),
  ])
  let assert [_, assistant, first, second, _] = messages
  decode.run(assistant, decode.field("content", decode.string, decode.success))
  |> should.equal(Ok("between"))
  decode.run(
    assistant,
    decode.at(
      ["tool_calls"],
      decode.list(decode.field("id", decode.string, decode.success)),
    ),
  )
  |> should.equal(Ok(["a", "b"]))
  decode.run(first, decode.field("tool_call_id", decode.string, decode.success))
  |> should.equal(Ok("a"))
  decode.run(
    second,
    decode.field("tool_call_id", decode.string, decode.success),
  )
  |> should.equal(Ok("b"))
}

pub fn chat_text_calls_and_results_project_to_responses_in_order_test() {
  let chronological = [
    entry(types.User("before"), "source"),
    entry(
      replay(
        types.ChatCompletions,
        "{\"role\":\"assistant\",\"content\":\"working\",\"reasoning_content\":\"secret\",\"tool_calls\":[{\"id\":\"a\",\"type\":\"function\",\"function\":{\"name\":\"first\",\"arguments\":\"{}\"}},{\"id\":\"b\",\"type\":\"function\",\"function\":{\"name\":\"second\",\"arguments\":\"{}\"}}]}",
      ),
      "source",
    ),
    entry(types.ToolOutput("a", "result-a", []), "source"),
    entry(types.ToolOutput("b", "result-b", []), "source"),
  ]
  let body = encode(types.Responses, list.reverse(chronological))
  let assert Ok(inputs) =
    json.parse(body, decode.at(["input"], decode.list(decode.dynamic)))
  let assert [user, text, first, second, first_result, second_result] = inputs
  decode.run(user, decode.field("content", decode.string, decode.success))
  |> should.equal(Ok("before"))
  decode.run(text, decode.field("content", decode.string, decode.success))
  |> should.equal(Ok("working"))
  list.map([first, second, first_result, second_result], fn(input) {
    decode.run(input, decode.field("call_id", decode.string, decode.success))
  })
  |> should.equal([Ok("a"), Ok("b"), Ok("a"), Ok("b")])
  string.contains(body, "secret") |> should.be_false
}

pub fn matching_provider_protocol_replay_is_lossless_test() {
  let item =
    replay(
      types.Responses,
      "{\"type\":\"reasoning\",\"encrypted_content\":\"opaque\",\"future\":{\"x\":1}}",
    )
  let newest = [entry(item, "target")]
  let body = encode(types.Responses, newest)
  let assert Ok([saved]) =
    json.parse(body, decode.at(["input"], decode.list(decode.dynamic)))
  decode.run(saved, decode.at(["future", "x"], decode.int))
  |> should.equal(Ok(1))
  string.contains(body, "opaque") |> should.be_true
}

pub fn unsupported_meaningful_output_rejects_projection_test() {
  let newest = [
    entry(
      replay(
        types.Responses,
        "{\"type\":\"computer_call\",\"id\":\"important\"}",
      ),
      "source",
    ),
  ]
  let assert Error(error) =
    projection.for_model(newest, "target", types.ChatCompletions)
  string.contains(error, "computer_call") |> should.be_true
  string.contains(error, "not portable") |> should.be_true
}

pub fn source_references_follow_provider_projection_test() {
  let chronological = [
    sourced(types.User("prompt"), 10),
    sourced(
      replay(
        types.Responses,
        "{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"answer\"}]}",
      ),
      11,
    ),
    sourced(
      replay(
        types.Responses,
        "{\"type\":\"reasoning\",\"encrypted_content\":\"opaque\"}",
      ),
      12,
    ),
    sourced(
      replay(
        types.Responses,
        "{\"type\":\"function_call\",\"call_id\":\"a\",\"name\":\"python\",\"arguments\":\"{}\",\"status\":\"completed\"}",
      ),
      13,
    ),
    sourced(types.ToolOutput("a", "done", []), 14),
  ]
  let newest = list.reverse(chronological)
  let assert Ok(projected) =
    projection.for_model_with_sources(newest, "target", types.ChatCompletions)
  let chronological_inputs = list.reverse(projected)
  let assert [prompt, assistant, output] = chronological_inputs
  prompt.sources |> should.equal([transcript.SourceRef("session", 10)])
  assistant.sources
  |> should.equal([
    transcript.SourceRef("session", 11),
    transcript.SourceRef("session", 13),
  ])
  output.sources |> should.equal([transcript.SourceRef("session", 14)])
  let assert Ok(plain) =
    projection.for_model(
      list.map(newest, fn(item) { item.entry }),
      "target",
      types.ChatCompletions,
    )
  list.map(projected, fn(item) { item.input }) |> should.equal(plain)
}

pub fn one_source_can_produce_multiple_portable_inputs_test() {
  let newest = [
    sourced(
      replay(
        types.ChatCompletions,
        "{\"role\":\"assistant\",\"content\":\"working\",\"tool_calls\":[{\"id\":\"a\",\"type\":\"function\",\"function\":{\"name\":\"python\",\"arguments\":\"{}\"}}]}",
      ),
      20,
    ),
  ]
  let assert Ok([call, text]) =
    projection.for_model_with_sources(newest, "target", types.Responses)
  call.sources |> should.equal([transcript.SourceRef("session", 20)])
  text.sources |> should.equal([transcript.SourceRef("session", 20)])
}
