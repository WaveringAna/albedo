import albedo/daemon/bus
import albedo/daemon/http_api as api
import albedo/harness/client_api
import albedo/harness/command
import albedo/harness/extension
import albedo/harness/extensions/work/ledger as work
import albedo/harness/page
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
import gleam/uri
import mist

pub fn handle(
  daemon: extension.Daemon,
  path: List(String),
  req: request.Request(BitArray),
  _live: request.Request(mist.Connection),
) -> response.Response(mist.ResponseData) {
  case dispatch(daemon, path, req) {
    Ok(reply) -> reply
    Error(failure) -> api.fail(failure)
  }
}

fn failure(error: work.Error) -> api.Failure {
  case error {
    work.Invalid("remove its sub-items first" as detail) ->
      api.Failure(409, "has_children", detail)
    work.Invalid(detail) -> api.invalid(detail)
    work.NotFound -> api.Failure(404, "not_found", "work item not found")
    work.Conflict ->
      api.Failure(412, "precondition_failed", "work item changed")
    work.Storage(detail) -> api.Failure(503, "storage_failed", detail)
  }
}

fn dispatch(
  daemon: extension.Daemon,
  path: List(String),
  req: request.Request(BitArray),
) -> Result(response.Response(mist.ResponseData), api.Failure) {
  use events <- result.try(api.wants_events(req))
  use _ <- result.try(case events {
    True -> Error(api.Failure(406, "not_acceptable", "work resources use JSON"))
    False -> Ok(Nil)
  })
  use query <- result.try(
    api.parameters(req, case req.method, path {
      Get, ["items"] -> ["workspace", "limit", "next"]
      Delete, ["items", _] -> ["workspace", "notify_session_id"]
      _, _ -> ["workspace"]
    }),
  )
  use workspace <- result.try(
    list.key_find(query, "workspace")
    |> result.replace_error(api.invalid("workspace is required")),
  )
  use _ <- result.try(
    case workspace == "" || string.byte_size(workspace) > 4096 {
      True -> Error(api.invalid("invalid workspace"))
      False -> Ok(Nil)
    },
  )
  case req.method, path {
    Get, ["items"] -> {
      use limit <- result.try(api.integer_parameter(query, "limit", 50, 200))
      use _ <- result.try(case limit > 0 {
        True -> Ok(Nil)
        False -> Error(api.invalid("limit must be positive"))
      })
      use after <- result.try(after(query, workspace, daemon.home))
      use items <- result.try(
        work.list(daemon.ledger, workspace, after, limit)
        |> result.map_error(failure),
      )
      let supplied = list.length(items)
      let items = api.bounded_items(items, 350_000, resource(_, workspace))
      let next = case
        supplied == limit || list.length(items) < supplied,
        list.last(items)
      {
        True, Ok(last) ->
          json.string(api.page_token(
            daemon.home,
            "work:" <> workspace,
            int.to_string(last.id),
          ))
        _, _ -> json.null()
      }
      Ok(api.reply(
        200,
        json.object([
          #("items", json.array(items, resource(_, workspace))),
          #("next", next),
          #("page", descriptor(items, workspace)),
        ]),
      ))
    }
    Post, ["items"] -> {
      use value <- result.try(
        api.body(
          req,
          [
            "title",
            "notes",
            "parent_id",
            "session_id",
            "run_id",
            "notify_session_id",
          ],
          {
            use title <- decode.field("title", decode.string)
            use notes <- decode.optional_field("notes", "", decode.string)
            use parent <- decode.optional_field(
              "parent_id",
              None,
              decode.optional(decode.string),
            )
            use session <- decode.optional_field(
              "session_id",
              None,
              decode.optional(decode.string),
            )
            use run <- decode.optional_field(
              "run_id",
              None,
              decode.optional(decode.string),
            )
            use notify <- decode.optional_field(
              "notify_session_id",
              None,
              decode.optional(decode.string),
            )
            decode.success(#(title, notes, parent, session, run, notify))
          },
        ),
      )
      use _ <- result.try(identities([value.3, value.4, value.5]))
      use parent <- result.try(case value.2 {
        None -> Ok(None)
        Some(id) -> identifier(id) |> result.map(Some)
      })
      use item <- result.try(
        work.create_assigned(
          daemon.ledger,
          workspace,
          value.0,
          value.1,
          parent,
          value.3,
          value.4,
        )
        |> result.map_error(failure),
      )
      let target = option_target(value.5, value.3)
      Ok(
        api.reply(201, change(item, workspace, notify(target, item, "added")))
        |> response.set_header("location", url(item.id, workspace)),
      )
    }
    Get, ["items", id] -> {
      use id <- result.try(identifier(id))
      use item <- result.try(
        work.get(daemon.ledger, workspace, id) |> result.map_error(failure),
      )
      Ok(api.reply(200, value(item)) |> response.set_header("etag", etag(item)))
    }
    Patch, ["items", id] -> {
      use id <- result.try(identifier(id))
      use current <- result.try(
        work.get(daemon.ledger, workspace, id) |> result.map_error(failure),
      )
      use _ <- result.try(api.require_match(req, etag(current)))
      use fields <- result.try(
        api.body(
          req,
          [
            "title",
            "notes",
            "session_id",
            "run_id",
            "status",
            "notify_session_id",
          ],
          {
            use title <- decode.optional_field(
              "title",
              current.title,
              decode.string,
            )
            use notes <- decode.optional_field(
              "notes",
              current.notes,
              decode.string,
            )
            use session <- decode.optional_field(
              "session_id",
              current.session,
              decode.optional(decode.string),
            )
            use run <- decode.optional_field(
              "run_id",
              current.run,
              decode.optional(decode.string),
            )
            use status <- decode.optional_field(
              "status",
              work.status_name(current.status),
              decode.string,
            )
            use notify <- decode.optional_field(
              "notify_session_id",
              None,
              decode.optional(decode.string),
            )
            decode.success(#(title, notes, session, run, status, notify))
          },
        ),
      )
      use _ <- result.try(identities([fields.2, fields.3, fields.5]))
      use status <- result.try(
        work.parse_status(fields.4) |> result.map_error(failure),
      )
      use changed <- result.try(
        work.update(
          daemon.ledger,
          workspace,
          work.Item(
            ..current,
            title: fields.0,
            notes: fields.1,
            session: fields.2,
            run: fields.3,
            status: status,
          ),
        )
        |> result.map_error(failure),
      )
      Ok(api.reply(
        200,
        change(
          changed,
          workspace,
          notify(option_target(fields.5, changed.session), changed, "changed"),
        ),
      ))
    }
    Delete, ["items", id] -> {
      use id <- result.try(identifier(id))
      use current <- result.try(
        work.get(daemon.ledger, workspace, id) |> result.map_error(failure),
      )
      use _ <- result.try(api.require_match(req, etag(current)))
      let requested =
        list.key_find(query, "notify_session_id") |> option.from_result
      use _ <- result.try(identities([requested]))
      use deleted <- result.try(
        work.delete(daemon.ledger, workspace, id, current.revision)
        |> result.map_error(failure),
      )
      bus.invalidate(
        [
          url(id, workspace),
          "/extensions/work/items?workspace=" <> uri.percent_encode(workspace),
        ],
        [],
        True,
      )
      Ok(api.reply(
        200,
        json.object([
          #("id", json.string(int.to_string(id))),
          #(
            "notification",
            notify(
              option_target(requested, deleted.session),
              deleted,
              "removed",
            ),
          ),
        ]),
      ))
    }
    _, ["items"] | _, ["items", _] ->
      Error(api.Failure(405, "method_not_allowed", "unsupported work method"))
    _, _ -> Error(api.Failure(404, "not_found", "work resource not found"))
  }
}

fn option_target(
  explicit: Option(String),
  fallback: Option(String),
) -> Option(String) {
  case explicit {
    Some(_) -> explicit
    None -> fallback
  }
}

fn after(
  query: List(#(String, String)),
  workspace: String,
  secret: String,
) -> Result(Int, api.Failure) {
  case list.key_find(query, "next") {
    Error(_) -> Ok(0)
    Ok(token) ->
      api.page_state(secret, "work:" <> workspace, token)
      |> result.replace_error(api.invalid("invalid page token"))
      |> result.try(identifier)
  }
}

fn identifier(id: String) -> Result(Int, api.Failure) {
  case int.parse(id) {
    Ok(id) if id > 0 -> Ok(id)
    _ -> Error(api.invalid("invalid work id"))
  }
}

fn url(id: Int, workspace: String) -> String {
  "/extensions/work/items/"
  <> int.to_string(id)
  <> "?workspace="
  <> uri.percent_encode(workspace)
}

fn etag(item: work.Item) -> String {
  "\"work-"
  <> int.to_string(item.id)
  <> "-"
  <> int.to_string(item.revision)
  <> "\""
}

fn value(item: work.Item) -> json.Json {
  json.object([
    #("id", json.string(int.to_string(item.id))),
    #("workspace", json.string(item.workspace)),
    #("title", json.string(item.title)),
    #("notes", json.string(item.notes)),
    #(
      "parent_id",
      json.nullable(item.parent, fn(id) { json.string(int.to_string(id)) }),
    ),
    #("session_id", json.nullable(item.session, json.string)),
    #("run_id", json.nullable(item.run, json.string)),
    #("status", json.string(work.status_name(item.status))),
    #("revision", json.string(int.to_string(item.revision))),
    #("created_at", json.string(item.created_at)),
    #("updated_at", json.string(item.updated_at)),
  ])
}

fn resource(item: work.Item, workspace: String) -> json.Json {
  json.object([
    #("url", json.string(url(item.id, workspace))),
    #("etag", json.string(etag(item))),
    #("value", value(item)),
  ])
}

fn change(
  item: work.Item,
  workspace: String,
  notification: json.Json,
) -> json.Json {
  bus.invalidate(
    [
      url(item.id, workspace),
      "/extensions/work/items?workspace=" <> uri.percent_encode(workspace),
    ],
    [],
    True,
  )
  json.object([
    #("resource", resource(item, workspace)),
    #("notification", notification),
  ])
}

fn notify(target: Option(String), item: work.Item, verb: String) -> json.Json {
  let outcome = case target {
    None -> #("not_requested", None)
    Some(session) ->
      case
        command.context(session).state(command.Note(
          "work",
          verb <> " work item " <> item.title,
          "<system-note>The user "
            <> verb
            <> " work item #"
            <> int.to_string(item.id)
            <> " · "
            <> item.title
            <> " (status "
            <> work.status_name(item.status)
            <> ") in the shared work ledger.</system-note>",
        ))
      {
        Ok(_) -> #("queued", None)
        Error(_) -> #(
          "failed",
          Some("the session could not accept the work note"),
        )
      }
  }
  json.object([
    #("state", json.string(outcome.0)),
    #("code", case outcome.1 {
      None -> json.null()
      Some(_) -> json.string("notification_failed")
    }),
    #("detail", json.nullable(outcome.1, json.string)),
  ])
}

