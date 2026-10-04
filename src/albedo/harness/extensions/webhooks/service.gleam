//// Bearer management and raw signed intake share one canonical mount.

import albedo/daemon/bus
import albedo/daemon/http_api as api
import albedo/daemon/mail
import albedo/harness/extension
import albedo/harness/extensions/webhooks/ledger as hooks
import gleam/bit_array
import gleam/dynamic/decode
import gleam/http.{type Method, Delete, Get, Patch, Post}
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

pub fn admission(path: List(String), method: Method) -> extension.Admission {
  extension.Admission(
    case method, path {
      Post, ["hooks", _, "deliveries"] -> extension.SignedBody
      _, _ -> extension.DaemonToken
    },
    65_536,
  )
}

pub fn handle(
  daemon: extension.Daemon,
  path: List(String),
  req: request.Request(BitArray),
  _live: request.Request(mist.Connection),
) -> response.Response(mist.ResponseData) {
  case dispatch(daemon, path, req) {
    Ok(reply) -> reply
    Error(error) -> api.fail(error)
  }
}

fn failure(error: hooks.Error) -> api.Failure {
  case error {
    hooks.Invalid("name already used" as detail) ->
      api.Failure(409, "name_conflict", detail)
    hooks.Invalid("session webhook limit reached" as detail) ->
      api.Failure(409, "hook_limit", detail)
    hooks.Invalid("webhook body exceeds 64 KiB" as detail) ->
      api.Failure(413, "body_too_large", detail)
    hooks.Invalid(detail) -> api.invalid(detail)
    hooks.NotFound ->
      api.Failure(404, "not_found", "hook, session, or delivery not found")
    hooks.Denied ->
      api.Failure(
        403,
        "permission_denied",
        "agent webhook management is disabled",
      )
    hooks.Conflict ->
      api.Failure(412, "precondition_failed", "webhook configuration changed")
    hooks.Unauthorized ->
      api.Failure(
        403,
        "invalid_signature",
        "missing or invalid webhook signature",
      )
    hooks.Overloaded -> api.Failure(429, "inbox_full", "webhook inbox is full")
    hooks.Storage(detail) -> api.Failure(503, "storage_failed", detail)
  }
}

