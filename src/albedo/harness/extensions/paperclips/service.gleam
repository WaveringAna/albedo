import albedo/daemon/bus
import albedo/daemon/http_api as api
import albedo/harness/client_api
import albedo/harness/extension
import albedo/harness/extensions/paperclips/ledger
import albedo/harness/extensions/paperclips/notifications
import albedo/harness/extensions/paperclips/presentation
import albedo/harness/page
import gleam/dict
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

fn failure(error: ledger.Error) -> api.Failure {
  case error {
    ledger.Invalid(detail) -> api.invalid(detail)
    ledger.NotFound -> api.Failure(404, "not_found", "paperclip not found")
    ledger.Conflict ->
      api.Failure(412, "precondition_failed", "paperclip changed")
    ledger.Storage(detail) -> api.Failure(503, "storage_failed", detail)
  }
}

fn identifier(text: String) -> Result(Int, api.Failure) {
  case int.parse(text) {
    Ok(id) if id > 0 -> Ok(id)
    _ -> Error(api.invalid("invalid paperclip id"))
  }
}

fn dispatch(
  daemon: extension.Daemon,
  path: List(String),
  req: request.Request(BitArray),
) -> Result(response.Response(mist.ResponseData), api.Failure) {
  use events <- result.try(api.wants_events(req))
  use _ <- result.try(case events {
    True -> Error(api.Failure(406, "not_acceptable", "paperclips use JSON"))
    False -> Ok(Nil)
  })
  use query <- result.try(
    api.parameters(req, case req.method, path {
      Get, ["items"] -> ["limit", "next"]
      _, _ -> []
    }),
  )
  case req.method, path {
    Get, ["items"] -> {
      use limit <- result.try(api.integer_parameter(query, "limit", 50, 200))
      use before <- result.try(case list.key_find(query, "next") {
        Error(_) -> Ok(0)
        Ok(token) ->
          api.page_state(daemon.home, "paperclips", token)
          |> result.replace_error(api.invalid("invalid page token"))
          |> result.try(identifier)
      })
      use items <- result.try(
        ledger.page(daemon.ledger, before, limit) |> result.map_error(failure),
      )
      use labels <- result.try(
        ledger.session_labels(
          daemon.ledger,
          items
            |> list.flat_map(fn(item) {
              option.values([item.session, item.resolved_by])
            })
            |> list.unique,
        )
        |> result.map_error(failure),
      )
      let supplied = list.length(items)
      let encoded = api.bounded_items(items, 350_000, 0, resource)
      let items = list.map(encoded, fn(item) { item.0 })
      let next =
        api.next_page(
          daemon.home,
          "paperclips",
          supplied == limit || list.length(items) < supplied,
          list.last(items) |> result.map(fn(item) { int.to_string(item.id) }),
        )
      Ok(api.reply(
        200,
        json.object([
          #("items", json.array(encoded, fn(item) { item.1 })),
          #("next", next),
          #("page", descriptor(encoded, labels)),
        ]),
      ))
    }
    Post, ["items"] -> {
      use fields <- result.try(
        api.body(
          req,
          ["topic", "title", "message", "suggestion", "session_id", "workspace"],
          {
            use topic <- decode.optional_field("topic", "other", decode.string)
            use title <- decode.optional_field("title", "", decode.string)
            use message <- decode.field("message", decode.string)
            use suggestion <- decode.optional_field(
              "suggestion",
              "",
              decode.string,
            )
            use session <- decode.optional_field(
              "session_id",
              None,
              decode.optional(decode.string),
            )
            use workspace <- decode.optional_field(
              "workspace",
              None,
              decode.optional(decode.string),
            )
            decode.success(#(
              topic,
              title,
              message,
              suggestion,
              session,
              workspace,
            ))
          },
        ),
      )
      use _ <- result.try(text_limits(fields.1, fields.2, fields.3))
      use topic <- result.try(
        ledger.parse_topic(fields.0) |> result.map_error(failure),
      )
      use item <- result.try(
        ledger.create(
          daemon.ledger,
          case fields.5 {
            None -> ""
            Some(value) -> value
          },
          topic,
          fields.1,
          fields.2,
          fields.3,
          fields.4,
        )
        |> result.map_error(failure),
      )
      Ok(
        api.reply(201, change(item, notification("not_requested", None)))
        |> response.set_header("location", url(item.id)),
      )
    }
    Get, ["items", id] -> {
      use id <- result.try(identifier(id))
      use item <- result.try(
        ledger.get(daemon.ledger, id) |> result.map_error(failure),
      )
      Ok(api.reply(200, value(item)) |> response.set_header("etag", etag(item)))
    }
    Patch, ["items", id] -> {
      use id <- result.try(identifier(id))
      use current <- result.try(
        ledger.get(daemon.ledger, id) |> result.map_error(failure),
      )
      use _ <- result.try(api.require_match(req, etag(current)))
      use fields <- result.try(
        api.body(req, ["status", "reply", "resolution"], {
          use status <- decode.optional_field(
            "status",
            None,
            decode.map(decode.string, Some),
          )
          use reply <- decode.optional_field(
            "reply",
            None,
            decode.map(decode.string, Some),
          )
          use resolution <- decode.optional_field(
            "resolution",
            current.resolution,
            decode.string,
          )
          decode.success(#(status, reply, resolution))
        }),
      )
      use status <- result.try(case fields.0, fields.1 {
        Some("resolved"), None -> Ok(ledger.Resolved)
        Some("dismissed"), None -> Ok(ledger.Dismissed)
        Some("acknowledged"), _ | None, Some(_) -> Ok(ledger.Acknowledged)
        None, None -> Ok(current.status)
        _, _ ->
          Error(api.invalid(
            "reply cannot accompany resolved or dismissed status",
          ))
      })
      let reply = case fields.1 {
        None -> current.reply
        Some(reply) -> reply
      }
      use _ <- result.try(
        case
          string.byte_size(reply) <= 16_384
          && string.byte_size(fields.2) <= 16_384
        {
          True -> Ok(Nil)
          False -> Error(api.invalid("paperclip text exceeds its byte limit"))
        },
      )
      use changed <- result.try(
        ledger.patch(
          daemon.ledger,
          ledger.Vent(
            ..current,
            status: status,
            reply: reply,
            resolution: fields.2,
          ),
        )
        |> result.map_error(failure),
      )
      let notification = case fields.1, current.session {
        None, _ -> notification("not_requested", None)
        Some(reply), Some(_) ->
          case notifications.reply(current, reply) {
            Ok(_) -> notification("queued", None)
            Error(_) ->
              notification(
                "failed",
                Some("the session could not accept the reply"),
              )
          }
        Some(_), None ->
          notification(
            "failed",
            Some("the paperclip records no session to answer"),
          )
      }
      Ok(api.reply(200, change(changed, notification)))
    }
    Delete, ["items", id] -> {
      use id <- result.try(identifier(id))
      use current <- result.try(
        ledger.get(daemon.ledger, id) |> result.map_error(failure),
      )
      use _ <- result.try(api.require_match(req, etag(current)))
      use _ <- result.try(
        ledger.delete_observed(daemon.ledger, id, current.revision)
        |> result.map_error(failure),
      )
      bus.invalidate([url(id), "/extensions/paperclips/items"], [], True)
      Ok(api.reply(
        200,
        json.object([
          #("id", json.string(int.to_string(id))),
          #("notification", notification("not_requested", None)),
        ]),
      ))
    }
    _, ["items"] | _, ["items", _] ->
      Error(api.Failure(
        405,
        "method_not_allowed",
        "unsupported paperclips method",
      ))
    _, _ ->
      Error(api.Failure(404, "not_found", "paperclips resource not found"))
  }
}

