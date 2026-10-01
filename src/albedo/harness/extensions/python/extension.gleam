//// The single model-facing tool. Host capabilities are ordinary Python functions.

import albedo/harness/extension
import albedo/harness/extensions/python/cells as journal
import albedo/harness/extensions/python/kernel as python
import albedo/harness/extensions/python/migrations/cell_images
import albedo/harness/extensions/python/rpc as cells
import albedo/openai_api/types
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result

pub fn definition() -> types.Tool {
  types.Tool(
    "python",
    "Execute Python in your persistent session. Always provide both JSON arguments: code (string) and timeout_ms (integer, 1–3600000), even for a one-line call. Top-level await works. Variables stay alive. Only printed output and the final expression return; duration is the cell's wall seconds; truncated=true means the output passed the 64 KiB preview, and the rest (up to 1 MiB) is readable with output.read(cell_id, offset=65536) while the cell is among the 16 most recent; read it before running many more cells, or print less. Failed cells are retained: await cells.read(id) for bounded source, await cells.info(id) for its status (ok, error, interrupted, started, saved) without source, await cells.trace(id) for what the cell read, ran and changed. Repair exact unique text without resending the source with await cells.run(id, replacements=[(old,new)]), or pass check=True first to compile the rewrite and get the syntax error back without running anything. A cell that started requires allow_partial=True after checking side effects; never retry blindly.",
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

/// Storage failure is `Fatal` rather than a refusal: a cell whose source or
/// outcome went unrecorded must not be offered back to the model to retry.
pub fn invoke(
  context: extension.Context,
  arguments: String,
) -> Result(extension.Output, extension.Failure) {
  let decoder = {
    use code <- decode.field("code", decode.string)
    use timeout <- decode.field("timeout_ms", decode.int)
    decode.success(#(code, timeout))
  }
  case json.parse(arguments, decoder) {
    Ok(#(code, timeout)) -> {
      use id <- result.try(
        journal.begin_call(
          context.store,
          context.session,
          context.call_id,
          code,
        )
        |> result.map_error(extension.Fatal),
      )
      let outcome =
        python.execute_saved(context.kernel, id, code, timeout, context.images)
      use _ <- result.try(
        journal.finish(context.store, id, outcome)
        |> result.map_error(extension.Fatal),
      )
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
      Ok(outcome_output(id, outcome, context.images))
    }
    Error(_) ->
      Ok(extension.text("{\"error\":\"expected code and timeout_ms\"}"))
  }
}

pub fn extension() -> extension.Extension {
  extension.Extension(
    "python",
    "A persistent Python namespace with saved cell recovery.",
    [],
    [
      extension.MigrationPlugin(extension.DataMigration(
        "cell_images",
        cell_images.run,
      )),
      extension.ToolPlugin(
        "Python has a persistent namespace, top-level await, cells.read/info/trace and cells.run for saved-source repair (all async), and output.read/output.list for bounded retained output (synchronous; awaiting them also works). cells.last_id is the id of the latest cell, and await cells.list(limit=20) lists this session's cells newest first with their status and first line, even after their output has rolled out. output.read(id, offset=0, limit=4000) returns up to limit characters. output.list() names every retained channel, which is also how to find earlier cells: cells, background jobs, and 'native' for bytes written to fd 1/2 while no cell was running. show_image(source) returns a PNG, JPEG, or WebP (bytes or a file path) to you with this cell's result, so you see it after the cell ends; at most 4 images and 5 MiB per cell.",
        [extension.Tool(definition(), invoke, recover)],
        [],
        [#("cells", cells.handle)],
      ),
      extension.ManagedPlugin(fn(_, _, workspace) {
        Ok(
          extension.Managed(..extension.empty(), routes: [
            #("session", fn(_, _, request) { cells.session(workspace, request) }),
          ]),
        )
      }),
    ],
    journal.initialise,
  )
}

/// The cell's JSON result with its images beside it. An image the provider
/// would refuse stays back and is reported with the unreadable ones, so the
/// model can show a smaller one instead.
fn outcome_output(
  id: String,
  outcome: Result(python.Outcome, python.Error),
  limits: types.ImageLimits,
) -> extension.Output {
  let outcome =
    result.map(outcome, fn(outcome) {
      let #(images, refusals) =
        list.fold_right(outcome.images, #([], []), fn(kept, image) {
          case types.image_refusal(limits, image) {
            Some(reason) -> #(kept.0, [reason, ..kept.1])
            None -> #([image, ..kept.0], kept.1)
          }
        })
      python.Outcome(
        ..outcome,
        images: images,
        image_errors: list.append(outcome.image_errors, refusals),
      )
    })
  let images = case outcome {
    Ok(outcome) -> outcome.images
    Error(_) -> []
  }
  extension.Output(json.to_string(outcome_json(id, outcome)), images)
}

fn outcome_json(
  id: String,
  outcome: Result(python.Outcome, python.Error),
) -> json.Json {
  case outcome {
    Ok(outcome) ->
      json.object([
        #("cell_id", json.string(id)),
        #("status", json.string(python.status_name(outcome.status))),
        #("duration", json.nullable(outcome.duration, json.float)),
        #("output", json.string(outcome.output)),
        #("value", json.string(outcome.value)),
        #("truncated", json.bool(outcome.truncated)),
        ..case outcome.image_errors {
          [] -> []
          errors -> [#("image_errors", json.array(errors, json.string))]
        }
      ])
    Error(error) -> failure(id, reason(error))
  }
}

/// The cell id and why it could not run, as the tool reports a failure.
fn failure(id: String, message: String) -> json.Json {
  json.object([
    #("cell_id", json.string(id)),
    #("error", json.string(message)),
  ])
}

fn reason(error: python.Error) -> String {
  case error {
    python.Busy -> "session is already executing a cell"
    python.Lost ->
      "kernel lost; namespace unavailable; inspect side effects before resetting"
    python.Unavailable(message) | python.Invalid(message) -> message
  }
}

fn recover(context: extension.Context) {
  // The id invoke saved the cell under: begin_call's session <> "/" <> call_id,
  // or qualified with a nonce when an upstream provider reuses call ids.
  let base_id = context.session <> "/" <> context.call_id
  let cell = journal.find_call(context.store, base_id)
  let id = case cell {
    Ok(cell) -> cell.id
    Error(_) -> base_id
  }
  let outcome = case cell {
    Ok(cell) -> cell.outcome
    Error(_) -> None
  }
  Some(case outcome {
    Some(outcome) -> outcome_output(id, outcome, context.images)
    None ->
      failure(
        id,
        "interrupted; outcome unknown. Inspect saved cell and side effects before retrying.",
      )
      |> json.to_string
      |> extension.text
  })
}
