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
//// This module does not retry; the tool loop reissues transient failures.
//// Replay final output using types.Replay; never flatten it to assistant text.
//// Supports text, image input, and function tools. Audio and custom tools are
//// unsupported. Function arguments must be validated before execution.
//// Requires Erlang/OTP 27+ for native JSON. The bounded incremental parser owns
//// SSE framing. HTTP/1.1 is read straight from a socket the caller owns,
//// verified TLS for https, and kept alive between requests to the same host.
//// Requests stay as iodata.

import albedo/clock

import albedo/openai_api/request
import albedo/openai_api/sse
import albedo/openai_api/stream as reducer
import albedo/openai_api/transport
import albedo/openai_api/types.{
  type Client, type Control, type Error, type Event, type Input, type Protocol,
  type Request, type Turn, ChatCompletions, Continue, Responses, Stop,
}
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/string_tree.{type StringTree}

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

/// OpenCode Go subscription transport: Chat Completions with per-conversation
/// `x-opencode-session` routing and prompt-cache affinity.
pub fn opencode_go_client(
  base_url: String,
  api_key: String,
  session_id: String,
  org_id: String,
) -> Client {
  types.Client(
    ChatCompletions,
    base_url,
    api_key,
    timeout_ms: 60_000,
    max_event_bytes: 8 * 1024 * 1024,
    policy: types.OpenCodeGo(session_id, org_id),
  )
}

pub fn request(model: String, input: List(Input)) -> Request {
  types.Request(model, None, input, [], None, types.defaults)
}

/// Returns final replayable items and tool-call proposals. The caller must validate
/// tool arguments and apply permissions before execution. Non-complete output is
/// explicitly marked; stopping the callback returns Error(Cancelled), not success.
/// Timeout applies to connection startup and the wait for response headers;
/// after them a silent stream is awaited while its connection stays alive.
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
  exchange(
    Exchange(
      string.remove_suffix(client.base_url, "/") <> path,
      headers(client, request.model),
      body,
      client.timeout_ms,
      None,
      client.max_event_bytes,
      // ChatGPT's Codex endpoint currently streams valid SSE with a generic
      // content type. Its framing, not that header, is authoritative.
      require_event_stream: case client.policy {
        types.Codex(_, _) -> False
        types.OpenAI | types.OpenCodeGo(_, _) -> True
      },
    ),
    reducer.reducer(client.protocol),
    on_event,
  )
}

