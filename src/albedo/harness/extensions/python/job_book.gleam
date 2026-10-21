//// The kernel's own book of jobs: every job its run plugin still knows, the
//// finished ones too, and pages of what they printed. The daemon asks the
//// kernel each time and keeps nothing, so the book is as long-lived as the
//// kernel's retained output.

import albedo/harness/extensions/python/kernel.{type Kernel}
import gleam/bool
import gleam/dynamic/decode
import gleam/json
import gleam/option.{type Option, Some}
import gleam/result

/// One job. `state` is `running` or `exited`; times are wall-clock
/// milliseconds, and `bytes` is everything the job has written.
pub type Record {
  Record(
    id: String,
    command: String,
    state: String,
    exit_code: Option(Int),
    timed_out: Bool,
    service: Bool,
    started_at: Int,
    ended_at: Option(Int),
    bytes: Int,
  )
}

/// A page of a job's output: the bytes it spans and the text they hold.
pub type Page {
  Page(job: Record, offset: Int, next_offset: Int, text: String)
}

pub type Failure {
  NoSuchJob
  /// The page is beyond what the kernel kept of the output.
  OutputLost(String)
  Rejected(String)
  Unavailable(String)
}

@external(erlang, "albedo_python", "job_list")
fn ask_list(kernel: Kernel) -> Result(String, String)

@external(erlang, "albedo_python", "job_read")
fn ask_read(
  kernel: Kernel,
  id: String,
  offset: Option(Int),
  limit: Int,
) -> Result(String, String)

/// A kernel on another python bundle or protocol ends its link on a frame it
/// does not know, so it is never asked: it has no job book to show.
fn knows_the_book(attached: Kernel) -> Bool {
  case kernel.stale(attached) {
    Some(kernel.Bundle) | Some(kernel.Protocol) -> False
    _ -> True
  }
}

/// Every job the kernel knows, newest first; none for a kernel that does not
/// know the job book yet.
pub fn list(kernel: Kernel) -> Result(List(Record), Failure) {
  use <- bool.guard(!knows_the_book(kernel), Ok([]))
  use reply <- result.try(ask_list(kernel) |> result.map_error(Unavailable))
  decode_reply(reply, {
    use jobs <- decode.field("jobs", decode.list(record()))
    decode.success(jobs)
  })
}

/// One page of a job's output, at most `limit` bytes from `offset`, or the
/// page that ends the output when there is no offset.
pub fn read(
  kernel: Kernel,
  id: String,
  offset: Option(Int),
  limit: Int,
) -> Result(Page, Failure) {
  use <- bool.guard(
    !knows_the_book(kernel),
    Error(Unavailable(
      "this kernel predates the job book; it is replaced when its session is idle",
    )),
  )
  use reply <- result.try(
    ask_read(kernel, id, offset, limit) |> result.map_error(Unavailable),
  )
  decode_reply(reply, {
    use job <- decode.field("job", record())
    use offset <- decode.field("offset", decode.int)
    use next_offset <- decode.field("next_offset", decode.int)
    use text <- decode.field("text", decode.string)
    decode.success(Page(job, offset, next_offset, text))
  })
}

/// A reply's fields when it says `ok`, else the failure it names.
fn decode_reply(
  reply: String,
  fields: decode.Decoder(a),
) -> Result(a, Failure) {
  let outcome = {
    use ok <- decode.field("ok", decode.bool)
    case ok {
      True -> decode.then(fields, fn(value) { decode.success(Ok(value)) })
      False -> {
        use code <- decode.optional_field("code", "failed", decode.string)
        use error <- decode.optional_field("error", "", decode.string)
        decode.success(Error(refusal(code, error)))
      }
    }
  }
  json.parse(reply, outcome)
  |> result.replace_error(Unavailable("the kernel answered unexpectedly"))
  |> result.flatten
}

fn refusal(code: String, error: String) -> Failure {
  case code {
    "not_found" -> NoSuchJob
    "lost" -> OutputLost(error)
    "invalid" -> Rejected(error)
    _ -> Unavailable(error)
  }
}

fn record() -> decode.Decoder(Record) {
  use id <- decode.field("id", decode.string)
  use command <- decode.field("command", decode.string)
  use state <- decode.field("state", decode.string)
  use exit_code <- decode.field("exit_code", decode.optional(decode.int))
  use timed_out <- decode.field("timed_out", decode.bool)
  use service <- decode.field("service", decode.bool)
  use started_at <- decode.field("started_at", decode.int)
  use ended_at <- decode.field("ended_at", decode.optional(decode.int))
  use bytes <- decode.field("bytes", decode.int)
  decode.success(Record(
    id,
    command,
    state,
    exit_code,
    timed_out,
    service,
    started_at,
    ended_at,
    bytes,
  ))
}

pub fn record_json(job: Record) -> json.Json {
  json.object([
    #("id", json.string(job.id)),
    #("command", json.string(job.command)),
    #("state", json.string(job.state)),
    #("exit_code", json.nullable(job.exit_code, json.int)),
    #("timed_out", json.bool(job.timed_out)),
    #("service", json.bool(job.service)),
    #("started_at", json.int(job.started_at)),
    #("ended_at", json.nullable(job.ended_at, json.int)),
    #("bytes", json.int(job.bytes)),
  ])
}

pub fn page_json(page: Page) -> json.Json {
  json.object([
    #("job", record_json(page.job)),
    #("offset", json.int(page.offset)),
    #("next_offset", json.int(page.next_offset)),
    #("text", json.string(page.text)),
  ])
}
