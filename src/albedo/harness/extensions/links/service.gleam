import albedo/daemon/bus
import albedo/daemon/http_api as api
import albedo/harness/client_api
import albedo/harness/command
import albedo/harness/extension
import albedo/harness/extensions/links/ledger
import albedo/harness/extensions/links/presence
import albedo/harness/location
import albedo/harness/ssh
import gleam/dynamic/decode
import gleam/http.{Delete, Get, Post}
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
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
    Ok(response) -> response
    Error(error) -> api.fail(error)
  }
}

fn failure(error: String) -> api.Failure {
  case error {
    "links page changed" ->
      api.invalid("links page changed; read the collection again")
    "links changed" -> api.Failure(412, "precondition_failed", error)
    "already linked" -> api.Failure(409, "already_linked", error)
    "member not linked" -> api.Failure(404, "not_found", error)
    _ -> api.Failure(503, "storage_failed", error)
  }
}

fn workspace(text: String) -> Result(String, api.Failure) {
  use _ <- result.try(case string.byte_size(text) <= 4096 {
    True -> Ok(Nil)
    False -> Error(api.invalid("workspace exceeds its byte limit"))
  })
  location.parse(text)
  |> result.map(location.to_string)
  |> result.map_error(api.invalid)
}

fn dispatch(
  daemon: extension.Daemon,
  path: List(String),
  req: request.Request(BitArray),
) -> Result(response.Response(mist.ResponseData), api.Failure) {
  use events <- result.try(api.wants_events(req))
  use _ <- result.try(case events {
    True -> Error(api.Failure(406, "not_acceptable", "links use JSON"))
    False -> Ok(Nil)
  })
  use query <- result.try(
    api.parameters(req, case req.method {
      Get -> ["workspace", "view", "limit", "next"]
      Post -> ["workspace", "view"]
      Delete -> ["workspace", "view", "member"]
      _ -> []
    }),
  )
  use own <- result.try(
    list.key_find(query, "workspace")
    |> result.replace_error(api.invalid("workspace is required"))
    |> result.try(workspace),
  )
  use group <- result.try(
    ledger.read(daemon.ledger, own) |> result.map_error(failure),
  )
  case req.method, path {
    Get, ["groups"] -> {
      use limit <- result.try(api.integer_parameter(query, "limit", 50, 200))
      use _ <- result.try(case limit > 0 {
        True -> Ok(Nil)
        False -> Error(api.invalid("limit must be positive"))
      })
      let binding = "links:" <> own <> ":" <> int.to_string(group.revision)
      use offset <- result.try(case list.key_find(query, "next") {
        Error(_) -> Ok(0)
        Ok(token) ->
          api.page_state(daemon.home, binding, token)
          |> result.replace_error(api.invalid("invalid page token"))
          |> result.try(fn(text) {
            int.parse(text)
            |> result.replace_error(api.invalid("invalid page token"))
          })
      })
      use group <- result.try(
        ledger.page(daemon.ledger, own, group.revision, offset, limit)
        |> result.map_error(failure),
      )
      let members = api.bounded_items(group.members, 100_000, json.string)
      let next = case group.total > offset + list.length(members) {
        True ->
          json.string(api.page_token(
            daemon.home,
            binding,
            int.to_string(offset + list.length(members)),
          ))
        False -> json.null()
      }
      case list.key_find(query, "view") {
        Ok("configuration") ->
          Ok(
            api.reply(200, configuration(group, members, next))
            |> response.set_header("etag", ledger.etag(group)),
          )
        Error(_) -> {
          let observations = presence.presences(members, 5000)
          let sessions = daemon.sessions()
          let rows =
            list.map2(members, observations, fn(member, observation) {
              let host =
                location.parse(member)
                |> result.replace_error(Nil)
                |> result.try(location.ssh_target)
                |> option.from_result
              json.object([
                #("workspace", json.string(member)),
                #(
                  "session_count",
                  json.int(
                    list.count(sessions, fn(info) { info.cwd == member }),
                  ),
                ),
                #(
                  "host",
                  json.nullable(host, fn(target) {
                    api.host(ssh.observe(target, False))
                  }),
                ),
                #("exists", case observation {
                  presence.Here -> json.bool(True)
                  presence.Gone -> json.bool(False)
                  presence.Unknown(..) -> json.null()
                }),
              ])
            })
          Ok(api.reply(
            200,
            json.object([
              #("configuration_resource", resource(group, members, next)),
              #("page", descriptor(group, members)),
              #("presence", json.array(rows, fn(row) { row })),
              #("next", next),
            ]),
          ))
        }
        _ -> Error(api.invalid("unsupported links view"))
      }
    }
    Post, ["groups"] -> {
      use _ <- result.try(configuration_view(query))
      use _ <- result.try(api.require_match(req, ledger.etag(group)))
      use fields <- result.try(
        api.body(req, ["other_workspace", "other_etag"], {
          use other <- decode.field("other_workspace", decode.string)
          use etag <- decode.field("other_etag", decode.string)
          decode.success(#(other, etag))
        }),
      )
      use other <- result.try(workspace(fields.0))
      use _ <- result.try(
        location.workspace(other)
        |> result.map_error(fn(failure) { api.invalid(failure.detail) }),
      )
      use changed <- result.try(
        ledger.merge(daemon.ledger, own, ledger.etag(group), other, fields.1)
        |> result.map_error(failure),
      )
      let notifications =
        joined(changed.0.members, changed.1.members)
        |> list.append(joined(changed.1.members, changed.0.members))
      Ok(api.reply(200, change(daemon, changed.2, notifications)))
    }
    Delete, ["groups"] -> {
      use _ <- result.try(configuration_view(query))
      use _ <- result.try(api.require_match(req, ledger.etag(group)))
      use member <- result.try(
        list.key_find(query, "member")
        |> result.replace_error(api.invalid("member is required"))
        |> result.try(workspace),
      )
      use changed <- result.try(
        ledger.unlink(daemon.ledger, own, ledger.etag(group), member)
        |> result.map_error(failure),
      )
      let rest = list.filter(changed.0.members, fn(value) { value != member })
      let notes = [
        #(
          member,
          "The user unlinked this workspace from "
            <> string.join(rest, ", ")
            <> ": memory and the work ledger cover only this workspace again. Nothing was deleted.",
        ),
        ..list.map(rest, fn(value) {
          #(
            value,
            "The user unlinked "
              <> member
              <> " from this workspace's group: its memory and work items are no longer read here. Nothing was deleted.",
          )
        })
      ]
      Ok(api.reply(200, change(daemon, changed.1, notes)))
    }
    _, ["groups"] ->
      Error(api.Failure(405, "method_not_allowed", "unsupported links method"))
    _, _ -> Error(api.Failure(404, "not_found", "links resource not found"))
  }
}