fn dispatch(
  daemon: extension.Daemon,
  path: List(String),
  req: request.Request(BitArray),
) -> Result(response.Response(mist.ResponseData), api.Failure) {
  use _ <- result.try(api.accepts_json(req))
  use query <- result.try(
    api.parameters(req, case req.method, path {
      Get, ["hooks"] -> ["session_id", "limit", "next"]
      Get, ["hooks", _] | Patch, ["hooks", _] | Delete, ["hooks", _] -> ["view"]
      Get, ["hooks", _, "deliveries"] -> ["state", "limit", "next"]
      _, _ -> []
    }),
  )
  case req.method, path {
    Get, ["hooks"] -> {
      use limit <- result.try(page_limit(query))
      let session = list.key_find(query, "session_id") |> option.from_result
      use _ <- result.try(case session {
        Some(value) ->
          case
            string.trim(value) != "",
            api.scalar_prefix(value, 256) == value
          {
            True, True -> Ok(Nil)
            _, _ ->
              Error(api.invalid("session_id must contain 1 to 256 characters"))
          }
        None -> Ok(Nil)
      })
      use after <- result.try(page_after(
        daemon.home,
        query,
        "hooks:" <> option.unwrap(session, ""),
      ))
      use found <- result.try(
        hooks.list_page(daemon.ledger, session, after, limit + 1)
        |> result.map_error(failure),
      )
      let encoded =
        api.bounded_items(
          list.take(found, limit),
          api.response_limit - 1025,
          1,
          hook_view(req, _),
        )
      let items = list.map(encoded, fn(item) { item.0 })
      let next =
        api.next_page(
          daemon.home,
          "hooks:" <> option.unwrap(session, ""),
          list.length(items) < list.length(found),
          list.last(items) |> result.map(fn(item) { item.hook.id }),
        )
      Ok(api.reply(
        200,
        json.object([
          #("items", json.array(encoded, fn(item) { item.1 })),
          #("next", next),
        ]),
      ))
    }
    Post, ["hooks"] -> {
      use fields <- result.try(
        api.body(
          req,
          [
            "session_id",
            "name",
            "enabled",
            "signature_header",
            "signature_prefix",
            "secret",
          ],
          {
            use session <- decode.field(
              "session_id",
              api.bounded_string(256, True),
            )
            use name <- decode.field("name", decode.string)
            use enabled <- decode.optional_field("enabled", True, decode.bool)
            use header <- decode.optional_field(
              "signature_header",
              "x-albedo-signature",
              decode.string,
            )
            use prefix <- decode.optional_field(
              "signature_prefix",
              "sha256=",
              decode.string,
            )
            use secret <- decode.optional_field(
              "secret",
              None,
              decode.string |> decode.map(Some),
            )
            decode.success(#(
              session,
              hooks.Definition(name, enabled, header, prefix),
              secret,
            ))
          },
        ),
      )
      use provisioned <- result.try(
        hooks.create_configured(
          daemon.ledger,
          hooks.Human,
          fields.0,
          fields.1,
          fields.2,
        )
        |> result.map_error(fn(error) {
          case error {
            hooks.Conflict ->
              api.Failure(
                409,
                "hook_conflict",
                "hook name already exists or session hook limit reached",
              )
            _ -> failure(error)
          }
        }),
      )
      changed(provisioned.hook)
      Ok(
        api.reply(201, change(provisioned.hook, Some(provisioned.secret)))
        |> response.set_header(
          "location",
          configuration_url(provisioned.hook.id),
        ),
      )
    }
    Get, ["hooks", id] -> {
      use hook <- result.try(
        hooks.find(daemon.ledger, id) |> result.map_error(failure),
      )
      use view <- result.try(configuration_view(query, False))
      use value <- result.try(case view {
        True -> Ok(configuration(hook))
        False -> {
          use pending <- result.try(
            hooks.pending_count(daemon.ledger, hook.session, id)
            |> result.map_error(failure),
          )
          use deferred <- result.try(
            hooks.last_failure(daemon.ledger, hook.session, id)
            |> result.map_error(failure),
          )
          Ok(hook_view(req, hooks.Overview(hook, pending, deferred)))
        }
      })
      Ok(api.reply(200, value) |> response.set_header("etag", hook_etag(hook)))
    }
    Patch, ["hooks", id] -> {
      use _ <- result.try(configuration_view(query, True))
      use current <- result.try(
        hooks.find(daemon.ledger, id) |> result.map_error(failure),
      )
      use _ <- result.try(api.require_match(req, hook_etag(current)))
      use definition <- result.try(
        api.body(
          req,
          ["name", "enabled", "signature_header", "signature_prefix"],
          {
            use name <- decode.optional_field(
              "name",
              current.name,
              decode.string,
            )
            use enabled <- decode.optional_field(
              "enabled",
              current.enabled,
              decode.bool,
            )
            use header <- decode.optional_field(
              "signature_header",
              current.signature_header,
              decode.string,
            )
            use prefix <- decode.optional_field(
              "signature_prefix",
              current.signature_prefix,
              decode.string,
            )
            decode.success(hooks.Definition(name, enabled, header, prefix))
          },
        ),
      )
      use hook <- result.try(
        hooks.patch(daemon.ledger, hooks.Human, current, definition)
        |> result.map_error(failure),
      )
      changed(hook)
      Ok(api.reply(200, change(hook, None)))
    }
    Delete, ["hooks", id] -> {
      use _ <- result.try(configuration_view(query, True))
      use _ <- result.try(api.empty_body(req))
      use current <- result.try(
        hooks.find(daemon.ledger, id) |> result.map_error(failure),
      )
      use _ <- result.try(api.require_match(req, hook_etag(current)))
      use hook <- result.try(
        hooks.delete(
          daemon.ledger,
          hooks.Human,
          current.session,
          id,
          current.revision,
        )
        |> result.map_error(failure),
      )
      changed(hook)
      Ok(api.reply(
        200,
        json.object([
          #("id", json.string(id)),
          #("notification", notification()),
        ]),
      ))
    }
    Post, ["hooks", id, "secret"] -> {
      use current <- result.try(
        hooks.find(daemon.ledger, id) |> result.map_error(failure),
      )
      use _ <- result.try(api.require_match(req, hook_etag(current)))
      use secret <- result.try(api.body(
        req,
        ["secret"],
        decode.optional_field(
          "secret",
          None,
          decode.string |> decode.map(Some),
          decode.success,
        ),
      ))
      use provisioned <- result.try(
        hooks.rotate(
          daemon.ledger,
          hooks.Human,
          current.session,
          id,
          current.revision,
          secret,
        )
        |> result.map_error(failure),
      )
      changed(provisioned.hook)
      Ok(api.reply(200, change(provisioned.hook, Some(provisioned.secret))))
    }
    Post, ["hooks", id, "deliveries"] -> {
      let event_key =
        request.get_header(req, "x-albedo-event-id") |> option.from_result
      use delivery <- result.try(
        hooks.accept(daemon.ledger, id, req.headers, req.body, event_key)
        |> result.map_error(fn(error) {
          case error {
            hooks.Conflict ->
              api.Failure(
                409,
                "event_conflict",
                "event id already used for a different body",
              )
            _ -> failure(error)
          }
        }),
      )
      mail.waiting()
      bus.invalidate(
        [
          "/extensions/webhooks/hooks/" <> id,
          "/extensions/webhooks/hooks/" <> id <> "/deliveries",
        ],
        [],
        False,
      )
      Ok(api.reply(202, json.object([#("delivery_id", json.string(delivery))])))
    }
    Get, ["hooks", id, "deliveries"] -> {
      use limit <- result.try(page_limit(query))
      let state = list.key_find(query, "state") |> result.unwrap("all")
      use _ <- result.try(
        case list.contains(["pending", "delivered", "all"], state) {
          True -> Ok(Nil)
          False -> Error(api.invalid("invalid delivery state"))
        },
      )
      let binding = "deliveries:" <> id <> ":" <> state
      use after <- result.try(page_after(daemon.home, query, binding))
      use found <- result.try(
        hooks.receipts(daemon.ledger, id, state, after, limit + 1)
        |> result.map_error(failure),
      )
      let encoded =
        api.bounded_items(
          list.take(found, limit),
          api.response_limit - 1025,
          1,
          receipt,
        )
      let items = list.map(encoded, fn(item) { item.0 })
      let next =
        api.next_page(
          daemon.home,
          binding,
          list.length(items) < list.length(found),
          list.last(items) |> result.map(fn(item) { item.id }),
        )
      Ok(api.reply(
        200,
        json.object([
          #("items", json.array(encoded, fn(item) { item.1 })),
          #("next", next),
        ]),
      ))
    }
    Get, ["deliveries", id] -> {
      use #(item, body) <- result.try(
        hooks.receipt(daemon.ledger, id) |> result.map_error(failure),
      )
      let #(encoding, data) = case bit_array.to_string(body) {
        Ok(text) -> #("utf8", text)
        Error(_) -> #("base64", base64(body))
      }
      Ok(api.reply(
        200,
        json.object(
          list.append(receipt_fields(item), [
            #(
              "payload",
              json.object([
                #("encoding", json.string(encoding)),
                #("data", json.string(data)),
              ]),
            ),
          ]),
        ),
      ))
    }
    Get, ["permissions", session] -> {
      use permission <- result.try(
        hooks.permission(daemon.ledger, session) |> result.map_error(failure),
      )
      Ok(
        api.reply(200, permission_value(permission))
        |> response.set_header("etag", permission_etag(permission)),
      )
    }
    Patch, ["permissions", session] -> {
      use current <- result.try(
        hooks.permission(daemon.ledger, session) |> result.map_error(failure),
      )
      use _ <- result.try(api.require_match(req, permission_etag(current)))
      use enabled <- result.try(api.body(
        req,
        ["agent_manage"],
        decode.optional_field(
          "agent_manage",
          current.agent_manage,
          decode.bool,
          decode.success,
        ),
      ))
      use permission <- result.try(
        hooks.patch_permission(daemon.ledger, current, enabled)
        |> result.map_error(failure),
      )
      bus.invalidate(
        ["/extensions/webhooks/permissions/" <> session],
        [session],
        False,
      )
      Ok(api.reply(
        200,
        json.object([
          #(
            "resource",
            json.object([
              #(
                "url",
                json.string("/extensions/webhooks/permissions/" <> session),
              ),
              #("etag", json.string(permission_etag(permission))),
              #("value", permission_value(permission)),
            ]),
          ),
          #("notification", notification()),
        ]),
      ))
    }
    _, ["hooks"]
    | _, ["hooks", _]
    | _, ["hooks", _, "secret"]
    | _, ["hooks", _, "deliveries"]
    | _, ["deliveries", _]
    | _, ["permissions", _]
    ->
      Error(api.Failure(
        405,
        "method_not_allowed",
        "method not allowed for webhook resource",
      ))
    _, _ -> Error(api.Failure(404, "not_found", "webhook route not found"))
  }
}

