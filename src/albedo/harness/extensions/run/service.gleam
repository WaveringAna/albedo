//// Session-owned job observations and explicit process-group stops.

import albedo/daemon/http_api as api
import albedo/harness/client_api
import albedo/harness/command
import albedo/harness/extension
import albedo/harness/extensions/python/kernel
import gleam/dynamic/decode
import gleam/http.{Get, Post}
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
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
    _ -> api.Failure(503, "job_operation_failed", detail)
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
  use _ <- result.try(api.parameters(req, []))
  case req.method, path {
    Get, ["sessions", id, "jobs"] -> {
      use observed <- result.try(
        command.context(id).state(command.KernelJobs)
        |> result.map_error(failure),
      )
      use jobs <- result.try(
        json.parse(json.to_string(observed), {
          use jobs <- decode.field("items", decode.list(job_decoder()))
          decode.success(jobs)
        })
        |> result.replace_error(api.Failure(
          503,
          "kernel_unavailable",
          "invalid kernel job observation",
        )),
      )
      use fields <- result.try(api.fields(json.to_string(observed)))
      Ok(api.reply(
        200,
        json.object([#("page", descriptor(id, jobs)), ..fields]),
      ))
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
    _, ["sessions", _, "jobs"] | _, ["sessions", _, "jobs", _, "stop"] ->
      Error(api.Failure(405, "method_not_allowed", "unsupported job method"))
    _, _ -> Error(api.Failure(404, "not_found", "job resource not found"))
  }
}

fn job_decoder() -> decode.Decoder(kernel.Job) {
  use id <- decode.field("id", decode.string)
  use pid <- decode.field("pid", decode.optional(decode.int))
  use command <- decode.field("command", decode.string)
  decode.success(kernel.Job(id, pid, command))
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
        keyboard_hint: "x",
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
