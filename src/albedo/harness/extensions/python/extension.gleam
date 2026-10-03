//// The single model-facing tool. Host capabilities are ordinary Python functions.

import albedo/harness/client_api
import albedo/harness/command
import albedo/harness/extension
import albedo/harness/extensions/python/cells as journal
import albedo/harness/extensions/python/kernel as python
import albedo/harness/extensions/python/link
import albedo/harness/extensions/python/migrations/cell_images
import albedo/harness/extensions/python/migrations/kernel_links
import albedo/harness/extensions/python/place
import albedo/harness/extensions/python/rpc as cells
import albedo/openai_api/types
import gleam/dict
import gleam/dynamic/decode
import gleam/http.{Get, Post}
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result

const default_timeout_ms = 300_000

fn definition() -> types.Tool {
  types.Tool(
    "python",
    "Execute Python in your persistent session. Provide code (string); timeout_ms (integer, 1–3600000) is optional and defaults to 300000. Top-level await works. Variables stay alive. Only printed output and the final expression return; duration is the cell's wall seconds; truncated=true means the output passed the 64 KiB preview, and the rest (up to 1 MiB) is readable with output.read(cell_id, offset=65536) while the cell is among the 16 most recent; read it before running many more cells, or print less. Failed cells are retained: await cells.read(id) for bounded source, await cells.info(id) for its status (ok, error, interrupted, started, saved) without source, await cells.trace(id) for what the cell read, ran and changed. Repair exact unique text without resending the source with await cells.run(id, replacements=[(old,new)]), or pass check=True first to compile the rewrite and get the syntax error back without running anything. A cell that started requires allow_partial=True after checking side effects; never retry blindly.",
    json.object([
      #("type", json.string("object")),
      #("additionalProperties", json.bool(False)),
      #("required", json.array(["code"], json.string)),
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

/// An unusable `timeout_ms` still saves the code, so the model reruns it with
/// `cells.run(id)` instead of resending the source.
///
/// Storage failure is `Fatal` rather than a refusal: a cell whose source or
/// outcome went unrecorded must not be offered back to the model to retry.
fn invoke(
  context: extension.Context,
  arguments: String,
) -> Result(extension.Output, extension.Failure) {
  let decoder = {
    use code <- decode.field("code", decode.string)
    use timeout <- decode.optional_field(
      "timeout_ms",
      Ok(default_timeout_ms),
      decode.one_of(decode.map(decode.int, Ok), [
        decode.map(decode.dynamic, fn(_) { Error(Nil) }),
      ]),
    )
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
      let outcome = case timeout {
        Ok(timeout_ms) ->
          python.execute_saved(
            context.kernel,
            id,
            code,
            timeout_ms,
            context.images,
          )
        Error(Nil) ->
          Error(python.Invalid(
            "timeout_ms must be an integer from 1 to 3600000; the code is saved, rerun it with cells.run(cell_id)",
          ))
      }
      use _ <- result.try(
        journal.settle(context.store, id, outcome)
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
      Ok(extension.text(
        "{\"error\":\"expected code (string) and optional timeout_ms (integer)\"}",
      ))
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
      extension.MigrationPlugin(extension.SchemaMigration(kernel_links.apply)),
      extension.CleanPlugin(link.forget_session),
      extension.CommandPlugin([kernel_command()]),
      extension.ClientPlugin([
        client_api.Command(
          "/kernel",
          client_api.Read,
          [],
          client_api.Operation(
            "getSession",
            Get,
            "/sessions/{session_id}",
            [#("session_id", client_api.Session("/id"))],
            [#("tail", client_api.Literal(json.int(0)))],
            [],
            [],
            json.object([
              #("type", json.string("object")),
              #("required", json.array(["kernel", "cursor"], json.string)),
            ]),
          ),
        ),
        client_api.Command(
          "/kernel",
          client_api.Mutation,
          [],
          client_api.Operation(
            "upgradeKernel",
            Post,
            "/sessions/{session_id}/kernel/upgrade",
            [#("session_id", client_api.Session("/id"))],
            [],
            [],
            [],
            json.object([
              #("type", json.string("object")),
              #(
                "required",
                json.array(
                  ["state", "old_kernel_id", "new_kernel_id"],
                  json.string,
                ),
              ),
            ]),
          ),
        ),
      ]),
      extension.ContextPlugin(place.context),
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

/// `/kernel` shows whether the session's kernel runs older code than the
/// daemon; `/kernel upgrade` swaps it now, past its live jobs.
fn kernel_command() -> command.Command {
  command.Command(
    "/kernel",
    "Show whether this session's python kernel is older than the daemon's bundle or modules, or upgrade it now (user only): the namespace carries over, live jobs stop.",
    [command.Argument("action", "upgrade, or omit to show", False, ["upgrade"])],
    False,
    False,
    False,
    None,
    fn(ctx: command.Context, _caller, args) {
      case dict.get(args, "action") {
        Error(_) | Ok("") -> ctx.state(command.KernelReport)
        Ok("upgrade") -> ctx.state(command.KernelUpgrade)
        Ok(other) ->
          Error("unknown kernel action " <> other <> "; available: upgrade")
      }
      |> result.map(command.Data)
    },
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
    python.Detached ->
      "the kernel was out of reach past the deadline; the cell may still be running there and its result is saved when the kernel is back. Check await cells.info(id) before rerunning anything"
  }
}

fn recover(context: extension.Context) -> option.Option(extension.Output) {
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
