//// The single model-facing tool. Host capabilities are ordinary Python functions.

import albedo/harness/extension
import albedo/harness/python/cells as journal
import albedo/harness/python/kernel as python
import albedo/harness/python/rpc as cells
import albedo/openai_api/types
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result

pub fn definition() -> types.Tool {
  types.Tool(
    "python",
    "Execute Python in your persistent session. Top-level await works. Variables stay alive. Only printed output and the final expression return; truncated=true means the output passed the 64 KiB preview, and the rest is readable with output.read(cell_id, offset=65536). Failed cells are retained: await cells.read(id) for bounded source, await cells.info(id) for status without source, await cells.trace(id) for what the cell read, ran and changed. Repair exact unique text without resending the source with await cells.run(id, replacements=[(old,new)]), or pass check=True first to compile the rewrite and get the syntax error back without running anything. A cell that started requires allow_partial=True after checking side effects; never retry blindly.",
    json.object([
      #("type", json.string("object")),
      #("additionalProperties", json.bool(False)),
      #("required", json.array(["code", "timeout_ms"], json.string)),
      #(
        "properties",
        json.object([
          #("code", json.object([#("type", json.string("string"))])),
          #(
            "timeout_ms",
            json.object([
              #("type", json.string("integer")),
              #("minimum", json.int(1)),
              #("maximum", json.int(3_600_000)),
            ]),
          ),
        ]),
      ),
    ]),
    True,
  )
}

/// Storage failure stops the harness rather than encouraging an unsafe tool retry.
pub fn invoke(
  context: extension.Context,
  arguments: String,
) -> Result(String, String) {
  let decoder = {
    use code <- decode.field("code", decode.string)
    use timeout <- decode.field("timeout_ms", decode.int)
    decode.success(#(code, timeout))
  }
  case json.parse(arguments, decoder) {
    Ok(#(code, timeout)) -> {
      use id <- result.try(journal.begin_call(
        context.store,
        context.session,
        context.call_id,
        code,
      ))
      let outcome = python.execute_saved(context.kernel, id, code, timeout)
      use _ <- result.try(journal.finish(context.store, id, outcome))
      let _ =
        list.try_each(python.events(context.kernel), fn(event) {
          let decoder = {
            use kind <- decode.field("type", decode.string)
            use id <- decode.field("id", decode.string)
            use trace <- decode.field("trace", decode.dynamic)
            decode.success(#(kind, id, trace))
          }
          case json.parse(event, decoder) {
            Ok(#("trace", id, trace)) ->
              journal.save_trace(context.store, id, trace)
            _ -> Ok(Nil)
          }
        })
      let body = outcome_json(id, outcome)
      Ok(json.to_string(body))
    }
    Error(_) -> Ok("{\"error\":\"expected code and timeout_ms\"}")
  }
}

pub fn extension() -> extension.Extension {
  extension.Extension(
    "python",
    "A persistent Python namespace with saved cell recovery.",
    [],
    [
      extension.ToolPlugin(
        "Python has a persistent namespace, top-level await, cells.read/info/trace and cells.run for saved-source repair, and output.read/output.list for bounded retained output. output.list() names every retained channel: cells, background jobs, and 'native' for bytes written to fd 1/2 while no cell was running.",
        [extension.Tool(definition(), invoke, recover)],
        [],
        [#("cells", cells.handle)],
      ),
    ],
    journal.initialise,
  )
}

pub fn plugin() -> extension.Extension {
  extension()
}

fn outcome_json(
  id: String,
  outcome: Result(python.Outcome, python.Error),
) -> json.Json {
  case outcome {
    Ok(outcome) ->
      json.object([
        #("cell_id", json.string(id)),
        #(
          "status",
          json.string(case outcome.status {
            python.Succeeded -> "ok"
            python.Failed -> "error"
            python.Interrupted -> "interrupted"
          }),
        ),
        #("output", json.string(outcome.output)),
        #("value", json.string(outcome.value)),
        #("truncated", json.bool(outcome.truncated)),
      ])
    Error(error) ->
      json.object([
        #("cell_id", json.string(id)),
        #(
          "error",
          json.string(case error {
            python.Busy -> "session is already executing a cell"
            python.Lost ->
              "kernel lost; namespace unavailable; inspect side effects before resetting"
            python.Unavailable(message) | python.Invalid(message) -> message
          }),
        ),
      ])
  }
}

fn recover(context: extension.Context) {
  let id = context.session <> "/" <> context.call_id
  let outcome = case journal.get(context.store, id) {
    Ok(cell) ->
      case cell.outcome {
        Some(outcome) -> Some(outcome_json(id, outcome))
        None -> None
      }
    Error(_) -> None
  }
  Some(case outcome {
    Some(value) -> json.to_string(value)
    None ->
      json.object([
        #("cell_id", json.string(id)),
        #(
          "error",
          json.string(
            "interrupted; outcome unknown. Inspect saved cell and side effects before retrying.",
          ),
        ),
      ])
      |> json.to_string
  })
}
