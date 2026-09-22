//// Streaming OpenAI Responses and Chat Completions for the Erlang target.
////
//// ```gleam
//// let client = openai.client(types.Responses, "https://api.openai.com/v1", key)
//// let request = openai.request(model, [types.User("hello")])
//// let result = openai.stream(client, request, fn(event) {
////   case event {
////     types.TextDelta(_, _, text) -> io.print(text)
////     _ -> Nil
////   }
////   types.Continue
//// })
//// ```
////
//// Callbacks run in the calling process. Returning Stop closes the connection.
//// There are no automatic retries: an interrupted attempt may have incurred cost.
//// Replay final output using types.Replay; never flatten it to assistant text.
//// This first adapter supports text and function tools, not audio/image input or
//// custom tools. Function argument strings must be validated before execution.
//// Requires Erlang/OTP 27+ for native JSON. ssevents owns SSE framing; Gun owns
//// streaming HTTP, flow control, and TLS verification. Requests stay as iodata.

import albedo/openai_api/request
import albedo/openai_api/sse
import albedo/openai_api/stream as reducer
import albedo/openai_api/transport
import albedo/openai_api/types.{
  type Client, type Control, type Error, type Event, type Input, type Protocol,
  type Request, type Turn, ChatCompletions, Continue, Responses, Stop,
}
import gleam/bit_array
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// base_url is the API root, e.g. https://api.openai.com/v1, not a full route.
/// An empty api_key omits Authorization for local compatible servers.
pub fn client(protocol: Protocol, base_url: String, api_key: String) -> Client {
  types.Client(
    protocol,
    base_url,
    api_key,
    timeout_ms: 60_000,
    max_event_bytes: 8 * 1024 * 1024,
    policy: types.OpenAI,
  )
}

/// ChatGPT subscription transport. OAuth and account selection stay outside
/// the protocol adapter; this client owns only Codex wire policy.
pub fn codex_client(
  base_url: String,
  access_token: String,
  account_id: String,
  session_id: String,
) -> Client {
  types.Client(
    Responses,
    base_url,
    access_token,
    timeout_ms: 60_000,
    max_event_bytes: 8 * 1024 * 1024,
    policy: types.Codex(account_id, session_id),
  )
}

pub fn request(model: String, input: List(Input)) -> Request {
  types.Request(model, None, input, [], None)
}

