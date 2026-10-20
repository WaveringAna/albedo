//// Session-owned job observations, explicit process-group stops, and what
//// jobs printed: the kernel's job book (finished jobs too) and pages of one
//// job's output.

import albedo/daemon/http_api as api
import albedo/harness/client_api
import albedo/harness/command
import albedo/harness/extension
import albedo/harness/extensions/python/job_book
import albedo/harness/extensions/python/kernel
import gleam/http.{Get, Post}
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import mist

pub fn operation() -> client_api.Operation {
  client_api.Operation(
    "listJobs",
    Get,
    "/extensions/run/sessions/{session_id}/jobs",
    [#("session_id", client_api.Session("/id"))],
    [],
    [],
    [],
    json.object([]),
    Some(200),
  )
}

pub fn handle(
  _daemon: extension.Daemon,
  path: List(String),
  req: request.Request(BitArray),
  _live: request.Request(mist.Connection),
) -> response.Response(mist.ResponseData) {
  case dispatch(path, req) {
    Ok(value) -> value
    Error(error) -> api.fail(error)
  }
}

fn failure(detail: String) -> api.Failure {
  case detail {
    "session unavailable" -> api.failure("session not found")
    "job not found" -> api.Failure(404, "job_not_found", detail)
    _ ->
      case string.starts_with(detail, output_lost) {
        True -> api.Failure(409, "output_lost", detail)
        False -> api.Failure(503, "job_operation_failed", detail)
      }
  }
}

/// How a read failure that is not a missing job begins, for `failure`.
const output_lost = "output no longer retained: "

/// The most output one page carries, the kernel's own preview bound.
const page_limit = 65_536

fn refusal(failure: job_book.Failure) -> String {
  case failure {
    job_book.NoSuchJob -> "job not found"
    job_book.OutputLost(why) -> output_lost <> why
    job_book.Rejected(why) | job_book.Unavailable(why) -> why
  }
}

fn dispatch(
  path: List(String),
  req: request.Request(BitArray),
) -> Result(response.Response(mist.ResponseData), api.Failure) {
  use events <- result.try(api.wants_events(req))
  use _ <- result.try(case events {
    True -> Error(api.Failure(406, "not_acceptable", "jobs use JSON"))
    False -> Ok(Nil)
  })
  use parameters <- result.try(
    api.parameters(req, case path {
      ["sessions", _, "jobs", _, "output"] -> ["offset", "limit"]
      _ -> []
    }),
  )
  case req.method, path {
    Get, ["sessions", id, "jobs"] -> {
      use observed <- result.try(
        command.context(id).state(
          command.KernelJobs(fn(jobs, live_job_count) {
            json.object([
              #("page", descriptor(id, jobs)),
              ..kernel.jobs_fields(jobs, live_job_count)
            ])
          }),
        )
        |> result.map_error(failure),
      )
      Ok(api.reply(200, observed))
    }
    Post, ["sessions", id, "jobs", job, "stop"] -> {
      use _ <- result.try(api.empty_body(req))
      use _ <- result.try(
        command.context(id).state(command.KernelStopJob(job))
        |> result.map_error(failure),
      )
      let _ =
        command.context(id).state(command.Note(
          "jobs",
          "stopped background job " <> job,
          "<system-note>background job " <> job <> " was stopped</system-note>",
        ))
      Ok(api.reply(200, json.object([#("stopped", json.string(job))])))
    }
    Get, ["sessions", id, "jobs", "recent"] -> {
      use jobs <- result.try(
        command.context(id).state(
          command.KernelRead(fn(attached) {
            case attached {
              Some(kernel) ->
                job_book.list(kernel)
                |> result.map(fn(jobs) {
                  json.array(jobs, job_book.record_json)
                })
                |> result.map_error(refusal)
              None -> Ok(json.array([], job_book.record_json))
            }
          }),
        )
        |> result.map_error(failure),
      )
      Ok(api.reply(200, json.object([#("items", jobs)])))
    }
    Get, ["sessions", id, "jobs", job, "output"] -> {
      use offset <- result.try(case list.key_find(parameters, "offset") {
        Ok(_) ->
          api.integer_parameter(parameters, "offset", 0, 9_007_199_254_740_991)
          |> result.map(Some)
        Error(_) -> Ok(None)
      })
      use limit <- result.try(api.integer_parameter(
        parameters,
        "limit",
        16_384,
        page_limit,
      ))
      use _ <- result.try(case limit >= 4 {
        True -> Ok(Nil)
        False -> Error(api.invalid("a page holds at least four bytes"))
      })
      use page <- result.try(
        command.context(id).state(
          command.KernelRead(fn(attached) {
            case attached {
              Some(kernel) ->
                job_book.read(kernel, job, offset, limit)
                |> result.map(job_book.page_json)
                |> result.map_error(refusal)
              None -> Error("job not found")
            }
          }),
        )
        |> result.map_error(failure),
      )
      Ok(api.reply(200, page))
    }
    _, ["sessions", _, "jobs"]
    | _, ["sessions", _, "jobs", "recent"]
    | _, ["sessions", _, "jobs", _, "stop"]
    | _, ["sessions", _, "jobs", _, "output"]
    -> Error(api.Failure(405, "method_not_allowed", "unsupported job method"))
    _, _ -> Error(api.Failure(404, "not_found", "job resource not found"))
  }
}

fn descriptor(id: String, jobs: List(kernel.Job)) -> json.Json {
  client_api.page(client_api.Page(
    title: "jobs",
    summary: case list.length(jobs) {
      1 -> "1 background job running"
      count -> int.to_string(count) <> " background jobs running"
    },
    empty_state: "no background jobs running",
    glance: None,
    actions: [
      client_api.Action(
        id: "stop",
        label: "stop",
        keyboard_hint: "ctrl+x",
        confirmation: Some("stop this background job?"),
        fields: [],
        operation: client_api.Operation(
          "stopJob",
          Post,
          "/extensions/run/sessions/{session_id}/jobs/{job_id}/stop",
          [
            #("session_id", client_api.Literal(json.string(id))),
            #("job_id", client_api.Row("/id")),
          ],
          [],
          [],
          [],
          json.object([]),
          Some(200),
        ),
      ),
    ],
    rows: list.map(jobs, fn(job) {
      client_api.PageRow(
        id: job.id,
        text: case job.command {
          "" -> "job " <> job.id
          cmd -> cmd
        },
        badge: Some(case job.pid {
          Some(pid) -> "pid " <> int.to_string(pid)
          None -> "running"
        }),
        tone: "active",
        detail: None,
        resource: json.null(),
      )
    }),
  ))
}
