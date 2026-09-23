//// Run supervised shell commands from Python.

import albedo/daemon/store
import albedo/harness/extension as harness_extension
import gleam/dynamic/decode
import gleam/json

const instructions = "bash(command) starts a background job. Await its handle for completion, or keep it in a variable. jobs contains session-owned handles. A job's output lives on its handle (job.tail()) and stays readable in full with output.read(job.id). job.exit_code, job.duration, and job.timed_out report the exit status, wall seconds, and deadline state once the command ends. A job that finishes with its result unread wakes the session by itself, so polling a handle is optional: leave it in a variable, end the cell, and a notice naming the job arrives when it lands. Awaiting the job, reading its result, or stopping it first means no wake."

pub fn extension() -> harness_extension.Extension {
  harness_extension.Extension(
    "bash",
    "Run supervised shell commands from Python.",
    ["python"],
    [
      harness_extension.ToolPlugin(instructions, [], ["bash"], [
        #("jobs", route),
      ]),
    ],
    fn(_) { Ok(Nil) },
  )
}

pub fn plugin() -> harness_extension.Extension {
  extension()
}

/// A session's answer to a job wake. `Busy` is the kernel's retry signal.
pub type Wake {
  Delivered
  Busy
  Unavailable(reason: String)
}

/// The kernel's wake route: a finished background job reports itself here, and
/// the submit closure its session registered turns the notice into an ordinary
/// user turn, so the model never polls for completion. The reply's code is the
/// kernel's retry signal: "busy" retries, anything else gives up.
pub fn route(_store: store.Store, session: String, request: String) -> String {
  case json.parse(request, request_decoder()) {
    Ok(#("jobs.completed", args)) ->
      case decode.run(args, notice_decoder()) {
        Ok(notice) ->
          case deliver(session, notice.display, notice.text) {
            Delivered ->
              json.to_string(
                json.object([
                  #("ok", json.bool(True)),
                  #("value", json.string("delivered")),
                ]),
              )
            Busy -> refused("busy", "session is busy")
            Unavailable(reason) -> refused("unavailable", reason)
          }
        Error(_) -> refused("invalid", "invalid jobs notice")
      }
    _ -> refused("invalid", "unknown jobs operation")
  }
}

fn request_decoder() -> decode.Decoder(#(String, decode.Dynamic)) {
  use method <- decode.field("method", decode.string)
  use args <- decode.field("args", decode.dynamic)
  decode.success(#(method, args))
}

type Notice {
  Notice(display: String, text: String)
}

fn notice_decoder() -> decode.Decoder(Notice) {
  use display <- decode.field("display", decode.string)
  use text <- decode.field("text", decode.string)
  decode.success(Notice(display, text))
}

@external(erlang, "albedo_wakes", "deliver")
fn deliver(session: String, display: String, text: String) -> Wake

fn refused(code: String, message: String) -> String {
  json.object([
    #("ok", json.bool(False)),
    #("code", json.string(code)),
    #("message", json.string(message)),
  ])
  |> json.to_string
}