/// Returns final replayable items and tool-call proposals. The caller must validate
/// tool arguments and apply permissions before execution. Non-complete output is
/// explicitly marked; stopping the callback returns Error(Cancelled), not success.
/// Timeout applies to connection startup and each wait for transport data.
pub fn stream(
  client: Client,
  request: Request,
  on_event: fn(Event) -> Control,
) -> Result(Turn, Error) {
  use _ <- result.try(validate_client(client))
  use _ <- result.try(validate_policy(client.policy, request.model))
  use body <- result.try(request.encode_with_policy(
    client.protocol,
    client.policy,
    request,
  ))
  let path = case client.policy, client.protocol {
    types.Codex(_, _), _ -> "/codex/responses"
    _, Responses -> "/responses"
    _, ChatCompletions -> "/chat/completions"
  }
  let url = string.remove_suffix(client.base_url, "/") <> path
  let headers = [
    #("content-type", "application/json"),
    #("accept", "text/event-stream"),
  ]
  let headers = case client.policy {
    types.OpenAI -> headers
    types.Codex(account_id, session_id) -> [
      #("chatgpt-account-id", account_id),
      #("originator", "albedo"),
      #("user-agent", "albedo"),
      #("openai-beta", "responses=experimental"),
      #("x-codex-routing-hint", "model=" <> request.model),
      #("session_id", session_id),
      #("x-client-request-id", session_id),
      ..headers
    ]
  }
  let headers = case client.api_key {
    "" -> headers
    key -> [#("authorization", "Bearer " <> key), ..headers]
  }
  use connection <- result.try(
    transport.open(url, headers, body, client.timeout_ms)
    |> result.map_error(transport_error),
  )
  use <- transport.with_connection(connection)
  use first <- result.try(receive(connection))
  case first {
    transport.Headers(status, headers, final) if status >= 200 && status < 300 -> {
      case event_stream(headers), client.policy {
        False, types.OpenAI -> http_error(connection, status, final, [], 0)
        _, _ if final -> Error(types.UnexpectedEnd)
        // ChatGPT's Codex endpoint currently streams valid SSE with a generic
        // content type. Its framing, not that header, is authoritative.
        _, _ ->
          pump(
            connection,
            sse.new(client.max_event_bytes),
            reducer.new(client.protocol),
            on_event,
          )
      }
    }
    transport.Headers(status, _, final) ->
      http_error(connection, status, final, [], 0)
    _ -> Error(types.InvalidEvent("HTTP data arrived before headers"))
  }
}

fn validate_client(client: Client) -> Result(Nil, Error) {
  case client.timeout_ms <= 0 || client.max_event_bytes <= 0 {
    True ->
      Error(types.InvalidRequest("timeouts and event limits must be positive"))
    False ->
      case
        string.contains(client.api_key, "\r")
        || string.contains(client.api_key, "\n")
        || string.contains(client.base_url, "?")
        || string.contains(client.base_url, "#")
      {
        True -> Error(types.InvalidRequest("invalid API key or base URL"))
        False -> Ok(Nil)
      }
  }
}

fn validate_policy(
  policy: types.ProviderPolicy,
  model: String,
) -> Result(Nil, Error) {
  case policy {
    types.OpenAI -> Ok(Nil)
    types.Codex(account_id, session_id) ->
      case
        unsafe_header(model)
        || string.trim(account_id) == ""
        || unsafe_header(account_id)
        || string.trim(session_id) == ""
        || unsafe_header(session_id)
      {
        True -> Error(types.InvalidRequest("invalid Codex request identity"))
        False -> Ok(Nil)
      }
  }
}

fn unsafe_header(value: String) -> Bool {
  string.contains(value, "\r") || string.contains(value, "\n")
}

fn event_stream(headers: List(#(String, String))) -> Bool {
  list.any(headers, fn(header) {
    let #(name, value) = header
    string.lowercase(name) == "content-type"
    && {
      value
      |> string.split(";")
      |> list.first
      |> result.unwrap("")
      |> string.trim
      |> string.lowercase
    }
    == "text/event-stream"
  })
}

fn pump(
  connection: transport.Connection,
  parser: sse.Parser,
  state: reducer.State,
  on_event: fn(Event) -> Control,
) -> Result(Turn, Error) {
  use message <- result.try(receive(connection))
  case message {
    transport.Data(bytes, final) -> {
      use #(parser, events) <- result.try(
        sse.feed(parser, bytes) |> result.map_error(sse_error),
      )
      use #(state, turn) <- result.try(deliver(state, events, on_event))
      case turn, final {
        Some(turn), _ -> Ok(turn)
        None, True -> {
          use events <- result.try(
            sse.finish(parser) |> result.map_error(sse_error),
          )
          use #(_, turn) <- result.try(deliver(state, events, on_event))
          case turn {
            Some(turn) -> Ok(turn)
            None -> Error(types.UnexpectedEnd)
          }
        }
        None, False -> pump(connection, parser, state, on_event)
      }
    }
    _ -> Error(types.InvalidEvent("unexpected HTTP headers inside stream"))
  }
}

fn deliver(
  state: reducer.State,
  events: List(sse.Event),
  on_event: fn(Event) -> Control,
) -> Result(#(reducer.State, Option(Turn)), Error) {
  case events {
    [] -> Ok(#(state, None))
    [event, ..rest] -> {
      use #(state, updates, turn) <- result.try(reducer.feed(state, event))
      use _ <- result.try(notify(updates, on_event))
      case turn {
        Some(_) -> Ok(#(state, turn))
        None -> deliver(state, rest, on_event)
      }
    }
  }
}

fn notify(
  events: List(Event),
  on_event: fn(Event) -> Control,
) -> Result(Nil, Error) {
  list.try_each(events, fn(event) {
    case on_event(event) {
      Continue -> Ok(Nil)
      Stop -> Error(types.Cancelled)
    }
  })
}

fn receive(
  connection: transport.Connection,
) -> Result(transport.Message, Error) {
  transport.receive(connection) |> result.map_error(transport_error)
}

fn transport_error(error: transport.Error) -> Error {
  case error {
    transport.InvalidUrl -> types.InvalidRequest("invalid HTTP endpoint")
    transport.TransportError(message) -> types.ConnectionError(message)
    transport.TimedOut -> types.Timeout
  }
}

fn sse_error(error: sse.Error) -> Error {
  case error {
    sse.EventTooLarge -> types.EventTooLarge
    sse.InvalidUtf8 -> types.InvalidEvent("invalid UTF-8 in event stream")
    sse.Malformed(message) -> types.InvalidEvent(message)
  }
}

fn http_error(
  connection: transport.Connection,
  status: Int,
  final: Bool,
  chunks: List(BitArray),
  size: Int,
) -> Result(a, Error) {
  case final || size >= 65_536 {
    True -> {
      let body =
        chunks
        |> list.reverse
        |> bit_array.concat
        |> bit_array.to_string
        |> result.unwrap("<non-UTF-8 response body>")
      Error(types.HttpError(status, body))
    }
    False -> {
      use message <- result.try(receive(connection))
      case message {
        transport.Data(bytes, final) -> {
          let remaining = 65_536 - size
          let bytes = case bit_array.byte_size(bytes) > remaining {
            True -> bit_array.slice(bytes, 0, remaining) |> result.unwrap(<<>>)
            False -> bytes
          }
          http_error(
            connection,
            status,
            final,
            [bytes, ..chunks],
            size + bit_array.byte_size(bytes),
          )
        }
        _ -> Error(types.HttpError(status, "unexpected response framing"))
      }
    }
  }
}