fn configuration_view(
  query: List(#(String, String)),
) -> Result(Nil, api.Failure) {
  case list.key_find(query, "view") {
    Ok("configuration") -> Ok(Nil)
    _ -> Error(api.invalid("membership writes require view=configuration"))
  }
}

fn url(workspace: String) -> String {
  "/extensions/links/groups?workspace="
  <> uri.percent_encode(workspace)
  <> "&view=configuration"
}

fn configuration(
  group: ledger.Group,
  members: List(String),
  next: json.Json,
) -> json.Json {
  json.object([
    #("workspace", json.string(group.workspace)),
    #("group_id", json.string(ledger.group_id(group))),
    #("members", json.array(members, json.string)),
    #("revision", json.string(int.to_string(group.revision))),
    #("next", next),
  ])
}

fn resource(
  group: ledger.Group,
  members: List(String),
  next: json.Json,
) -> json.Json {
  json.object([
    #("url", json.string(url(group.workspace))),
    #("etag", json.string(ledger.etag(group))),
    #("value", configuration(group, members, next)),
  ])
}

fn joined(
  members: List(String),
  others: List(String),
) -> List(#(String, String)) {
  let memory = linked_memory(others)
  let text =
    "The user linked this workspace with "
    <> string.join(others, ", ")
    <> ": memory and the work ledger now also read their notes and items. What you write stays in this workspace."
    <> case memory {
      "" -> ""
      _ -> " Their memory, as a new session's snapshot holds it:\n" <> memory
    }
  list.map(members, fn(member) { #(member, text) })
}

fn change(
  daemon: extension.Daemon,
  group: ledger.Group,
  notes: List(#(String, String)),
) -> json.Json {
  let members =
    list.take(group.members, 200) |> api.bounded_items(100_000, json.string)
  bus.invalidate(list.map(notes, fn(note) { url(note.0) }), [], True)
  let targets =
    daemon.sessions()
    |> list.filter_map(fn(info) {
      list.key_find(notes, info.cwd)
      |> result.map(fn(text) { #(info.id, text) })
    })
  let #(outcomes, _) =
    list.fold(targets, #([], 0), fn(state, target) {
      let outcome =
        command.context(target.0).state(command.Note(
          "links",
          "workspace links changed",
          "<system-note>" <> target.1 <> "</system-note>",
        ))
      let outcome =
        json.object([
          #("session_id", json.string(target.0)),
          #(
            "notification",
            json.object([
              #(
                "state",
                json.string(case outcome {
                  Ok(_) -> "queued"
                  Error(_) -> "failed"
                }),
              ),
              #("code", case outcome {
                Ok(_) -> json.null()
                Error(_) -> json.string("notification_failed")
              }),
              #("detail", case outcome {
                Ok(_) -> json.null()
                Error(_) ->
                  json.string("the session could not accept the links note")
              }),
            ]),
          ),
        ])
      case state.1 < 200 {
        True -> #([outcome, ..state.0], state.1 + 1)
        False -> state
      }
    })
  json.object([
    #(
      "resource",
      resource(group, members, case group.total > list.length(members) {
        True ->
          json.string(api.page_token(
            daemon.home,
            "links:" <> group.workspace <> ":" <> int.to_string(group.revision),
            int.to_string(list.length(members)),
          ))
        False -> json.null()
      }),
    ),
    #(
      "notifications",
      json.array(list.reverse(outcomes), fn(outcome) { outcome }),
    ),
    #("notification_count", json.int(list.length(targets))),
    #("truncated", json.bool(list.length(targets) > 200)),
  ])
}