fn text_limits(
  title: String,
  message: String,
  suggestion: String,
) -> Result(Nil, api.Failure) {
  case
    string.byte_size(title) <= 4096
    && string.byte_size(message) <= 32_768
    && string.byte_size(suggestion) <= 16_384
    && string.trim(message) != ""
  {
    True -> Ok(Nil)
    False ->
      Error(api.invalid("paperclip text exceeds its limit or message is empty"))
  }
}

fn url(id: Int) -> String {
  "/extensions/paperclips/items/" <> int.to_string(id)
}

fn etag(item: ledger.Vent) -> String {
  "\"paperclip-"
  <> int.to_string(item.id)
  <> "-"
  <> int.to_string(item.revision)
  <> "\""
}

fn value(item: ledger.Vent) -> json.Json {
  json.object([
    #("id", json.string(int.to_string(item.id))),
    #("topic", json.string(ledger.topic_name(item.topic))),
    #(
      "title",
      json.string(case item.title {
        "" -> api.content_preview(presentation.title(item), 1000)
        title -> title
      }),
    ),
    #("message", json.string(item.message)),
    #("suggestion", json.string(item.suggestion)),
    #("reply", json.string(item.reply)),
    #("status", json.string(ledger.status_name(item.status))),
    #("session_id", json.nullable(item.session, json.string)),
    #("workspace", case item.cwd {
      "" -> json.null()
      cwd -> json.string(cwd)
    }),
    #("created_at", json.string(item.created_at)),
    #("resolution", json.string(item.resolution)),
    #("resolving_session_id", json.nullable(item.resolved_by, json.string)),
    #("revision", json.string(int.to_string(item.revision))),
    #("updated_at", json.string(item.updated_at)),
  ])
}

