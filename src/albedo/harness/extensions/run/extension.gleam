//// Start supervised programs from Python, without a shell.

import albedo/daemon/store
import albedo/harness/client_api
import albedo/harness/command.{Data}
import albedo/harness/extension as harness_extension
import albedo/harness/extensions/python/kernel
import albedo/harness/extensions/run/service
import albedo/harness/rpc
import gleam/dynamic/decode
import gleam/json
import gleam/option.{None}
import gleam/result

const instructions = "run(program, *args, cwd=None, env=None, stdin=None, timeout=300) starts one program without a shell and returns its job handle right away; run is not async, and awaiting the handle waits for the program: job = run(\"go\", \"test\", \"./...\", cwd=\"cli\"), then await job, then job.exit_code and job.tail(lines=20). Bind the handle before awaiting it: job = await run(...) blocks before the assignment, so a cell interrupted mid-wait leaves the running job only in jobs. There is no shell, so shell syntax has Python spellings: cd dir && ... is cwd=, NAME=value is env= (added to the kernel's environment), | tail -n 20 is job.tail(lines=20), | head -n 20 is job.head(lines=20), a | b is .pipe(): run() and job.pipe(program, *args) return handles at once, so chain first and await once, as in job = run(\"git\", \"log\", \"--oneline\").pipe(\"rg\", \"fix\").pipe(\"sort\", \"-u\"); await job; the stages stream like a shell pipe, the await waits for the last one, and job.pipeline is the whole line, 2>&1 is implied (stderr joins stdout), stdin= takes text, bytes, a path, or another job, and &&, loops, and globs are Python over job.exit_code and the output. `sh -c` and subprocess/os.system from a cell are refused with the run() call they mean, and so is a time.sleep of a second or more: start the work with run() and do other useful work while it runs; if nothing else is left, give the user a status report first, then wait with await asyncio.sleep(n). Programs start at once at low priority and are never paused for admission. cargo runs through mbx (a shared build cache) when mbx is installed, so every checkout reuses compiled work; env={\"ALBEDO_NO_MBX\": \"1\"} runs plain cargo. The timeout (seconds, at most a day) counts wall time after the program starts. Await the handle for completion, or keep it in a variable. jobs is a dict of job id to handle for this session. A job's output lives on its handle (job.tail(n=4000) for the last n characters, lines= for lines; job.command is what ran, job.argv as a list) and stays readable in full with output.read(job.id, offset=0, limit=4000); await job.stop() ends it. job.exit_code, job.duration, and job.timed_out report the exit status, the seconds it ran, and deadline state once the program ends (job.poll() and job.returncode are subprocess-style spellings of job.exit_code). A job that finishes with its result unread wakes the session by itself, so polling a handle is optional: leave it in a variable, end the cell, and a notice naming the job arrives once the session is idle. A job that finishes while you are still working is reported after your turn ends, unless you read it first. Awaiting the job, reading its result, or stopping it first means no wake."

pub fn extension() -> harness_extension.Extension {
  harness_extension.Extension(
    "run",
    "Start supervised programs from Python, without a shell.",
    ["python"],
    [
      harness_extension.ClientPlugin([
        client_api.Command("/jobs", client_api.Read, [], service.operation()),
      ]),
      harness_extension.ServicePlugin(harness_extension.Service(
        fn(_, _) {
          harness_extension.Admission(harness_extension.DaemonToken, 1024)
        },
        service.handle,
      )),
      harness_extension.ToolPlugin(instructions, [], ["run"], [
        #("jobs", route),
      ]),
      harness_extension.CommandPlugin([command()]),
    ],
    harness_extension.no_initialise,
  )
}

/// `/jobs`: inspect and manage background jobs running in the session.
fn command() -> command.Command {
  command.Command(
    "/jobs",
    "Show background jobs running in this session.",
    [],
    False,
    False,
    True,
    None,
    fn(ctx, _caller, _args) {
      ctx.state(
        command.KernelJobs(fn(jobs, live_job_count) {
          json.object(kernel.jobs_fields(jobs, live_job_count))
        }),
      )
      |> result.map(Data)
    },
  )
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
fn route(_store: store.Store, session: String, request: String) -> String {
  case rpc.decode(request) {
    Ok(#("jobs.completed", args)) ->
      case rpc.args(args, notice_decoder(), Nil) {
        Ok(#(display, text)) ->
          case deliver(session, display, text) {
            Delivered -> Ok(json.string("delivered"))
            Busy -> Error(#("busy", "session is busy"))
            Unavailable(reason) -> Error(#("unavailable", reason))
          }
        Error(_) -> Error(#("invalid", "invalid jobs notice"))
      }
    _ -> Error(#("invalid", "unknown jobs operation"))
  }
  |> rpc.reply
}

fn notice_decoder() -> decode.Decoder(#(String, String)) {
  use display <- decode.field("display", decode.string)
  use text <- decode.field("text", decode.string)
  decode.success(#(display, text))
}

@external(erlang, "albedo_wakes", "deliver")
fn deliver(session: String, display: String, text: String) -> Wake