/// The headers a streaming request for `model` carries through `client`.
pub fn headers(client: Client, model: String) -> List(#(String, String)) {
  let headers = [
    #("content-type", "application/json"),
    #("accept", "text/event-stream"),
  ]
  let headers = case client.policy {
    types.OpenAI -> headers
    types.OpenCodeGo(session_id, org_id) -> {
      let headers = [
        #("user-agent", "albedo/1.0"),
        #("x-opencode-client", "albedo"),
        #("x-opencode-session", session_id),
        ..headers
      ]
      case org_id {
        "" -> headers
        _ -> [#("x-opencode-org-id", org_id), ..headers]
      }
    }
    types.Codex(account_id, session_id) -> [
      #("chatgpt-account-id", account_id),
      #("originator", "albedo"),
      #("user-agent", "albedo"),
      #("openai-beta", "responses=experimental"),
      #("x-codex-routing-hint", "model=" <> model),
      #("session_id", session_id),
      #("x-client-request-id", session_id),
      ..headers
    ]
  }
  case client.api_key {
    "" -> headers
    key -> [#("authorization", "Bearer " <> key), ..headers]
  }
}

/// One streaming POST whose SSE payloads a reducer turns into events and a
/// turn. A provider with its own wire format drives this directly.
///
/// `timeout_ms` bounds connecting and each wait up to the first event; after
/// it a silent body is awaited while TCP keepalive finds the peer alive.
/// With `first_event_timeout_ms`, the headers and the first event share that
/// budget instead, counted from when the request went out: a model that
/// thinks silently before it streams anything gets its own allowance.
pub type Exchange {
  Exchange(
    url: String,
    headers: List(#(String, String)),
    body: StringTree,
    timeout_ms: Int,
    first_event_timeout_ms: Option(Int),
    max_event_bytes: Int,
    require_event_stream: Bool,
  )
}

/// The budgets one exchange waits under; `first_event` is the deadline its
/// headers and first event must meet, and the budget that deadline came from.
type Wait {
  Wait(idle_ms: Int, first_event: Option(#(Int, Int)))
}

pub fn exchange(
  exchange: Exchange,
  reducer: reducer.Reducer,
  on_event: fn(Event) -> Control,
) -> Result(Turn, Error) {
  let exchange = capped(exchange, transport.budget_cap())
  let sent = clock.monotonic_ms()
  let wait =
    Wait(
      exchange.timeout_ms,
      option.map(exchange.first_event_timeout_ms, fn(budget) {
        #(sent + budget, budget)
      }),
    )
  use connection <- result.try(
    transport.open(
      exchange.url,
      exchange.headers,
      exchange.body,
      exchange.timeout_ms,
    )
    |> result.map_error(transport_error(
      _,
      types.Connecting,
      exchange.timeout_ms,
    )),
  )
  use <- transport.with_connection(connection)
  use first <- result.try(receive(connection, wait, types.AwaitingHeaders))
  case first {
    transport.Headers(status, headers, final) -> {
      use _ <- result.try(notify([types.Responded(status)], on_event))
      case status >= 200 && status < 300 {
        False -> http_error(connection, wait, status, final, [], 0)
        True ->
          case event_stream(headers) || !exchange.require_event_stream, final {
            False, _ -> http_error(connection, wait, status, final, [], 0)
            True, True -> Error(types.UnexpectedEnd)
            True, False ->
              pump(
                connection,
                wait,
                types.AwaitingFirstEvent,
                sse.new(exchange.max_event_bytes),
                reducer,
                Thinking(0, sent, None),
                on_event,
              )
          }
      }
    }
    _ -> Error(types.InvalidEvent("HTTP data arrived before headers"))
  }
}

/// `exchange` with every budget held to `cap` ms, when `cap` is positive.
fn capped(exchange: Exchange, cap: Int) -> Exchange {
  case cap > 0 {
    False -> exchange
    True ->
      Exchange(
        ..exchange,
        timeout_ms: int.min(exchange.timeout_ms, cap),
        first_event_timeout_ms: option.map(
          exchange.first_event_timeout_ms,
          int.min(_, cap),
        ),
      )
  }
}

fn validate_client(client: Client) -> Result(Nil, Error) {
  case
    client.timeout_ms <= 0 || client.max_event_bytes <= 0,
    string.contains(client.api_key, "\r")
    || string.contains(client.api_key, "\n")
    || string.contains(client.base_url, "?")
    || string.contains(client.base_url, "#")
  {
    True, _ ->
      Error(types.InvalidRequest("timeouts and event limits must be positive"))
    _, True -> Error(types.InvalidRequest("invalid API key or base URL"))
    _, _ -> Ok(Nil)
  }
}

fn validate_policy(
  policy: types.ProviderPolicy,
  model: String,
) -> Result(Nil, Error) {
  case policy {
    types.OpenAI -> Ok(Nil)
    types.OpenCodeGo(session_id, org_id) ->
      case
        string.trim(session_id) == ""
        || unsafe_header(session_id)
        || unsafe_header(org_id)
      {
        True ->
          Error(types.InvalidRequest("invalid OpenCode Go session identity"))
        False -> Ok(Nil)
      }
    types.Codex(account_id, session_id) ->
      case
        unsafe_header(model)
        || list.any([account_id, session_id], fn(id) {
          string.trim(id) == "" || unsafe_header(id)
        })
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
  wait: Wait,
  phase: types.TimeoutPhase,
  parser: sse.Parser,
  state: reducer.Reducer,
  thinking: Thinking,
  on_event: fn(Event) -> Control,
) -> Result(Turn, Error) {
  use message <- result.try(receive(connection, wait, phase))
  case message {
    transport.Data(bytes, final) -> {
      let now = clock.monotonic_ms()
      use #(parser, events) <- result.try(
        sse.feed(parser, bytes) |> result.map_error(sse_error),
      )
      let phase = case events {
        [] -> phase
        _ -> types.Streaming
      }
      use #(state, thinking, turn) <- result.try(deliver(
        state,
        thinking,
        now,
        events,
        on_event,
      ))
      case turn, final {
        Some(turn), _ -> Ok(timed(turn, thinking, now))
        None, True -> {
          use events <- result.try(
            sse.finish(parser) |> result.map_error(sse_error),
          )
          use #(state, thinking, turn) <- result.try(deliver(
            state,
            thinking,
            now,
            events,
            on_event,
          ))
          case turn {
            Some(turn) -> Ok(turn)
            None -> state.finish()
          }
          |> result.map(timed(_, thinking, now))
        }
        None, False ->
          pump(connection, wait, phase, parser, state, thinking, on_event)
      }
    }
    _ -> Error(types.InvalidEvent("unexpected HTTP headers inside stream"))
  }
}

fn deliver(
  state: reducer.Reducer,
  thinking: Thinking,
  now: Int,
  events: List(sse.Event),
  on_event: fn(Event) -> Control,
) -> Result(#(reducer.Reducer, Thinking, Option(Turn)), Error) {
  case events {
    [] -> Ok(#(state, thinking, None))
    [event, ..rest] -> {
      use #(state, updates, turn) <- result.try(state.feed(event.data))
      use _ <- result.try(notify(updates, on_event))
      let thinking = list.fold(updates, thinking, fn(t, e) { think(t, e, now) })
      case turn {
        Some(_) -> Ok(#(state, thinking, turn))
        None -> deliver(state, thinking, now, rest, on_event)
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

/// Time spent thinking so far, when the last other event came (the request
/// itself, at first), and when the spell under way began.
type Thinking {
  Thinking(total: Int, last: Int, since: Option(Int))
}

/// A spell runs from the event before its first thinking delta to the next
/// other event: summarized thinking streams only once it is written, so the
/// thought began before its first delta did.
fn think(thinking: Thinking, event: Event, now: Int) -> Thinking {
  case event, thinking.since {
    types.ThinkingDelta(_), None ->
      Thinking(..thinking, since: Some(thinking.last))
    types.ThinkingDelta(_), Some(_) -> thinking
    _, Some(_) -> Thinking(elapsed(thinking, now), now, None)
    _, None -> Thinking(..thinking, last: now)
  }
}

/// A turn that ends while it is still thinking thought until its end.
fn timed(turn: Turn, thinking: Thinking, now: Int) -> Turn {
  case elapsed(thinking, now) {
    0 -> turn
    total -> types.Turn(..turn, thought_ms: Some(total))
  }
}

/// Thinking time so far, closing the spell under way if there is one.
fn elapsed(thinking: Thinking, now: Int) -> Int {
  case thinking.since {
    Some(since) -> thinking.total + now - since
    None -> thinking.total
  }
}

/// The next message, within what is left of the first-event deadline while
/// one runs, else within the idle budget until the first event. Once events
/// flow, a body chunk waits while the connection is alive.
fn receive(
  connection: transport.Connection,
  wait: Wait,
  phase: types.TimeoutPhase,
) -> Result(transport.Message, Error) {
  case wait.first_event, phase {
    Some(#(deadline, total)), types.AwaitingHeaders
    | Some(#(deadline, total)), types.AwaitingFirstEvent
    ->
      transport.receive_within(
        connection,
        int.max(1, deadline - clock.monotonic_ms()),
      )
      |> result.map_error(transport_error(_, phase, total))
    _, types.Streaming ->
      transport.receive(connection)
      |> result.map_error(transport_error(_, phase, wait.idle_ms))
    _, _ ->
      transport.receive_within(connection, wait.idle_ms)
      |> result.map_error(transport_error(_, phase, wait.idle_ms))
  }
}

fn transport_error(
  error: transport.Error,
  phase: types.TimeoutPhase,
  waited_ms: Int,
) -> Error {
  case error {
    transport.InvalidUrl -> types.InvalidRequest("invalid HTTP endpoint")
    transport.TransportError(message) -> types.ConnectionError(message)
    transport.TimedOut -> types.Timeout(phase, waited_ms)
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
  wait: Wait,
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
      use message <- result.try(receive(
        connection,
        wait,
        types.AwaitingFirstEvent,
      ))
      case message {
        transport.Data(bytes, final) -> {
          let remaining = 65_536 - size
          let bytes = case bit_array.byte_size(bytes) > remaining {
            True -> bit_array.slice(bytes, 0, remaining) |> result.unwrap(<<>>)
            False -> bytes
          }
          http_error(
            connection,
            wait,
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
