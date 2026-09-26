//// Start supervised programs from Python, without a shell.

import albedo/daemon/store
import albedo/harness/extension as harness_extension
import gleam/dynamic/decode
import gleam/json

const instructions = "run(program, *args, cwd=None, env=None, stdin=None, timeout=300) starts one program without a shell and returns a background job handle right away: job = await run(\"go\", \"test\", \"./...\", cwd=\"cli\") then job.exit_code and job.tail(lines=20). There is no shell, so shell syntax has Python spellings: cd dir && ... is cwd=, NAME=value is env= (added to the kernel's environment), | tail -n 20 is job.tail(lines=20), | head -n 20 is job.head(lines=20), a | b is .pipe(): run() and job.pipe(program, *args) return handles at once, so chain first and await once, as in job = await run(\"git\", \"log\", \"--oneline\").pipe(\"rg\", \"fix\").pipe(\"sort\", \"-u\"); the stages stream like a shell pipe, the await waits for the last one, and job.pipeline is the whole line, 2>&1 is implied (stderr joins stdout), stdin= takes text, bytes, a path, or another job, and &&, loops, and globs are Python over job.exit_code and the output. `sh -c` and subprocess/os.system from a cell are refused with the run() call they mean. Programs start at once at low priority; one still running after 5 seconds needs one of a few daemon-wide heavy slots and is paused while it waits (job.queued is True then), so keep long computations few and let quick commands be quick. The timeout (seconds) counts only time the program ran, not time paused. Await the handle for completion, or keep it in a variable. jobs is a dict of job id to handle for this session. A job's output lives on its handle (job.tail(n=4000) for the last n characters, lines= for lines; job.command is what ran, job.argv as a list) and stays readable in full with output.read(job.id, offset=0, limit=4000); await job.stop() ends it. job.exit_code, job.duration, and job.timed_out report the exit status, wall seconds, and deadline state once the program ends (job.poll() and job.returncode are subprocess-style spellings of job.exit_code). A job that finishes with its result unread wakes the session by itself, so polling a handle is optional: leave it in a variable, end the cell, and a notice naming the job arrives once the session is idle. A job that finishes while you are still working is reported after your turn ends, unless you read it first. Awaiting the job, reading its result, or stopping it first means no wake."

pub fn extension() -> harness_extension.Extension {
  harness_extension.Extension(
    "run",
    "Start supervised programs from Python, without a shell.",
    ["python"],
    [
      harness_extension.ToolPlugin(instructions, [], ["run"], [
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
