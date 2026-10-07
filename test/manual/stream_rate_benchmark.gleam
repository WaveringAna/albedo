//// Run explicitly with: gleam run -m manual/stream_rate_benchmark
//// Streams from test/manual/mock_openai_server.py (start it first; its origin
//// from ALBEDO_BENCH_ORIGIN, default http://127.0.0.1:8765, and for https the
//// CA to trust from ALBEDO_BENCH_CA) through the real transport and reducers,
//// and prints VM CPU and reductions per token and send-to-callback latency.
//// Run with the daemon's ERL_FLAGS (the vm_defaults in
//// priv/bin/albedo-daemon: two schedulers, no busy waiting), so scheduler
//// spinning does not count as work.
////
//// By default each protocol streams 2000 deltas at 500 per second, then
//// 20000 unthrottled (ALBEDO_BENCH_UNTHROTTLED=0 skips those).
//// ALBEDO_BENCH_PARALLEL=N instead streams N at once, each at
//// ALBEDO_BENCH_RATE (default 1000) per second for four seconds.
//// ALBEDO_BENCH_PROTOCOL=responses|chat_completions|claude|vertex|antigravity
//// runs one protocol, ALBEDO_BENCH_TOOLS=P streams P percent of the deltas as tool
//// call arguments, and ALBEDO_BENCH_MSACC=1 prints microstate accounting.

import albedo/harness/extensions/antigravity/catalog
import albedo/harness/extensions/antigravity/stream as antigravity
import albedo/harness/extensions/claude/stream as claude
import albedo/harness/extensions/vertex/stream as vertex
import albedo/openai_api as openai
import albedo/openai_api/types
import gleam/float
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import gleam/string_tree

@external(erlang, "albedo_openai_rate_bench", "env")
fn env(name: String, default: String) -> String

@external(erlang, "albedo_openai_rate_bench", "token")
fn token() -> Nil

@external(erlang, "albedo_openai_rate_bench", "trust")
fn trust(ca_file: String) -> Nil

@external(erlang, "albedo_openai_rate_bench", "measure")
fn measure(
  origin: String,
  runs: List(#(String, fn() -> Result(types.Turn, types.Error))),
) -> #(List(Result(types.Turn, types.Error)), List(#(String, Float)))

const runs = 3

type Protocol {
  OpenAI(types.Protocol)
  Claude
  Vertex
  Antigravity
}

pub fn main() -> Nil {
  let origin = env("ALBEDO_BENCH_ORIGIN", "http://127.0.0.1:8765")
  trust(env("ALBEDO_BENCH_CA", ""))
  let only = env("ALBEDO_BENCH_PROTOCOL", "")
  let assert Ok(tools) = int.parse(env("ALBEDO_BENCH_TOOLS", "0"))
  let assert Ok(parallel) = int.parse(env("ALBEDO_BENCH_PARALLEL", "0"))
  let assert Ok(rate) = int.parse(env("ALBEDO_BENCH_RATE", "1000"))
  let unthrottled = env("ALBEDO_BENCH_UNTHROTTLED", "1") == "1"
  [
    OpenAI(types.Responses),
    OpenAI(types.ChatCompletions),
    Claude,
    Vertex,
    Antigravity,
  ]
  |> list.filter(fn(protocol) { only == "" || only == name(protocol) })
  |> list.each(fn(protocol) {
    case parallel, unthrottled {
      0, True -> {
        bench(origin, protocol, tools, 1, 500, 2000)
        bench(origin, protocol, tools, 1, 0, 20_000)
      }
      0, False -> bench(origin, protocol, tools, 1, 500, 2000)
      streams, _ -> bench(origin, protocol, tools, streams, rate, rate * 4)
    }
  })
}

fn name(protocol: Protocol) -> String {
  case protocol {
    OpenAI(protocol) -> types.protocol_name(protocol)
    Claude -> "claude"
    Vertex -> "vertex"
    Antigravity -> "antigravity"
  }
}

fn bench(
  origin: String,
  protocol: Protocol,
  tools: Int,
  streams: Int,
  rate: Int,
  tokens: Int,
) -> Nil {
  let runs_once =
    int.range(0, streams, [], list.prepend)
    |> list.map(fn(i) {
      let id = int.to_string(i)
      let base =
        string.join(
          [
            origin,
            int.to_string(rate),
            int.to_string(tokens),
            "t" <> int.to_string(tools),
            "s" <> id,
            "v1",
          ],
          "/",
        )
      #(id, fn() { stream(protocol, base) })
    })
  // one warm-up run loads modules and opens the connections the runs reuse
  let _ = measure(origin, runs_once)
  let results =
    list.repeat(Nil, runs) |> list.map(fn(_) { measure(origin, runs_once) })
  let label =
    name(protocol)
    <> case tools {
      0 -> ""
      _ -> " (" <> int.to_string(tools) <> "% tool args)"
    }
    <> case streams {
      1 -> ""
      _ -> " " <> int.to_string(streams) <> " streams"
    }
    <> " @ "
    <> case rate {
      0 -> "unthrottled"
      _ -> int.to_string(rate) <> " tok/s"
    }
  let failure =
    list.flat_map(results, fn(run) { run.0 }) |> list.find(result.is_error)
  case failure {
    Ok(Error(error)) -> io.println(label <> ": " <> string.inspect(error))
    _ -> io.println(label <> " " <> median(list.map(results, fn(r) { r.1 })))
  }
}

fn stream(protocol: Protocol, base: String) -> Result(types.Turn, types.Error) {
  let on_event = fn(event) {
    case event {
      types.ArgumentsDelta(_, _, "") -> Nil
      types.TextDelta(..) | types.ArgumentsDelta(..) -> token()
      _ -> Nil
    }
    types.Continue
  }
  case protocol {
    OpenAI(protocol) ->
      openai.stream(
        openai.client(protocol, base, ""),
        openai.request("mock", [types.User("go")]),
        on_event,
      )
    Claude ->
      openai.exchange(
        exchange(base <> "/messages"),
        claude.reducer("mock", []),
        on_event,
      )
    Vertex ->
      openai.exchange(exchange(base <> "/vertex"), vertex.reducer(), on_event)
    Antigravity -> {
      let model = catalog.model("/nonexistent", "gemini-3-pro", None)
      openai.exchange(
        exchange(base <> "/antigravity"),
        antigravity.reducer(model),
        on_event,
      )
    }
  }
}

fn exchange(url: String) -> openai.Exchange {
  openai.Exchange(
    url,
    [#("content-type", "application/json")],
    string_tree.from_string("{}"),
    60_000,
    8 * 1024 * 1024,
    require_event_stream: True,
  )
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
