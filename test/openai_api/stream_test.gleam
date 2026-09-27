// OpenAI streaming wire-format errors and partial tool calls must never become executable output.
import albedo/openai_api/sse
import albedo/openai_api/stream
import albedo/openai_api/types
import gleam/dynamic/decode
import gleam/json
import gleam/option.{type Option, None, Some}

pub fn responses_incomplete_never_exposes_executable_calls_test() {
  let data =
    "{\"type\":\"response.incomplete\",\"response\":{\"output\":[{\"type\":\"function_call\",\"call_id\":\"danger\",\"name\":\"delete\",\"arguments\":\"{}\"}],\"incomplete_details\":{\"reason\":\"max_output_tokens\"}}}"
  let assert Ok(#(
    _,
    [],
    Some(types.Turn(None, [_], [], None, types.LengthLimit, None)),
  )) = send(stream.new(types.Responses), "response.incomplete", data)
}

pub fn responses_provider_failures_and_malformed_fields_are_typed_test() {
  let failed =
    "{\"type\":\"response.failed\",\"response\":{\"error\":{\"message\":\"capacity\"}}}"
  assert send(stream.new(types.Responses), "response.failed", failed)
    == Error(types.ProviderError("capacity"))
  let malformed = "{\"type\":\"response.created\",\"response\":{\"id\":42}}"
  let assert Error(types.InvalidEvent(_)) =
    send(stream.new(types.Responses), "response.created", malformed)
  let unsupported =
    "{\"type\":\"response.custom_tool_call_input.delta\",\"delta\":\"rm\"}"
  assert send(
      stream.new(types.Responses),
      "response.custom_tool_call_input.delta",
      unsupported,
    )
    == Error(types.Unsupported(
      "unsupported Responses semantic event: response.custom_tool_call_input.delta",
    ))
}

