import albedo/openai_api as openai
import albedo/openai_api/types
import gleam/dynamic/decode
import gleam/option.{None, Some}
import gleam/string

type Fixture

@external(erlang, "albedo_openai_test_server", "with_server")
fn with_server(
  body: String,
  status: Int,
  content_type: String,
  run: fn(String, Fixture) -> a,
) -> a

@external(erlang, "albedo_openai_test_server", "request")
fn received(fixture: Fixture) -> String

@external(erlang, "albedo_openai_test_server", "closed")
fn closed(fixture: Fixture) -> Bool

const response_body = "event: response.created\ndata: {\"type\":\"response.created\",\"response\":{\"id\":\"resp1\"}}\n\ndata: {\"type\":\"response.output_text.delta\",\"output_index\":0,\"content_index\":0,\"delta\":\"hello\"}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp1\",\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"hello\"}]}],\"usage\":{\"input_tokens\":2,\"output_tokens\":1}}}\n\n"

pub fn responses_stream_end_to_end_test() {
  use base, fixture <- with_server(
    response_body,
    200,
    "text/event-stream; charset=utf-8",
  )
  let client = openai.client(types.Responses, base <> "/v1/", "test-key")
  let assert Ok(turn) =
    openai.stream(client, openai.request("model", [types.User("hi")]), fn(_) {
      types.Continue
    })
  assert turn.finish == types.Complete
  assert turn.response_id == Some("resp1")
  assert turn.usage == Some(types.Usage(2, 1, None))
  let request = received(fixture)
  assert string.contains(request, "POST /v1/responses HTTP/1.1")
  assert string.contains(request, "authorization: Bearer test-key")
  assert closed(fixture)
}

pub fn chat_stream_end_to_end_test() {
  let body =
    "data: {\"id\":\"chat1\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"hello\"},\"finish_reason\":null}]}\n\ndata: {\"id\":\"chat1\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
  use base, fixture <- with_server(body, 200, "text/event-stream")
  let client = openai.client(types.ChatCompletions, base, "")
  let assert Ok(turn) =
    openai.stream(client, openai.request("model", [types.User("hi")]), fn(_) {
      types.Continue
    })
  let assert [item] = turn.output
  assert types.inspect_item(item, decode.at(["content"], decode.string))
    == Ok("hello")
  let request = received(fixture)
  assert string.contains(request, "POST /chat/completions HTTP/1.1")
  assert !string.contains(request, "authorization:")
  assert closed(fixture)
}

pub fn consumer_can_stop_and_connection_is_closed_test() {
  use base, fixture <- with_server(response_body, 200, "text/event-stream")
  let client = openai.client(types.Responses, base, "")
  assert openai.stream(
      client,
      openai.request("model", [types.User("hi")]),
      fn(_) { types.Stop },
    )
    == Error(types.Cancelled)
  assert closed(fixture)
}

pub fn premature_eof_is_not_a_completed_turn_test() {
  let body =
    "data: {\"type\":\"response.output_text.delta\",\"output_index\":0,\"content_index\":0,\"delta\":\"unfinished\"}\n\n"
  use base, _ <- with_server(body, 200, "text/event-stream")
  assert openai.stream(
      openai.client(types.Responses, base, ""),
      openai.request("model", []),
      fn(_) { types.Continue },
    )
    == Error(types.UnexpectedEnd)
}

pub fn http_error_preserves_status_and_body_test() {
  use base, _ <- with_server(
    "{\"error\":\"slow down\"}",
    429,
    "application/json",
  )
  assert openai.stream(
      openai.client(types.Responses, base, ""),
      openai.request("model", []),
      fn(_) { types.Continue },
    )
    == Error(types.HttpError(429, "{\"error\":\"slow down\"}"))
}

pub fn rejects_non_sse_success_response_test() {
  use base, _ <- with_server("{}", 200, "application/json")
  let assert Error(types.InvalidEvent(_)) =
    openai.stream(
      openai.client(types.Responses, base, ""),
      openai.request("model", []),
      fn(_) { types.Continue },
    )
}

pub fn validates_config_before_opening_connection_test() {
  let client =
    openai.client(
      types.Responses,
      "http://127.0.0.1:1",
      "key\r\nx-injected: yes",
    )
  let assert Error(types.InvalidRequest(_)) =
    openai.stream(client, openai.request("model", []), fn(_) { types.Continue })
}
