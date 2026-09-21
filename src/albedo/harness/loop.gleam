//// Model → tools → model. The session owns cancellation and durable commits.

import albedo/daemon/events as view
import albedo/daemon/usage
import albedo/harness/runtime
import albedo/openai_api as openai
import albedo/openai_api/types
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string

pub type Loop {
  Loop(
    model: String,
    host: runtime.Runtime,
    kernel: runtime.Session,
    client: types.Client,
    publish: fn(String) -> Bool,
    commit: fn(List(types.Input), String) -> Result(Int, String),
    record_usage: fn(usage.Metadata) -> Result(Nil, String),
  )
}

pub fn run(
  state: Loop,
  id: String,
  inputs: List(types.Input),
  step: Int,
) -> Result(Nil, String) {
  use _ <- result.try(case state.publish(view.event("checkpoint", [])) {
    True -> Ok(Nil)
    False -> Error("cancelled")
  })
  let request =
    types.Request(
      state.model,
      Some(instructions <> "\n" <> runtime.instructions(state.host)),
      list.reverse(inputs),
      runtime.tools(state.host),
      None,
    )
  use turn <- result.try(
    openai.stream(state.client, request, fn(event) {
      let event = case event {
        types.TextDelta(_, _, text) -> view.text("text", text)
        types.ThinkingDelta(text) -> view.text("thinking", text)
        types.ArgumentsDelta(index, text) ->
          view.event("arguments_delta", [
            #(
              "callId",
              json.string(
                id <> ":" <> int.to_string(step) <> ":" <> int.to_string(index),
              ),
            ),
            #("text", json.string(text)),
          ])
        types.Started(_) -> view.event("turn_started", [])
      }
      case state.publish(event) {
        True -> types.Continue
        False -> types.Stop
      }
    })
    |> result.map_error(fn(error) { string.inspect(error) }),
  )
  let completed_usage =
    usage.from_completion(state.model, turn.usage, usage.now())
  let replay = list.map(turn.output, types.Replay)
  use timestamp <- result.try(
    state.commit(replay, case turn.tool_calls {
      [] -> "idle"
      _ -> "tool"
    }),
  )
  list.each(replay, fn(input) {
    view.assistant_message(input, Some(timestamp))
    |> list.each(fn(event) {
      let _ = state.publish(event)
      Nil
    })
  })
  use _ <- result.try(state.record_usage(completed_usage))
  let _ = state.publish(usage.event(completed_usage))
  case turn.tool_calls {
    [] ->
      case turn.finish {
        types.Complete -> Ok(Nil)
        _ -> Error("model stopped: " <> string.inspect(turn.finish))
      }
    calls -> {
      use results <- result.try(
        list.try_map(calls, fn(call) {
          case state.publish(view.progress(call.id, call.name, "running")) {
            False -> Error("cancelled before tool execution")
            True -> {
              use output <- result.try(runtime.invoke(
                state.host,
                state.kernel,
                call,
              ))
              use _ <- result.try(state.commit([output], "tool"))
              let _ = case output {
                types.ToolOutput(_, body) ->
                  state.publish(view.tool(
                    runtime.ledger(state.host),
                    call,
                    body,
                  ))
                _ -> True
              }
              Ok(output)
            }
          }
        }),
      )
      use _ <- result.try(state.commit([], "model"))
      run(
        state,
        id,
        list.append(
          list.reverse(results),
          list.append(list.reverse(replay), inputs),
        ),
        step + 1,
      )
    }
  }
}

const instructions = "You are a coding agent working in the session workspace. Use the python tool: one persistent namespace, top-level await, normal Python libraries. Keep large values in variables and inspect slices. cells.read and cells.run repair saved cells by exact replacements; never blindly retry a cell that started. Run tests and report real results. Client disconnection does not stop your session."
