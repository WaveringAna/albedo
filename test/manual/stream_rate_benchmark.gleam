//// Run explicitly with: gleam run -m manual/stream_rate_benchmark
//// Streams from test/manual/mock_openai_server.py (start it first; its origin
//// from ALBEDO_BENCH_ORIGIN, default http://127.0.0.1:8765, and for https the
//// CA to trust from ALBEDO_BENCH_CA) through the real transport, at 500
//// tokens/s and unthrottled, and prints VM CPU and reductions per token and
//// send-to-callback latency. Run with the daemon's ERL_FLAGS (the
//// vm_defaults in priv/bin/albedo-daemon: two schedulers, no busy waiting),
//// so scheduler spinning does not count as work.
//// ALBEDO_BENCH_PROTOCOL=responses|chat_completions runs one protocol,
//// ALBEDO_BENCH_UNTHROTTLED=0 skips the unthrottled run, and
//// ALBEDO_BENCH_MSACC=1 prints each run's microstate accounting.

import albedo/openai_api as openai
import albedo/openai_api/types
import gleam/float
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/result
import gleam/string

@external(erlang, "albedo_openai_rate_bench", "env")
fn env(name: String, default: String) -> String

@external(erlang, "albedo_openai_rate_bench", "token")
fn token() -> Nil

@external(erlang, "albedo_openai_rate_bench", "trust")
fn trust(ca_file: String) -> Nil

@external(erlang, "albedo_openai_rate_bench", "measure")
fn measure(
  origin: String,
  tokens: Int,
  run: fn() -> Result(types.Turn, types.Error),
) -> #(Result(types.Turn, types.Error), List(#(String, Float)))

const runs = 3

pub fn main() -> Nil {
  let origin = env("ALBEDO_BENCH_ORIGIN", "http://127.0.0.1:8765")
  trust(env("ALBEDO_BENCH_CA", ""))
  let only = env("ALBEDO_BENCH_PROTOCOL", "")
  let unthrottled = env("ALBEDO_BENCH_UNTHROTTLED", "1") == "1"
  [types.Responses, types.ChatCompletions]
  |> list.filter(fn(protocol) {
    only == "" || only == types.protocol_name(protocol)
  })
  |> list.each(fn(protocol) {
    bench(origin, protocol, 500, 2000)
    case unthrottled {
      True -> bench(origin, protocol, 0, 20_000)
      False -> Nil
    }
  })
}

fn bench(
  origin: String,
  protocol: types.Protocol,
  rate: Int,
  tokens: Int,
) -> Nil {
  let base =
    origin
    <> "/"
    <> int.to_string(rate)
    <> "/"
    <> int.to_string(tokens)
    <> "/v1"
  let client = openai.client(protocol, base, "")
  let request = openai.request("mock", [types.User("go")])
  // one warm-up run loads modules and opens the connection the runs reuse
  let _ = measure(origin, tokens, fn() { stream(client, request) })
  let results =
    list.repeat(Nil, runs)
    |> list.map(fn(_) {
      measure(origin, tokens, fn() { stream(client, request) })
    })
  let label =
    types.protocol_name(protocol)
    <> " @ "
    <> case rate {
      0 -> "unthrottled"
      _ -> int.to_string(rate) <> " tok/s"
    }
  case list.find(results, fn(run) { result.is_error(run.0) }) {
    Ok(#(Error(error), _)) -> io.println(label <> ": " <> string.inspect(error))
    _ -> io.println(label <> " " <> median(list.map(results, fn(r) { r.1 })))
  }
}

fn stream(
  client: types.Client,
  request: types.Request,
) -> Result(types.Turn, types.Error) {
  openai.stream(client, request, fn(event) {
    case event {
      types.TextDelta(..) -> token()
      _ -> Nil
    }
    types.Continue
  })
}

/// Each metric's median across runs, as one JSON object.
fn median(runs: List(List(#(String, Float)))) -> String {
  let assert [first, ..] = runs
  list.map(first, fn(metric) {
    let values =
      list.filter_map(runs, fn(run) { list.key_find(run, metric.0) })
      |> list.sort(float.compare)
    let assert Ok(middle) =
      list.drop(values, list.length(values) / 2) |> list.first
    #(metric.0, json.float(float.to_precision(middle, 2)))
  })
  |> json.object
  |> json.to_string
}
