//// provide-usage as a stateless one-shot CLI, driven from Erlang. The core
//// (usage-core, Zig) decides which requests to send and nothing else: each
//// round is one fresh `usage advance -` process fed the whole history on
//// stdin, so a credential never reaches argv, and every byte of I/O is
//// albedo's - `http` requests through albedo's HTTP client, `command`
//// requests through a PATH, HOME, locale, timezone and proxy environment
//// with a timeout and a stdout cap. The round loop lives here and the I/O
//// lives in albedo_usage_core, so neither half can drift from the other.
////
//// `Error` from `fetch` means the driver itself failed: the binary is
//// missing, its output is unparseable, or the feed did not finish in
//// `max_rounds` rounds. A provider failure (a 4xx, an unknown provider, a
//// flaky CLI) is data: it comes back as `Ok(Report(error: Some(..)))`.

import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub type Limit {
  Limit(
    id: String,
    label: String,
    used_percent: Option(Float),
    window_label: Option(String),
    window_seconds: Option(Int),
    resets_at: Option(Int),
    scope: Option(String),
    status: String,
  )
}

pub type Report {
  Report(
    account_id: Option(String),
    email: Option(String),
    plan: Option(String),
    limits: List(Limit),
    error: Option(String),
  )
}

/// A feed that needs more round trips than this is stuck, not slow: the
/// deepest feed today (hyper) is three rounds.
const max_rounds = 6

@external(erlang, "albedo_usage_core", "advance")
fn advance(envelope: String) -> Result(String, String)

@external(erlang, "albedo_usage_core", "http_request")
fn http_request(
  method: String,
  url: String,
  headers: List(#(String, String)),
  body: Option(String),
) -> #(Int, String)

@external(erlang, "albedo_usage_core", "run_command")
fn run_command(
  command: String,
  args: List(String),
  stdin: Option(String),
  timeout_ms: Option(Int),
) -> #(Int, String)

/// Runs a provider's feed to completion. Each round is one `usage advance -`
/// process fed one envelope line on stdin (never argv: it carries the
/// credential); `http` requests go through albedo's HTTP client, `command`
/// requests (alibaba's `bl`) run with only PATH, HOME, locale, timezone and
/// proxy variables, a timeout, and a stdout cap.
pub fn fetch(
  provider: String,
  credential: json.Json,
  now_ms: Int,
) -> Result(Report, String) {
  loop(provider, credential, now_ms, [])
}

/// `rounds` is the whole history so far, one entry per answered round, so
/// every `usage advance -` process replays the feed from scratch and the core
/// stays stateless: the host keeps the state, the core keeps the rules.
fn loop(
  provider: String,
  credential: json.Json,
  now_ms: Int,
  rounds: List(json.Json),
) -> Result(Report, String) {
  case list.length(rounds) >= max_rounds {
    True ->
      Error(
        "usage feed for "
        <> provider
        <> " did not finish in "
        <> int.to_string(max_rounds)
        <> " rounds",
      )
    False -> {
      let envelope =
        json.object([
          #("provider", json.string(provider)),
          #("credential", credential),
          #("responses", json.array(rounds, fn(round) { round })),
          #("nowMs", json.int(now_ms)),
        ])
        |> json.to_string
      use output <- result.try(advance(envelope))
      use step <- result.try(step(output))
      case step {
        Reported(report) -> Ok(report)
        // The core answers an unknown provider (or its own parse failure)
        // with an error step, which is still the provider's answer, not a
        // driver failure.
        Failed(message) -> Ok(Report(None, None, None, [], Some(message)))
        Requests(requests) -> {
          let round =
            json.array(list.map(requests, answer), fn(response) { response })
          loop(provider, credential, now_ms, list.append(rounds, [round]))
        }
      }
    }
  }
}

fn answer(request: Request) -> json.Json {
  // A transport failure or a command that could not run is already folded
  // into the status by the Erlang half, so both request kinds answer the
  // same way: one `{"status", "body"}` object per request.
  let #(status, body) = case request {
    HttpRequest(method, url, headers, body) ->
      http_request(method, url, headers, body)
    CommandRequest(command, args, stdin, timeout_ms) ->
      run_command(command, args, stdin, timeout_ms)
  }
  json.object([
    #("status", json.int(status)),
    #("body", json.string(body)),
  ])
}