fn resource(item: ledger.Vent) -> json.Json {
  json.object([
    #("url", json.string(url(item.id))),
    #("etag", json.string(etag(item))),
    #("value", value(item)),
  ])
}

fn change(item: ledger.Vent, notification: json.Json) -> json.Json {
  bus.invalidate([url(item.id), "/extensions/paperclips/items"], [], True)
  json.object([#("resource", resource(item)), #("notification", notification)])
}

fn notification(state: String, detail: Option(String)) -> json.Json {
  json.object([
    #("state", json.string(state)),
    #("code", case detail {
      None -> json.null()
      Some(_) -> json.string("notification_failed")
    }),
    #("detail", json.nullable(detail, json.string)),
  ])
}

fn descriptor(
  encoded: List(#(ledger.Vent, json.Json)),
  labels: dict.Dict(String, String),
) -> json.Json {
  let items = list.map(encoded, fn(item) { item.0 })
  client_api.page(client_api.Page(
    title: "paperclips",
    summary: int.to_string(list.length(items)) <> " items",
    empty_state: "no paperclips",
    glance: Some(glance(items)),
    actions: actions(),
    rows: list.map(encoded, fn(entry) {
      let item = entry.0
      client_api.PageRow(
        id: int.to_string(item.id),
        text: api.content_preview(
          case item.title {
            "" -> item.message
            title -> title
          },
          1000,
        ),
        badge: Some(ledger.status_name(item.status)),
        tone: "plain",
        detail: Some(api.content_preview(
          presentation.detail(labels, item),
          4000,
        )),
        resource: entry.1,
      )
    }),
  ))
}

fn actions() -> List(client_api.Action) {
  [
    client_api.Action(
      id: "create",
      label: "add",
      keyboard_hint: "a",
      confirmation: None,
      fields: [
        client_api.choice_field("topic", False, [
          "harness", "workflow", "bug", "user", "other",
        ]),
        client_api.text_field("title", False),
        client_api.text_field("message", True),
        client_api.text_field("suggestion", False),
      ],
      operation: client_api.Operation(
        ..client_api.operation_defaults(
          "createPaperclips",
          Post,
          "/extensions/paperclips/items",
          201,
        ),
        body: client_api.form_body(["topic", "title", "message", "suggestion"]),
      ),
    ),
    client_api.Action(
      id: "reply",
      label: "reply",
      keyboard_hint: "n",
      confirmation: None,
      fields: [
        client_api.Field(
          ..client_api.text_field("reply", True),
          default_binding: Some(client_api.Row("/resource/value/" <> "reply")),
        ),
      ],
      operation: client_api.Operation(
        ..client_api.operation_defaults(
          "patchPaperclips",
          Patch,
          "/extensions/paperclips/items/{item_id}",
          200,
        ),
        path: [#("item_id", client_api.Row("/resource/value/id"))],
        headers: [#("If-Match", client_api.Row("/resource/etag"))],
        body: client_api.form_body(["reply"]),
      ),
    ),
    client_api.Action(
      id: "acknowledge",
      label: "acknowledge",
      keyboard_hint: "a",
      confirmation: None,
      fields: [],
      operation: client_api.Operation(
        ..client_api.operation_defaults(
          "patchPaperclips",
          Patch,
          "/extensions/paperclips/items/{item_id}",
          200,
        ),
        path: [#("item_id", client_api.Row("/resource/value/id"))],
        headers: [#("If-Match", client_api.Row("/resource/etag"))],
        body: [#("/status", client_api.Literal(json.string("acknowledged")))],
      ),
    ),
    client_api.Action(
      id: "resolve",
      label: "resolve",
      keyboard_hint: "r",
      confirmation: None,
      fields: [
        client_api.Field(
          ..client_api.text_field("resolution", False),
          default_binding: Some(client_api.Row(
            "/resource/value/" <> "resolution",
          )),
        ),
      ],
      operation: client_api.Operation(
        ..client_api.operation_defaults(
          "patchPaperclips",
          Patch,
          "/extensions/paperclips/items/{item_id}",
          200,
        ),
        path: [#("item_id", client_api.Row("/resource/value/id"))],
        headers: [#("If-Match", client_api.Row("/resource/etag"))],
        body: [
          #("/status", client_api.Literal(json.string("resolved"))),
          ..client_api.form_body(["resolution"])
        ],
      ),
    ),
    client_api.Action(
      id: "dismiss",
      label: "dismiss",
      keyboard_hint: "d",
      confirmation: None,
      fields: [],
      operation: client_api.Operation(
        ..client_api.operation_defaults(
          "patchPaperclips",
          Patch,
          "/extensions/paperclips/items/{item_id}",
          200,
        ),
        path: [#("item_id", client_api.Row("/resource/value/id"))],
        headers: [#("If-Match", client_api.Row("/resource/etag"))],
        body: [#("/status", client_api.Literal(json.string("dismissed")))],
      ),
    ),
    client_api.Action(
      id: "delete",
      label: "delete",
      keyboard_hint: "x",
      confirmation: Some("Delete this item?"),
      fields: [],
      operation: client_api.Operation(
        ..client_api.operation_defaults(
          "deletePaperclips",
          Delete,
          "/extensions/paperclips/items/{item_id}",
          200,
        ),
        path: [#("item_id", client_api.Row("/resource/value/id"))],
        headers: [#("If-Match", client_api.Row("/resource/etag"))],
      ),
    ),
  ]
}

fn glance(items: List(ledger.Vent)) -> json.Json {
  let rows =
    items
    |> list.filter(fn(item) { item.status == ledger.Open })
    |> list.take(12)
    |> list.map(fn(item) {
      json.object([
        #("id", json.string(int.to_string(item.id))),
        #(
          "text",
          json.string(api.content_preview(
            case item.title {
              "" -> item.message
              title -> title
            },
            64,
          )),
        ),
        #("badge", json.string(ledger.status_name(item.status))),
        #("tone", json.string("plain")),
        #("detail", json.null()),
        #("resource", json.null()),
      ])
    })
  json.object([
    #("extension", json.string("paperclips")),
    #("title", json.string("paperclips")),
    #("rows", json.array(rows, fn(row) { row })),
    #("url", json.string("/extensions/paperclips/items")),
  ])
}

/// Native composition uses this typed bounded read without executing a command.
pub fn sidebar(
  storage: ledger.Store,
  _session: String,
  _workspace: String,
) -> Result(page.Glance, String) {
  use items <- result.try(
    ledger.open(storage)
    |> result.map_error(fn(error) { failure(error).detail }),
  )
  Ok(page.Glance(
    "open vents",
    list.map(items, fn(item) {
      page.detail_row(
        int.to_string(item.id),
        api.content_preview(presentation.title(item), 64),
        ledger.status_name(item.status),
        page.Warning,
        "",
      )
    }),
  ))
}

/// Canonical resource addressed by this extension sidebar.
pub fn resource_url(_session: String, _workspace: String) -> String {
  "/extensions/paperclips/items"
}