@external(erlang, "albedo_memory", "linked")
fn linked_memory(workspaces: List(String)) -> String

fn descriptor(group: ledger.Group, members: List(String)) -> json.Json {
  client_api.page(page(group, members))
}

pub fn page(group: ledger.Group, members: List(String)) -> client_api.Page {
  let query = [
    #("workspace", client_api.Literal(json.string(group.workspace))),
    #("view", client_api.Literal(json.string("configuration"))),
  ]
  client_api.Page(
    title: "links",
    summary: int.to_string(group.total - 1) <> " linked",
    empty_state: "not linked",
    glance: None,
    actions: [
      client_api.Action(
        id: "merge",
        label: "link",
        keyboard_hint: "a",
        confirmation: None,
        fields: [
          client_api.Field(
            ..client_api.text_field("other_workspace", True),
            label: "workspace",
            description: "path or host:/path",
          ),
        ],
        operation: client_api.Operation(
          ..client_api.operation_defaults(
            "mergeLinkGroups",
            Post,
            "/extensions/links/groups",
            200,
          ),
          query: query,
          headers: [
            #("If-Match", client_api.Literal(json.string(ledger.etag(group)))),
          ],
          body: client_api.form_body(["other_workspace"]),
        ),
      ),
      client_api.Action(
        id: "unlink",
        label: "unlink",
        keyboard_hint: "x",
        confirmation: Some(
          "Unlink this workspace? Its memory and work items will remain.",
        ),
        fields: [],
        operation: client_api.Operation(
          ..client_api.operation_defaults(
            "unlinkWorkspace",
            Delete,
            "/extensions/links/groups",
            200,
          ),
          query: [
            #("member", client_api.Row("/resource/value/member")),
            ..query
          ],
          headers: [#("If-Match", client_api.Row("/resource/etag"))],
        ),
      ),
    ],
    rows: list.map(members, fn(member) {
      client_api.PageRow(
        id: api.etag(member) |> string.replace("\"", ""),
        text: member,
        badge: None,
        tone: "plain",
        detail: None,
        resource: json.object([
          #("url", json.string(url(group.workspace))),
          #("etag", json.string(ledger.etag(group))),
          #("value", json.object([#("member", json.string(member))])),
        ]),
      )
    }),
  )
}