/// One step is printed per replayed round; the last line is the answer.
fn step(output: String) -> Result(Step, String) {
  let last =
    output
    |> string.split("\n")
    |> list.map(string.trim)
    |> list.filter(fn(line) { line != "" })
    |> list.last
  case last {
    Error(Nil) -> Error("the usage CLI printed no step")
    Ok(last) ->
      json.parse(last, step_decoder())
      |> result.replace_error("the usage CLI printed an unparseable step")
  }
}

type Request {
  HttpRequest(
    method: String,
    url: String,
    headers: List(#(String, String)),
    body: Option(String),
  )
  CommandRequest(
    command: String,
    args: List(String),
    stdin: Option(String),
    timeout_ms: Option(Int),
  )
}

type Step {
  Requests(List(Request))
  Reported(Report)
  Failed(String)
}

fn step_decoder() -> decode.Decoder(Step) {
  decode.one_of(
    decode.field("report", report_decoder(), fn(report) {
      decode.success(Reported(report))
    }),
    or: [
      decode.field("requests", decode.list(request_decoder()), fn(requests) {
        decode.success(Requests(requests))
      }),
      decode.field("error", decode.string, fn(message) {
        decode.success(Failed(message))
      }),
    ],
  )
}

fn request_decoder() -> decode.Decoder(Request) {
  use kind <- decode.field("kind", decode.string)
  case kind {
    "command" -> command_decoder()
    _ -> http_decoder()
  }
}

fn command_decoder() -> decode.Decoder(Request) {
  use command <- decode.field("command", decode.string)
  use args <- decode.optional_field("args", [], decode.list(decode.string))
  use stdin <- decode.optional_field("stdin", None, optional_string())
  use timeout_ms <- decode.optional_field("timeoutMs", None, optional_int())
  decode.success(CommandRequest(command, args, stdin, timeout_ms))
}

fn http_decoder() -> decode.Decoder(Request) {
  use method <- decode.optional_field("method", "GET", decode.string)
  use url <- decode.field("url", decode.string)
  use headers <- decode.optional_field("headers", [], decode.list(pair()))
  use body <- decode.optional_field("body", None, optional_string())
  decode.success(HttpRequest(method, url, headers, body))
}

fn report_decoder() -> decode.Decoder(Report) {
  use account_id <- decode.optional_field("accountId", None, optional_string())
  use email <- decode.optional_field("email", None, optional_string())
  use plan <- decode.optional_field("planType", None, optional_string())
  use limits <- decode.optional_field(
    "limits",
    [],
    decode.list(limit_decoder()),
  )
  use error <- decode.optional_field("error", None, optional_string())
  decode.success(Report(account_id, email, plan, limits, error))
}

fn limit_decoder() -> decode.Decoder(Limit) {
  use id <- decode.field("id", decode.string)
  use label <- decode.field("label", decode.string)
  use used_percent <- decode.optional_field(
    "usedPercent",
    None,
    optional_float(),
  )
  use window_label <- decode.optional_field(
    "windowLabel",
    None,
    optional_string(),
  )
  use window_seconds <- decode.optional_field(
    "windowSeconds",
    None,
    optional_int(),
  )
  use resets_at <- decode.optional_field("resetsAt", None, optional_int())
  use scope <- decode.optional_field("scope", None, optional_string())
  use status <- decode.field("status", decode.string)
  decode.success(Limit(
    id,
    label,
    used_percent,
    window_label,
    window_seconds,
    resets_at,
    scope,
    status,
  ))
}

fn optional_string() -> decode.Decoder(Option(String)) {
  decode.optional(decode.string)
}

fn optional_int() -> decode.Decoder(Option(Int)) {
  decode.optional(decode.int)
}

/// The core clamps percentages but emits whole numbers without a decimal
/// point, which arrive as integers; a percentage is a float either way.
fn optional_float() -> decode.Decoder(Option(Float)) {
  decode.optional(
    decode.one_of(decode.float, or: [
      decode.map(decode.int, int.to_float),
    ]),
  )
}

fn pair() -> decode.Decoder(#(String, String)) {
  decode.then(decode.list(decode.string), fn(parts) {
    case parts {
      [name, value] -> decode.success(#(name, value))
      _ -> decode.failure(#("", ""), "a two-element header pair")
    }
  })
}