pub fn responses_argument_deltas_name_the_tool_their_item_opened_with_test() {
  let added =
    "{\"type\":\"response.output_item.added\",\"output_index\":1,\"item\":{\"type\":\"function_call\",\"call_id\":\"c\",\"name\":\"web_search\",\"arguments\":\"\"}}"
  let assert Ok(#(state, [], None)) =
    send(stream.new(types.Responses), "response.output_item.added", added)
  let delta =
    "{\"type\":\"response.function_call_arguments.delta\",\"output_index\":1,\"delta\":\"{\\\"q\"}"
  let assert Ok(#(_, [types.ArgumentsDelta(1, "web_search", "{\"q")], None)) =
    send(state, "response.function_call_arguments.delta", delta)
}

pub fn chat_accumulates_interleaved_tools_usage_and_native_replay_test() {
  let state = stream.new(types.ChatCompletions)
  let first =
    "{\"id\":\"chat_1\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"hel\",\"reasoning_content\":\"think \"},\"finish_reason\":null}]}"
  let assert Ok(#(
    state,
    [
      types.Started("chat_1"),
      types.ThinkingDelta("think "),
      types.TextDelta(0, 0, "hel"),
    ],
    None,
  )) = send(state, "", first)
  let one =
    "{\"id\":\"chat_1\",\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":1,\"id\":\"call_b\",\"type\":\"function\",\"function\":{\"name\":\"beta\",\"arguments\":\"{\\\"b\\\":\"}},{\"index\":0,\"id\":\"call_a\",\"type\":\"function\",\"function\":{\"name\":\"alpha\",\"arguments\":\"{\\\"a\\\":\"}}]},\"finish_reason\":null}]}"
  let assert Ok(#(
    state,
    [
      types.ArgumentsDelta(1, "beta", "{\"b\":"),
      types.ArgumentsDelta(0, "alpha", "{\"a\":"),
    ],
    None,
  )) = send(state, "", one)
  let two =
    "{\"id\":\"chat_1\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"lo\",\"refusal\":\"no\",\"reasoning_content\":\"carefully\",\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"1}\"}},{\"index\":1,\"function\":{\"arguments\":\"2}\"}}]},\"finish_reason\":\"tool_calls\"}]}"
  let assert Ok(#(state, events, None)) = send(state, "", two)
  assert events
    == [
      types.ThinkingDelta("carefully"),
      types.TextDelta(0, 0, "lo"),
      types.ArgumentsDelta(0, "alpha", "1}"),
      types.ArgumentsDelta(1, "beta", "2}"),
    ]
  let usage =
    "{\"id\":\"chat_1\",\"choices\":[],\"usage\":{\"prompt_tokens\":5,\"completion_tokens\":8,\"total_tokens\":13,\"prompt_tokens_details\":{\"cached_tokens\":0}}}"
  let assert Ok(#(state, [], None)) = send(state, "", usage)
  let assert Ok(#(
    _,
    [],
    Some(types.Turn(
      Some("chat_1"),
      [message],
      [
        types.ToolCall("call_a", "alpha", "{\"a\":1}"),
        types.ToolCall("call_b", "beta", "{\"b\":2}"),
      ],
      Some(types.Usage(5, 8, Some(0), None)),
      types.ToolCalls,
      None,
    )),
  )) = send(state, "", "[DONE]")
  let decoder = {
    use content <- decode.field("content", decode.string)
    use refusal <- decode.field("refusal", decode.string)
    use reasoning <- decode.field("reasoning_content", decode.string)
    use tool_ids <- decode.field(
      "tool_calls",
      decode.list({
        use id <- decode.field("id", decode.string)
        decode.success(id)
      }),
    )
    decode.success(#(content, refusal, reasoning, tool_ids))
  }
  assert types.inspect_item(message, decoder)
    == Ok(#("hello", "no", "think carefully", ["call_a", "call_b"]))
}

pub fn cache_usage_details_tolerate_null_and_reject_malformed_values_test() {
  let responses_null =
    "{\"type\":\"response.completed\",\"response\":{\"output\":[],\"usage\":{\"input_tokens\":3,\"output_tokens\":2,\"input_tokens_details\":null}}}"
  let assert Ok(#(
    _,
    [],
    Some(types.Turn(_, [], [], Some(types.Usage(3, 2, None, None)), _, None)),
  )) = send(stream.new(types.Responses), "", responses_null)

  let chat_null =
    "{\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":2,\"prompt_tokens_details\":null}}"
  let assert Ok(#(state, _, None)) =
    send(stream.new(types.ChatCompletions), "", chat_null)
  let assert Ok(#(
    _,
    [],
    Some(types.Turn(_, _, [], Some(types.Usage(3, 2, None, None)), _, None)),
  )) = send(state, "", "[DONE]")

  let responses_malformed =
    "{\"type\":\"response.completed\",\"response\":{\"output\":[],\"usage\":{\"input_tokens\":3,\"output_tokens\":2,\"input_tokens_details\":{\"cached_tokens\":\"3\"}}}}"
  let assert Error(types.InvalidEvent(_)) =
    send(stream.new(types.Responses), "", responses_malformed)

  let chat_malformed =
    "{\"choices\":[],\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":2,\"prompt_tokens_details\":{\"cached_tokens\":\"3\"}}}"
  let assert Error(types.InvalidEvent(_)) =
    send(stream.new(types.ChatCompletions), "", chat_malformed)
}

pub fn responses_separates_reasoning_summary_parts_test() {
  let part = fn(index) {
    "{\"type\":\"response.reasoning_summary_part.added\",\"output_index\":0,\"summary_index\":"
    <> index
    <> ",\"part\":{\"type\":\"summary_text\",\"text\":\"\"}}"
  }
  let state = stream.new(types.Responses)
  let assert Ok(#(state, [], None)) = send(state, "", part("0"))
  let assert Ok(#(_state, [types.ThinkingDelta("\n\n")], None)) =
    send(state, "", part("1"))
}

pub fn chat_rejects_multiple_choices_and_nonempty_unknown_semantics_test() {
  let multiple =
    "{\"choices\":[{\"index\":0,\"delta\":{}},{\"index\":1,\"delta\":{}}]}"
  assert send(stream.new(types.ChatCompletions), "", multiple)
    == Error(types.Unsupported("multiple chat completion choices"))
  let audio =
    "{\"choices\":[{\"index\":0,\"delta\":{\"audio\":{\"id\":\"a\"}}}]}"
  let assert Error(types.InvalidEvent(_)) =
    send(stream.new(types.ChatCompletions), "", audio)
}

pub fn chat_requires_finish_and_suppresses_partial_tools_on_limits_test() {
  assert send(stream.new(types.ChatCompletions), "", "[DONE]")
    == Error(types.InvalidEvent("[DONE] before chat finish reason"))
  let partial =
    "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_partial\",\"type\":\"function\",\"function\":{\"name\":\"unsafe\",\"arguments\":\"{\"}}]},\"finish_reason\":\"length\"}]}"
  let assert Ok(#(state, _, None)) =
    send(stream.new(types.ChatCompletions), "", partial)
  let assert Ok(#(
    _,
    [],
    Some(types.Turn(None, [message], [], None, types.LengthLimit, None)),
  )) = send(state, "", "[DONE]")
  let decoder = {
    use calls <- decode.optional_field(
      "tool_calls",
      None,
      decode.optional(decode.list(decode.dynamic)),
    )
    decode.success(calls)
  }
  assert types.inspect_item(message, decoder) == Ok(None)
}

pub fn malformed_json_and_content_filter_finish_are_typed_test() {
  let assert Error(types.InvalidEvent(_)) =
    send(stream.new(types.ChatCompletions), "", "{")
  let assert Error(types.InvalidEvent(_)) =
    send(stream.new(types.Responses), "", "[]")

  let filtered =
    "{\"choices\":[{\"index\":0,\"delta\":{\"content\":\"safe prefix\"},\"finish_reason\":\"content_filter\"}]}"
  let assert Ok(#(state, _, None)) =
    send(stream.new(types.ChatCompletions), "", filtered)
  let assert Ok(#(
    _,
    [],
    Some(types.Turn(_, _, [], _, types.ContentFiltered, None)),
  )) = send(state, "", "[DONE]")
}

pub fn chat_assembles_name_fragments_and_encodes_tool_only_content_as_null_test() {
  let first =
    "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call1\",\"function\":{\"name\":\"read_\",\"arguments\":\"{\"}}]}}]}"
  let second =
    "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"name\":\"file\",\"arguments\":\"}\"}}]},\"finish_reason\":\"tool_calls\"}]}"
  let assert Ok(#(state, _, None)) =
    send(stream.new(types.ChatCompletions), "", first)
  let assert Ok(#(state, _, None)) = send(state, "", second)
  let assert Ok(#(state, _, Some(turn))) = send(state, "", "[DONE]")
  assert turn.tool_calls == [types.ToolCall("call1", "read_file", "{}")]
  let assert [item] = turn.output
  let encoded = types.replay_json(item) |> json.to_string
  assert json.parse(
      encoded,
      decode.at(["content"], decode.optional(decode.string)),
    )
    == Ok(None)
  let assert Error(types.InvalidEvent(_)) = send(state, "", "[DONE]")
}

pub fn chat_rejects_data_after_finish_reason_test() {
  let first =
    "{\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}"
  let late = "{\"choices\":[{\"index\":0,\"delta\":{\"content\":\"late\"}}]}"
  let assert Ok(#(state, _, None)) =
    send(stream.new(types.ChatCompletions), "", first)
  let assert Error(types.InvalidEvent(_)) = send(state, "", late)
}

pub fn responses_rejects_incomplete_call_in_completed_response_test() {
  let event =
    "{\"type\":\"response.completed\",\"response\":{\"output\":[{\"type\":\"function_call\",\"call_id\":\"c\",\"name\":\"tool\",\"arguments\":\"{}\",\"status\":\"in_progress\"}]}}"
  let assert Error(types.InvalidEvent(_)) =
    send(stream.new(types.Responses), "", event)
}

pub fn compatible_reasoning_fields_are_preserved_without_renaming_test() {
  let first =
    "{\"choices\":[{\"index\":0,\"delta\":{\"reasoning\":\"r1\",\"reasoning_content\":\"c1\"}}]}"
  let second =
    "{\"choices\":[{\"index\":0,\"delta\":{\"reasoning\":\"r2\",\"reasoning_content\":\"c2\",\"content\":\"answer\"},\"finish_reason\":\"stop\"}]}"
  let assert Ok(#(state, _, None)) =
    send(stream.new(types.ChatCompletions), "", first)
  let assert Ok(#(state, _, None)) = send(state, "", second)
  let assert Ok(#(_, _, Some(turn))) = send(state, "", "[DONE]")
  let assert [item] = turn.output
  assert types.inspect_item(item, decode.at(["reasoning"], decode.string))
    == Ok("r1r2")
  assert types.inspect_item(
      item,
      decode.at(["reasoning_content"], decode.string),
    )
    == Ok("c1c2")
}

pub fn reasoning_details_merge_fragments_by_index_and_keep_metadata_test() {
  let first =
    "{\"choices\":[{\"index\":0,\"delta\":{\"reasoning\":\"a\",\"reasoning_details\":[{\"type\":\"reasoning.text\",\"index\":0,\"format\":\"unknown\",\"text\":\"a\"}]}}]}"
  let second =
    "{\"choices\":[{\"index\":0,\"delta\":{\"reasoning\":\"b\",\"reasoning_details\":[{\"type\":\"reasoning.text\",\"index\":0,\"format\":\"unknown\",\"text\":\"b\"}],\"content\":\"answer\"},\"finish_reason\":\"stop\"}]}"
  let assert Ok(#(state, _, None)) =
    send(stream.new(types.ChatCompletions), "", first)
  let assert Ok(#(state, _, None)) = send(state, "", second)
  let assert Ok(#(_, _, Some(turn))) = send(state, "", "[DONE]")
  let assert [item] = turn.output
  assert types.inspect_item(
      item,
      decode.at(
        ["reasoning_details"],
        decode.list(decode.at(["text"], decode.string)),
      ),
    )
    == Ok(["ab"])
  assert types.inspect_item(
      item,
      decode.at(
        ["reasoning_details"],
        decode.list(decode.at(["format"], decode.string)),
      ),
    )
    == Ok(["unknown"])
}

pub fn responses_uses_streamed_done_items_when_terminal_output_is_empty_test() {
  let state = stream.new(types.Responses)
  let done =
    "{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"call_id\":\"call_1\",\"name\":\"python\",\"arguments\":\"{\\\"code\\\":\\\"20 + 22\\\",\\\"timeout_ms\\\":1000}\",\"status\":\"completed\"}}"
  let assert Ok(#(state, [], None)) = send(state, "", done)
  let completed =
    "{\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\",\"output\":[],\"usage\":{\"input_tokens\":10,\"output_tokens\":5}}}"
  let assert Ok(#(
    _,
    [types.Started("resp_1")],
    Some(types.Turn(
      Some("resp_1"),
      [_],
      [types.ToolCall("call_1", "python", arguments)],
      _,
      types.ToolCalls,
      None,
    )),
  )) = send(state, "", completed)
  assert arguments == "{\"code\":\"20 + 22\",\"timeout_ms\":1000}"
}

fn send(
  state: stream.State,
  name: String,
  data: String,
) -> Result(#(stream.State, List(types.Event), Option(types.Turn)), types.Error) {
  stream.feed(state, sse.Event(name, data))
}
