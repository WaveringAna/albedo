import albedo/daemon/bus
import albedo/daemon/conversation
import albedo/daemon/http_api as api
import albedo/harness/client_api
import albedo/harness/extension
import albedo/harness/extensions/schedule/ledger
import gleam/dynamic/decode
import gleam/http.{Delete, Get, Patch, Post}
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import mist

pub fn handle(
  daemon: extension.Daemon,
  path: List(String),
  req: request.Request(BitArray),
  _live: request.Request(mist.Connection),
) -> response.Response(mist.ResponseData) {
  case dispatch(daemon, path, req) {
    Ok(response) -> response
    Error(error) -> api.fail(error)
  }
}

fn failure(error: String) -> api.Failure {
  case error {
    "schedule not found" -> api.Failure(404, "not_found", error)
    "schedule changed" -> api.Failure(412, "precondition_failed", error)
    _ -> api.Failure(503, "storage_failed", error)
  }
}

fn identifier(text: String) -> Result(Int, api.Failure) {
  case int.parse(text) {
    Ok(id) if id > 0 -> Ok(id)
    _ -> Error(api.invalid("invalid schedule id"))
  }
}

fn dispatch(
  daemon: extension.Daemon,
  path: List(String),
  req: request.Request(BitArray),
) -> Result(response.Response(mist.ResponseData), api.Failure) {
  use events <- result.try(api.wants_events(req))
  use _ <- result.try(case events {
    True -> Error(api.Failure(406, "not_acceptable", "schedules use JSON"))
    False -> Ok(Nil)
  })
  use query <- result.try(
    api.parameters(req, case req.method, path {
      Get, ["jobs"] -> ["session_id", "limit", "next"]
      _, _ -> []
    }),
  )
  case req.method, path {
    Get, ["jobs"] -> {
      use session <- result.try(
        list.key_find(query, "session_id")
        |> result.replace_error(api.invalid("session_id is required")),
      )
      use limit <- result.try(api.integer_parameter(query, "limit", 50, 200))
      use _ <- result.try(case limit > 0 {
        True -> Ok(Nil)
        False -> Error(api.invalid("limit must be positive"))
      })
      let binding = "schedule:" <> session
      use after <- result.try(case list.key_find(query, "next") {
        Error(_) -> Ok(0)
        Ok(token) ->
          api.page_state(daemon.home, binding, token)
          |> result.replace_error(api.invalid("invalid page token"))
          |> result.try(identifier)
      })
      use items <- result.try(
        ledger.page(daemon.ledger, session, after, limit)
        |> result.map_error(failure),
      )
      let supplied = list.length(items)
      let items = api.bounded_items(items, 350_000, resource)
      let next = case
        supplied == limit || list.length(items) < supplied,
        list.last(items)
      {
        True, Ok(last) ->
          json.string(api.page_token(
            daemon.home,
            binding,
            int.to_string(last.id),
          ))
        _, _ -> json.null()
      }
      Ok(api.reply(
        200,
        json.object([
          #("items", json.array(items, resource)),
          #("next", next),
          #("page", descriptor(items, session)),
        ]),
      ))
    }
    Post, ["jobs"] -> {
      use fields <- result.try(
        api.body(
          req,
          ["session_id", "kind", "prompt", "delay_seconds", "every_seconds"],
          {
            use session <- decode.field("session_id", decode.string)
            use kind <- decode.field("kind", decode.string)
            use prompt <- decode.field("prompt", decode.string)
            use delay <- decode.optional_field("delay_seconds", 0, decode.int)
            use every <- decode.optional_field(
              "every_seconds",
              None,
              decode.map(decode.int, Some),
            )
            decode.success(#(session, kind, prompt, delay, every))
          },
        ),
      )
      use _ <- result.try(valid(fields.1, fields.2, fields.3, fields.4))
      use _ <- result.try(
        conversation.get(daemon.ledger, fields.0)
        |> result.map_error(fn(error) {
          case error {
            "session not found" -> api.Failure(404, "not_found", error)
            _ -> failure(error)
          }
        }),
      )
      use item <- result.try(
        ledger.save(
          daemon.ledger,
          fields.0,
          None,
          fields.1,
          fields.2,
          fields.3,
          fields.4,
        )
        |> result.map_error(failure),
      )
      Ok(
        api.reply(201, change(item))
        |> response.set_header("location", url(item.id)),
      )
    }
    Get, ["jobs", id] -> {
      use id <- result.try(identifier(id))
      use item <- result.try(
        ledger.find(daemon.ledger, id) |> result.map_error(failure),
      )
      Ok(api.reply(200, value(item)) |> response.set_header("etag", etag(item)))
    }
    Patch, ["jobs", id] -> {
      use id <- result.try(identifier(id))
      use current <- result.try(
        ledger.find(daemon.ledger, id) |> result.map_error(failure),
      )
      use _ <- result.try(api.require_match(req, etag(current)))
      use fields <- result.try(
        api.body(req, ["kind", "prompt", "delay_seconds", "every_seconds"], {
          use kind <- decode.optional_field("kind", current.kind, decode.string)
          use prompt <- decode.optional_field(
            "prompt",
            current.prompt,
            decode.string,
          )
          use delay <- decode.optional_field(
            "delay_seconds",
            None,
            decode.map(decode.int, Some),
          )
          use every <- decode.optional_field(
            "every_seconds",
            current.every,
            decode.optional(decode.int),
          )
          decode.success(#(kind, prompt, delay, every))
        }),
      )
      use _ <- result.try(valid(
        fields.0,
        fields.1,
        case fields.2 {
          None -> 0
          Some(delay) -> delay
        },
        fields.3,
      ))
      let next_at = case fields.2 {
        None -> current.next_at
        Some(delay) -> ledger.now() + delay
      }
      use changed <- result.try(
        ledger.update_observed(
          daemon.ledger,
          ledger.Job(
            ..current,
            kind: fields.0,
            prompt: fields.1,
            next_at: next_at,
            every: fields.3,
          ),
        )
        |> result.map_error(failure),
      )
      Ok(api.reply(200, change(changed)))
    }
    Delete, ["jobs", id] -> {
      use id <- result.try(identifier(id))
      use current <- result.try(
        ledger.find(daemon.ledger, id) |> result.map_error(failure),
      )
      use _ <- result.try(api.require_match(req, etag(current)))
      use _ <- result.try(
        ledger.delete_observed(daemon.ledger, id, current.revision)
        |> result.map_error(failure),
      )
      bus.invalidate(
        [url(id), "/extensions/schedule/jobs?session_id=" <> current.session],
        [current.session],
        False,
      )
      Ok(api.reply(
        200,
        json.object([
          #("id", json.string(int.to_string(id))),
          #("notification", notification()),
        ]),
      ))
    }
    _, ["jobs"] | _, ["jobs", _] ->
      Error(api.Failure(
        405,
        "method_not_allowed",
        "unsupported schedule method",
      ))
    _, _ -> Error(api.Failure(404, "not_found", "schedule resource not found"))
  }
}

fn valid(
  kind: String,
  prompt: String,
  delay: Int,
  every: Option(Int),
) -> Result(Nil, api.Failure) {
  let repetition = case kind, every {
    "once", None -> True
    "recurring", Some(seconds) | "heartbeat", Some(seconds) ->
      seconds >= 60 && seconds <= 31_536_000
    _, _ -> False
  }
  case
    repetition
    && string.trim(prompt) != ""
    && string.byte_size(prompt) <= 4096
    && delay >= 0
    && delay <= 31_536_000
  {
    True -> Ok(Nil)
    False -> Error(api.invalid("invalid schedule candidate"))
  }
}

fn url(id: Int) -> String {
  "/extensions/schedule/jobs/" <> int.to_string(id)
}

fn etag(item: ledger.Job) -> String {
  "\"schedule-"
  <> int.to_string(item.id)
  <> "-"
  <> int.to_string(item.revision)
  <> "\""
}

fn value(item: ledger.Job) -> json.Json {
  json.object([
    #("id", json.string(int.to_string(item.id))),
    #("session_id", json.string(item.session)),
    #("kind", json.string(item.kind)),
    #("prompt", json.string(item.prompt)),
    #("next_at", json.string(api.timestamp(item.next_at * 1000))),
    #("every_seconds", json.nullable(item.every, json.int)),
    #("revision", json.string(int.to_string(item.revision))),
    #("created_at", json.nullable(item.created_at, json.string)),
    #("updated_at", json.nullable(item.updated_at, json.string)),
  ])
}

fn resource(item: ledger.Job) -> json.Json {
  json.object([
    #("url", json.string(url(item.id))),
    #("etag", json.string(etag(item))),
    #("value", value(item)),
  ])
}

fn notification() -> json.Json {
  json.object([
    #("state", json.string("not_requested")),
    #("code", json.null()),
    #("detail", json.null()),
  ])
}

fn change(item: ledger.Job) -> json.Json {
  bus.invalidate(
    [url(item.id), "/extensions/schedule/jobs?session_id=" <> item.session],
    [item.session],
    False,
  )
  json.object([#("resource", resource(item)), #("notification", notification())])
}

fn descriptor(items: List(ledger.Job), session: String) -> json.Json {
  client_api.page(client_api.Page(
    title: "schedule",
    summary: int.to_string(list.length(items)) <> " jobs",
    empty_state: "no scheduled prompts",
    glance: None,
    actions: actions(session),
    rows: list.map(items, fn(item) {
      client_api.PageRow(
        id: int.to_string(item.id),
        text: api.content_preview(item.prompt, 1000),
        badge: item.kind,
        tone: "plain",
        detail: None,
        resource: resource(item),
      )
    }),
  ))
}

fn actions(session: String) -> List(client_api.Action) {
  let fields = [
    client_api.Field(
      name: "kind",
      label: "kind",
      kind: "choice",
      required: True,
      default: json.null(),
      choices: list.map(["once", "recurring", "heartbeat"], fn(value) {
        #(json.string(value), value)
      }),
      description: "",
      default_binding: None,
    ),
    client_api.Field(
      name: "prompt",
      label: "prompt",
      kind: "text",
      required: True,
      default: json.null(),
      choices: [],
      description: "",
      default_binding: None,
    ),
    client_api.Field(
      name: "delay_seconds",
      label: "delay_seconds",
      kind: "integer",
      required: False,
      default: json.null(),
      choices: [],
      description: "",
      default_binding: None,
    ),
    client_api.Field(
      name: "every_seconds",
      label: "every_seconds",
      kind: "integer",
      required: False,
      default: json.null(),
      choices: [],
      description: "",
      default_binding: None,
    ),
  ]
  [
    client_api.Action(
      id: "create",
      label: "add",
      keyboard_hint: "a",
      confirmation: None,
      fields: fields,
      operation: client_api.Operation(
        id: "createSchedule",
        method: Post,
        path_template: "/extensions/schedule/jobs",
        path: [],
        query: [],
        headers: [],
        body: [
          #("/session_id", client_api.Literal(json.string(session))),
          ..client_api.form_body([
            "kind",
            "prompt",
            "delay_seconds",
            "every_seconds",
          ])
        ],
        result_schema: json.object([]),
      ),
    ),
    client_api.Action(
      id: "edit",
      label: "edit",
      keyboard_hint: "e",
      confirmation: None,
      fields: [
        client_api.Field(
          name: "kind",
          label: "kind",
          kind: "choice",
          required: False,
          default: json.null(),
          choices: list.map(["once", "recurring", "heartbeat"], fn(value) {
            #(json.string(value), value)
          }),
          description: "",
          default_binding: Some(client_api.Row("/resource/value/" <> "kind")),
        ),
        client_api.Field(
          name: "prompt",
          label: "prompt",
          kind: "text",
          required: False,
          default: json.null(),
          choices: [],
          description: "",
          default_binding: Some(client_api.Row("/resource/value/" <> "prompt")),
        ),
        client_api.Field(
          name: "delay_seconds",
          label: "delay_seconds",
          kind: "integer",
          required: False,
          default: json.null(),
          choices: [],
          description: "",
          default_binding: None,
        ),
        client_api.Field(
          name: "every_seconds",
          label: "every_seconds",
          kind: "integer",
          required: False,
          default: json.null(),
          choices: [],
          description: "",
          default_binding: Some(client_api.Row(
            "/resource/value/" <> "every_seconds",
          )),
        ),
      ],
      operation: client_api.Operation(
        id: "patchSchedule",
        method: Patch,
        path_template: "/extensions/schedule/jobs/{job_id}",
        path: [#("job_id", client_api.Row("/resource/value/id"))],
        query: [],
        headers: [#("If-Match", client_api.Row("/resource/etag"))],
        body: client_api.form_body([
          "kind",
          "prompt",
          "delay_seconds",
          "every_seconds",
        ]),
        result_schema: json.object([]),
      ),
    ),
    client_api.Action(
      id: "once",
      label: "run once",
      keyboard_hint: "",
      confirmation: None,
      fields: [
        client_api.Field(
          name: "delay_seconds",
          label: "delay_seconds",
          kind: "integer",
          required: False,
          default: json.null(),
          choices: [],
          description: "",
          default_binding: None,
        ),
      ],
      operation: client_api.Operation(
        id: "patchSchedule",
        method: Patch,
        path_template: "/extensions/schedule/jobs/{job_id}",
        path: [#("job_id", client_api.Row("/resource/value/id"))],
        query: [],
        headers: [#("If-Match", client_api.Row("/resource/etag"))],
        body: [
          #("/kind", client_api.Literal(json.string("once"))),
          #("/every_seconds", client_api.Literal(json.null())),
          ..client_api.form_body(["delay_seconds"])
        ],
        result_schema: json.object([]),
      ),
    ),
    client_api.Action(
      id: "delete",
      label: "delete",
      keyboard_hint: "x",
      confirmation: Some("Delete this item?"),
      fields: [],
      operation: client_api.Operation(
        id: "deleteSchedule",
        method: Delete,
        path_template: "/extensions/schedule/jobs/{job_id}",
        path: [#("job_id", client_api.Row("/resource/value/id"))],
        query: [],
        headers: [#("If-Match", client_api.Row("/resource/etag"))],
        body: [],
        result_schema: json.object([]),
      ),
    ),
  ]
}