fn page_limit(query: List(#(String, String))) -> Result(Int, api.Failure) {
  use limit <- result.try(api.integer_parameter(query, "limit", 50, 200))
  case limit > 0 {
    True -> Ok(limit)
    False -> Error(api.invalid("limit must be positive"))
  }
}

fn page_after(
  home: String,
  query: List(#(String, String)),
  binding: String,
) -> Result(String, api.Failure) {
  case list.key_find(query, "next") {
    Error(_) -> Ok("")
    Ok(token) ->
      api.page_state(home, binding, token) |> result.map_error(api.invalid)
  }
}

fn configuration_view(
  query: List(#(String, String)),
  required: Bool,
) -> Result(Bool, api.Failure) {
  case list.key_find(query, "view"), required {
    Ok("configuration"), _ -> Ok(True)
    Error(_), False -> Ok(False)
    _, _ -> Error(api.invalid("view=configuration is required"))
  }
}

fn configuration_url(id: String) -> String {
  "/extensions/webhooks/hooks/" <> id <> "?view=configuration"
}

fn revision(hook: hooks.Hook) -> String {
  "hook-revision-" <> int.to_string(hook.revision)
}

fn hook_etag(hook: hooks.Hook) -> String {
  api.etag(json.to_string(configuration(hook)))
}

fn configuration(hook: hooks.Hook) -> json.Json {
  json.object([
    #("id", json.string(hook.id)),
    #("session_id", json.string(hook.session)),
    #("name", json.string(hook.name)),
    #("enabled", json.bool(hook.enabled)),
    #("signature_header", json.string(hook.signature_header)),
    #("signature_prefix", json.string(hook.signature_prefix)),
    #("revision", json.string(revision(hook))),
  ])
}

fn resource(hook: hooks.Hook) -> json.Json {
  json.object([
    #("url", json.string(configuration_url(hook.id))),
    #("etag", json.string(hook_etag(hook))),
    #("value", configuration(hook)),
  ])
}

fn hook_view(
  req: request.Request(BitArray),
  overview: hooks.Overview,
) -> json.Json {
  let base = request.to_uri(req)
  let delivery_url =
    uri.to_string(
      uri.Uri(
        ..base,
        path: "/extensions/webhooks/hooks/" <> overview.hook.id <> "/deliveries",
        query: None,
        fragment: None,
      ),
    )
  json.object([
    #("configuration_resource", resource(overview.hook)),
    #("delivery_url", json.string(delivery_url)),
    #("pending_count", json.int(overview.pending)),
    #(
      "deferral_reason",
      json.nullable(overview.deferral, api.reason("delivery_deferred", _)),
    ),
  ])
}

fn notification() -> json.Json {
  json.object([
    #("state", json.string("not_requested")),
    #("code", json.null()),
    #("detail", json.null()),
  ])
}

fn change(hook: hooks.Hook, secret: Option(String)) -> json.Json {
  let fields = [
    #("resource", resource(hook)),
    #("notification", notification()),
  ]
  json.object(case secret {
    None -> fields
    Some(value) -> [#("secret", json.string(value)), ..fields]
  })
}

fn changed(hook: hooks.Hook) -> Nil {
  bus.invalidate(
    ["/extensions/webhooks/hooks", configuration_url(hook.id)],
    [hook.session],
    False,
  )
}

fn permission_value(permission: hooks.Permission) -> json.Json {
  json.object([
    #("session_id", json.string(permission.session)),
    #("agent_manage", json.bool(permission.agent_manage)),
    #(
      "revision",
      json.string("hook-permission-" <> int.to_string(permission.revision)),
    ),
  ])
}

fn permission_etag(permission: hooks.Permission) -> String {
  api.etag(json.to_string(permission_value(permission)))
}

fn receipt_fields(item: hooks.Receipt) -> List(#(String, json.Json)) {
  [
    #("id", json.string(item.id)),
    #("hook_id", json.string(item.hook)),
    #("session_id", json.string(item.session)),
    #("received_at", json.string(item.received_at)),
    #("delivered_at", json.nullable(item.delivered_at, json.string)),
    #("attempts", json.int(item.attempts)),
    #(
      "deferral_reason",
      json.nullable(item.deferral, api.reason("delivery_deferred", _)),
    ),
  ]
}

fn receipt(item: hooks.Receipt) -> json.Json {
  json.object(receipt_fields(item))
}

@external(erlang, "albedo_webhooks", "base64")
fn base64(body: BitArray) -> String
