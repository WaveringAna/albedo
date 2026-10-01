//// Opt-in live integration: gleam run -m manual/coding
//// Uses ALBEDO_BENCH_URL/MODEL/KEY and ALBEDO_LIVE_WORKSPACE/DATABASE/PROTOCOL.
//// No credentials are retained in the kernel environment or output.

import albedo/harness/extensions/work/ledger as work
import albedo/harness/runtime
import albedo/openai_api as openai
import albedo/openai_api/types
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/string

@external(erlang, "albedo_openai_bench", "env")
fn env(name: String) -> String

@external(erlang, "albedo_live_coding", "take_key")
fn take_key() -> String

@external(erlang, "albedo_live_coding", "now")
fn now() -> Int

@external(erlang, "albedo_live_coding", "with_runtime")
fn with_runtime(host: runtime.Runtime, run: fn() -> a) -> a

pub fn main() -> Nil {
  let key = take_key()
  let workspace = env("ALBEDO_LIVE_WORKSPACE")
  case
    key == ""
    || workspace == ""
    || env("ALBEDO_BENCH_URL") == ""
    || env("ALBEDO_BENCH_MODEL") == ""
    || env("ALBEDO_LIVE_DATABASE") == ""
  {
    True -> io.println("missing live-test environment; no requests made")
    False -> {
      let protocol = case env("ALBEDO_LIVE_PROTOCOL") {
        "chat_completions" -> types.ChatCompletions
        _ -> types.Responses
      }
      let client =
        types.Client(
          ..openai.client(protocol, env("ALBEDO_BENCH_URL"), key),
          timeout_ms: 90_000,
        )
      let assert Ok(host) = runtime.start(env("ALBEDO_LIVE_DATABASE"))
      use <- with_runtime(host)
      let assert Ok(session) = runtime.open_session(host, "coding", workspace)
      let request =
        types.Request(
          ..openai.request(env("ALBEDO_BENCH_MODEL"), [types.User(task)]),
          instructions: Some(instructions),
          tools: runtime.tools(session),
          max_output_tokens: Some(4096),
        )
      let start = now()
      let result = run(client, request, host, session, 1, 0)
      let ledger =
        work.list(runtime.ledger(host), workspace, 0, 50) |> result.unwrap([])
      log([
        #("event", json.string("summary")),
        #("elapsed_ms", json.int(now() - start)),
        #(
          "result",
          json.string(
            string.inspect(result) |> string.replace(key, "[redacted]"),
          ),
        ),
        #("ledger", json.array(ledger, work.to_json)),
      ])
      let assert Ok(_) = result
      Nil
    }
  }
}

fn run(
  client: types.Client,
  request: types.Request,
  host: runtime.Runtime,
  session: runtime.Session,
  step: Int,
  tools: Int,
) -> Result(#(Int, Int), String) {
  case step > 20 || tools > 30 {
    True -> Error("live test turn/tool limit reached")
    False -> {
      let start = now()
      use turn <- result.try(
        openai.stream(client, request, fn(_) { types.Continue })
        |> result.map_error(fn(error) {
          string.inspect(error) |> string.replace(client.api_key, "[redacted]")
        }),
      )
      log([
        #("event", json.string("model_turn")),
        #("step", json.int(step)),
        #("elapsed_ms", json.int(now() - start)),
        #("calls", json.int(list.length(turn.tool_calls))),
        #("finish", json.string(string.inspect(turn.finish))),
        #("usage", json.string(string.inspect(turn.usage))),
      ])
      case turn.tool_calls {
        [] -> {
          log([
            #("event", json.string("final")),
            #("output", json.array(turn.output, types.replay_json)),
          ])
          case turn.finish {
            types.Complete -> Ok(#(step, tools))
            _ -> Error("model stopped without completion")
          }
        }
        calls -> {
          use outputs <- result.try(
            list.try_map(calls, fn(call) {
              log([
                #("event", json.string("tool_call")),
                #("id", json.string(call.id)),
                #("arguments", json.string(call.arguments)),
              ])
              use output <- result.try(runtime.invoke(
                host,
                session,
                call,
                types.any_images,
              ))
              case output {
                types.ToolOutput(_, text, _) ->
                  log([
                    #("event", json.string("tool_result")),
                    #("body", json.string(text)),
                  ])
                _ -> Nil
              }
              Ok(output)
            }),
          )
          let input =
            list.append(
              request.input,
              list.append(list.map(turn.output, types.Replay), outputs),
            )
          run(
            client,
            types.Request(..request, input: input),
            host,
            session,
            step + 1,
            tools + list.length(calls),
          )
        }
      }
    }
  }
}

fn log(fields: List(#(String, json.Json))) -> Nil {
  fields |> json.object |> json.to_string |> io.println
}

const instructions = "You are testing albedo by solving a real coding task. Your only tool is python. Its namespace persists across calls, and top-level await is supported. Use pathlib for files. await work.create(title, notes=...) returns a dict with id and revision; await work.update(id, revision=..., status=...) uses optimistic revisions. These methods are coroutines: always await them, including when assigning their result. run(program, *args, timeout=seconds) starts a job without a shell; await its handle and print(job.tail()) to see results. Use cells.read/cells.run if a cell fails. Work only in your current workspace. Do not inspect credentials, environment variables, other directories, or network services. Do not modify any README. You must actually create files and run tests, not merely describe code. Use at least two python calls and retain a variable between calls. Once your tests pass, update the work item to done and finish with a brief account of what passed. Do not keep adding unrelated tests after success."

const task = "Implement interval_set.py using only the Python standard library. Public functions normalize(intervals), union(left, right), intersection(left, right), and difference(left, right) return canonical lists of (start, end) integer tuples for half-open intervals [start,end). Inputs may be unsorted, overlap, contain duplicates or empty intervals, and may be one-shot generators. Drop empty intervals; reject any reversed interval (start > end) with ValueError. Canonical output is sorted, nonempty, disjoint, and merges touching intervals. Do not mutate caller input. difference means left minus right. Do not enumerate integer points: endpoints can be arbitrarily large. Aim for sorting plus linear sweeps. Create a work item and mark it done only after tests pass. Write test_interval_set.py with edge cases and deterministic randomized checks, then execute it through bash from the python tool. Do not install dependencies. Keep the implementation readable."
