//// Run explicitly with: gleam run -m manual/benchmark
//// ALBEDO_BENCH_URL, ALBEDO_BENCH_MODEL, ALBEDO_BENCH_KEY are environment variables.
//// Makes at most three requests per protocol; stops a protocol on its first error.

import albedo/openai_api as openai
import albedo/openai_api/types
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

pub type Metrics {
  Metrics(
    elapsed_ms: Float,
    first_text_ms: Option(Float),
    text_bytes: Int,
    chunks: Int,
    peak_process_bytes: Int,
    peak_vm_binary_growth_bytes: Int,
    reductions: Int,
  )
}

@external(erlang, "albedo_openai_bench", "env")
fn env(name: String) -> String

@external(erlang, "albedo_openai_bench", "measure")
fn measure(run: fn() -> a) -> #(a, Metrics)

@external(erlang, "albedo_openai_bench", "text")
fn text(bytes: Int) -> Nil

pub fn main() -> Nil {
  let key = env("ALBEDO_BENCH_KEY")
  let url = env("ALBEDO_BENCH_URL")
  let model = env("ALBEDO_BENCH_MODEL")
  case key == "" || url == "" || model == "" {
    True ->
      io.println("missing benchmark environment variables; no requests made")
    False -> {
      let protocols = case env("ALBEDO_BENCH_PROTOCOL") {
        "responses" -> [types.Responses]
        "chat_completions" -> [types.ChatCompletions]
        _ -> [types.Responses, types.ChatCompletions]
      }
      list.each(protocols, fn(protocol) {
        run(openai.client(protocol, url, key), model, 1)
      })
    }
  }
}

fn run(client: types.Client, model: String, iteration: Int) -> Nil {
  let client = types.Client(..client, timeout_ms: 90_000)
  let request =
    openai.request(model, [
      types.User(
        "Write the integers from 1 through 80, separated by spaces. Do not include any other text.",
      ),
    ])
  let request = types.Request(..request, max_output_tokens: Some(256))
  let #(result, metrics) =
    measure(fn() {
      openai.stream(client, request, fn(event) {
        case event {
          types.TextDelta(_, _, value) -> text(string.byte_size(value))
          _ -> Nil
        }
        types.Continue
      })
    })
  let protocol = case client.protocol {
    types.Responses -> "responses"
    types.ChatCompletions -> "chat_completions"
  }
  let fields = [
    #("protocol", json.string(protocol)),
    #("iteration", json.int(iteration)),
    #("elapsed_ms", json.float(metrics.elapsed_ms)),
    #("first_text_ms", json.nullable(metrics.first_text_ms, json.float)),
    #("text_bytes", json.int(metrics.text_bytes)),
    #("text_chunks", json.int(metrics.chunks)),
    #("sampled_peak_process_bytes", json.int(metrics.peak_process_bytes)),
    #(
      "sampled_peak_vm_binary_growth_bytes",
      json.int(metrics.peak_vm_binary_growth_bytes),
    ),
    #("worker_reductions", json.int(metrics.reductions)),
  ]
  let fields = case result {
    Ok(turn) -> [
      #("ok", json.bool(True)),
      #("finish", json.string(string.inspect(turn.finish))),
      #(
        "input_tokens",
        json.nullable(option_tokens(turn.usage, True), json.int),
      ),
      #(
        "output_tokens",
        json.nullable(option_tokens(turn.usage, False), json.int),
      ),
      ..fields
    ]
    Error(error) -> [
      #("ok", json.bool(False)),
      #(
        "error",
        json.string(
          string.inspect(error)
          |> string.replace(client.api_key, "[redacted]")
          |> string.slice(0, 2000),
        ),
      ),
      ..fields
    ]
  }
  fields |> json.object |> json.to_string |> io.println
  case result, iteration < 3 {
    Ok(_), True -> run(client, model, iteration + 1)
    _, _ -> Nil
  }
}

fn option_tokens(usage: Option(types.Usage), input: Bool) -> Option(Int) {
  case usage, input {
    None, _ -> None
    Some(usage), True -> Some(usage.input_tokens)
    Some(usage), False -> Some(usage.output_tokens)
  }
}