fn descriptor(items: List(work.Item), workspace: String) -> json.Json {
  client_api.page(client_api.Page(
    title: "work",
    summary: int.to_string(list.length(items)) <> " items",
    empty_state: "nothing tracked yet",
    glance: Some(glance(items, workspace)),
    actions: actions(workspace),
    rows: list.map(items, fn(item) {
      client_api.PageRow(
        id: int.to_string(item.id),
        text: item.title,
        badge: work.status_name(item.status),
        tone: "plain",
        detail: Some(api.content_preview(item.notes, 4000)),
        resource: resource(item, workspace),
      )
    }),
  ))
}

fn actions(workspace: String) -> List(client_api.Action) {
  let query = [#("workspace", client_api.Literal(json.string(workspace)))]
  [
    client_api.Action(
      id: "create",
      label: "add",
      keyboard_hint: "a",
      confirmation: None,
      fields: [
        client_api.Field(
          name: "title",
          label: "title",
          kind: "text",
          required: True,
          default: json.null(),
          choices: [],
          description: "",
          default_binding: None,
        ),
        client_api.Field(
          name: "notes",
          label: "notes",
          kind: "text",
          required: False,
          default: json.null(),
          choices: [],
          description: "",
          default_binding: None,
        ),
        client_api.Field(
          name: "parent_id",
          label: "parent_id",
          kind: "text",
          required: False,
          default: json.null(),
          choices: [],
          description: "",
          default_binding: None,
        ),
      ],
      operation: client_api.Operation(
        id: "createWork",
        method: Post,
        path_template: "/extensions/work/items",
        path: [],
        query: query,
        headers: [],
        body: [
          #("/session_id", client_api.Session("/id")),
          ..client_api.form_body(["title", "notes", "parent_id"])
        ],
        result_schema: json.object([]),
        success_status: Some(201),
      ),
    ),
    client_api.Action(
      id: "edit",
      label: "edit",
      keyboard_hint: "e",
      confirmation: None,
      fields: [
        client_api.Field(
          name: "title",
          label: "title",
          kind: "text",
          required: False,
          default: json.null(),
          choices: [],
          description: "",
          default_binding: Some(client_api.Row("/resource/value/" <> "title")),
        ),
        client_api.Field(
          name: "notes",
          label: "notes",
          kind: "text",
          required: False,
          default: json.null(),
          choices: [],
          description: "",
          default_binding: Some(client_api.Row("/resource/value/" <> "notes")),
        ),
        client_api.Field(
          name: "status",
          label: "status",
          kind: "choice",
          required: False,
          default: json.null(),
          choices: list.map(
            ["open", "active", "blocked", "done", "cancelled"],
            fn(value) { #(json.string(value), value) },
          ),
          description: "",
          default_binding: Some(client_api.Row("/resource/value/" <> "status")),
        ),
      ],
      operation: client_api.Operation(
        id: "patchWork",
        method: Patch,
        path_template: "/extensions/work/items/{item_id}",
        path: [#("item_id", client_api.Row("/resource/value/id"))],
        query: query,
        headers: [#("If-Match", client_api.Row("/resource/etag"))],
        body: [
          #("/notify_session_id", client_api.Session("/id")),
          ..client_api.form_body(["title", "notes", "status"])
        ],
        result_schema: json.object([]),
        success_status: Some(200),
      ),
    ),
    client_api.Action(
      id: "done",
      label: "done",
      keyboard_hint: "d",
      confirmation: None,
      fields: [],
      operation: client_api.Operation(
        id: "patchWork",
        method: Patch,
        path_template: "/extensions/work/items/{item_id}",
        path: [#("item_id", client_api.Row("/resource/value/id"))],
        query: query,
        headers: [#("If-Match", client_api.Row("/resource/etag"))],
        body: [
          #("/status", client_api.Literal(json.string("done"))),
          #("/notify_session_id", client_api.Session("/id")),
        ],
        result_schema: json.object([]),
        success_status: Some(200),
      ),
    ),
    client_api.Action(
      id: "delete",
      label: "remove",
      keyboard_hint: "x",
      confirmation: Some("Delete this item?"),
      fields: [],
      operation: client_api.Operation(
        id: "deleteWork",
        method: Delete,
        path_template: "/extensions/work/items/{item_id}",
        path: [#("item_id", client_api.Row("/resource/value/id"))],
        query: [#("notify_session_id", client_api.Session("/id")), ..query],
        headers: [#("If-Match", client_api.Row("/resource/etag"))],
        body: [],
        result_schema: json.object([]),
        success_status: Some(200),
      ),
    ),
  ]
}

fn glance(items: List(work.Item), workspace: String) -> json.Json {
  let rows =
    items
    |> list.filter(fn(item) {
      item.status != work.Done && item.status != work.Cancelled
    })
    |> list.take(12)
    |> list.map(fn(item) {
      json.object([
        #("id", json.string(int.to_string(item.id))),
        #("text", json.string(api.content_preview(item.title, 64))),
        #("badge", json.string(work.status_name(item.status))),
        #("tone", json.string("plain")),
        #("detail", json.null()),
        #("resource", json.null()),
      ])
    })
  json.object([
    #("extension", json.string("work")),
    #("title", json.string("pending work")),
    #("rows", json.array(rows, fn(row) { row })),
    #(
      "url",
      json.string(
        "/extensions/work/items?workspace=" <> uri.percent_encode(workspace),
      ),
    ),
  ])
}

fn identities(ids: List(Option(String))) -> Result(Nil, api.Failure) {
  case
    list.all(ids, fn(id) {
      case id {
        None -> True
        Some(id) -> id != "" && list.length(string.to_utf_codepoints(id)) <= 512
      }
    })
  {
    True -> Ok(Nil)
    False -> Error(api.invalid("invalid session or run identity"))
  }
}

/// Native composition uses this typed bounded read without executing a command.
pub fn sidebar(
  storage: work.Store,
  _session: String,
  workspace: String,
) -> Result(page.Glance, String) {
  use items <- result.try(
    work.pending(storage, workspace)
    |> result.map_error(fn(error) { failure(error).detail }),
  )
  Ok(page.Glance(
    "pending work",
    list.map(items, fn(item) {
      page.detail_row(
        int.to_string(item.id),
        api.content_preview(item.title, 64),
        work.status_name(item.status),
        case item.status {
          work.Active -> page.Active
          work.Blocked -> page.Warning
          _ -> page.Plain
        },
        "",
      )
    }),
  ))
}

/// Canonical resource addressed by this extension sidebar.
pub fn resource_url(_session: String, workspace: String) -> String {
  "/extensions/work/items?workspace=" <> uri.percent_encode(workspace)
}
