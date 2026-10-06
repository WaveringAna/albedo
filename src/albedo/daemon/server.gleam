import albedo/daemon/active_output
import albedo/daemon/configuration
import albedo/daemon/http_active_output
import albedo/daemon/http_api
import albedo/daemon/http_auth
import albedo/daemon/http_coding
import albedo/daemon/http_resources
import albedo/daemon/http_session_collection
import albedo/daemon/http_sessions
import albedo/daemon/http_transcript
import albedo/daemon/http_wire
import albedo/daemon/listener
import albedo/daemon/quota
import albedo/daemon/registry.{type Config, type Message, Config, List, Shutdown}
import albedo/daemon/settings
import albedo/harness/credentials
import albedo/harness/extension
import albedo/harness/runtime
import albedo/harness/usage_feed
import gleam/bit_array
import gleam/bytes_tree
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/http.{Delete, Get, Options, Patch, Post, Put}
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision
import gleam/result
import gleam/string
import mist
import sqlight

type HttpBoundary {
  HttpBoundary(
    instance_id: String,
    port: Int,
    origins: List(String),
    hosts: List(String),
  )
}

pub fn start(config: Config, port: Int) -> Result(Int, String) {
  // Storage is the one thing this daemon cannot run without, so the runtime
  // that owns it stays linked to the daemon; everything above it is supervised.
  use host <- result.try(
    runtime.start(config.home <> "/albedo.sqlite")
    |> result.replace_error("could not start runtime"),
  )
  use _ <- result.try(registry.prepare_storage(config, host))
  active_output.maintenance(config.home)
  let name = process.new_name("albedo_registry")
  use _ <- result.try(
    supervisor.new(supervisor.OneForOne)
    |> supervisor.restart_tolerance(intensity: 10, period: 60)
    |> supervisor.add(
      supervision.worker(fn() { registry.start(config, host, name) }),
    )
    // One daemon-wide quota poller: every account it can see, on its own
    // cadence, recorded as raw readings.
    |> supervisor.add(
      supervision.worker(fn() {
        quota.start(config.home, runtime.ledger(host), usage_feed.fetch)
      }),
    )
    |> supervisor.start
    |> result.map_error(string.inspect),
  )
  // A name, not a pid: handlers keep reaching the registry across restarts.
  runtime.resume_kernels(host, registry.rewarm(process.named_subject(name), _))
  let registry = process.named_subject(name)
  // A restarted listener comes back on the port it was built with, so port 0
  // would bring it back somewhere daemon.json does not say: pick it once.
  let port = case port {
    0 -> free_port()
    _ -> port
  }
  let instance_id = http_api.instance_id()
  let boundary =
    HttpBoundary(
      instance_id,
      port,
      configured_list("ALBEDO_HTTP_ORIGINS"),
      configured_list("ALBEDO_HTTP_HOSTS"),
    )
  use _ <- result.try(
    listener.keep(port, fn() {
      mist.new(route(config, registry, boundary, _))
      |> mist.bind("127.0.0.1")
      |> mist.port(port)
      |> mist.start
    }),
  )
  Ok(port)
}

/// The daemon's own top-level routes; a service never shadows them.
/// Shutdown can close a handle after the registry admitted its request.
/// Keep this transport failure at the HTTP boundary; other panics still fail.
fn route(
  config: Config,
  registry: Subject(Message),
  boundary: HttpBoundary,
  req: request.Request(mist.Connection),
) -> response.Response(mist.ResponseData) {
  case http_request(fn() { handle_request(config, registry, boundary, req) }) {
    Ok(response) -> http_coding.encode(req, response)
    Error(_) ->
      http_api.fail(http_api.Failure(
        503,
        "daemon_unavailable",
        "daemon request process is unavailable",
      ))
      |> response.set_header("connection", "close")
  }
}

@external(erlang, "albedo_daemon", "http_request")
fn http_request(
  handle: fn() -> response.Response(mist.ResponseData),
) -> Result(response.Response(mist.ResponseData), Nil)

fn handle_request(
  config: Config,
  registry: Subject(Message),
  boundary: HttpBoundary,
  req: request.Request(mist.Connection),
) -> response.Response(mist.ResponseData) {
  let hosts = [
    "127.0.0.1:" <> int.to_string(boundary.port),
    "localhost:" <> int.to_string(boundary.port),
    ..list.map(boundary.hosts, string.lowercase)
  ]
  let host_headers =
    list.filter(req.headers, fn(header) { string.lowercase(header.0) == "host" })
  let origin_headers =
    list.filter(req.headers, fn(header) {
      string.lowercase(header.0) == "origin"
    })
  case host_headers, origin_headers {
    [#(_, host)], [] ->
      case list.contains(hosts, string.lowercase(host)) {
        True -> route_trusted(config, registry, boundary.instance_id, req)
        False -> ingress_error(403, "host_forbidden", "host is not allowed")
      }
    [#(_, host)], [#(_, origin)] ->
      case
        list.contains(hosts, string.lowercase(host)),
        list.contains(boundary.origins, origin)
      {
        True, True -> {
          let reply = case req.method {
            Options -> preflight(req)
            _ -> route_trusted(config, registry, boundary.instance_id, req)
          }
          reply
          |> response.set_header("access-control-allow-origin", origin)
          |> response.set_header(
            "access-control-expose-headers",
            "ETag, Location, Retry-After",
          )
          |> response.set_header("vary", "Origin, Accept")
        }
        False, _ -> ingress_error(403, "host_forbidden", "host is not allowed")
        _, False ->
          ingress_error(403, "origin_forbidden", "origin is not allowed")
      }
    _, _ ->
      ingress_error(
        403,
        "request_authority_invalid",
        "host and origin headers must be unambiguous",
      )
  }
}

fn route_trusted(
  config: Config,
  registry: Subject(Message),
  instance_id: String,
  req: request.Request(mist.Connection),
) -> response.Response(mist.ResponseData) {
  case request.path_segments(req) {
    ["extensions", name, ..rest] ->
      case registry.host(registry) {
        Error(_) ->
          ingress_error(503, "daemon_unavailable", "daemon is unavailable")
        Ok(host) ->
          case
            runtime.global(host)
            |> result.replace_error(Nil)
            |> result.try(extension.service(_, name))
          {
            Ok(service) -> {
              let admission = service.admission(rest, req.method)
              admitted(config, admission, req, fn(read) {
                service.handle(daemon(config, registry, host), rest, read, req)
              })
            }
            Error(_) -> routed(config, registry, instance_id, req)
          }
      }
    _ -> routed(config, registry, instance_id, req)
  }
}

fn configured_list(name: String) -> List(String) {
  env(name)
  |> string.split(",")
  |> list.map(string.trim)
  |> list.filter(fn(value) {
    value != ""
    && !string.contains(value, "\r")
    && !string.contains(value, "\n")
    && value != "*"
    && value != "null"
  })
}

fn preflight(
  req: request.Request(mist.Connection),
) -> response.Response(mist.ResponseData) {
  let headers =
    request.get_header(req, "access-control-request-headers")
    |> result.unwrap("")
    |> string.lowercase
    |> string.split(",")
    |> list.map(string.trim)
    |> list.filter(fn(header) { header != "" })
  let allowed_headers = [
    "authorization",
    "content-type",
    "if-match",
    "if-none-match",
    "accept",
  ]
  let method =
    request.get_header(req, "access-control-request-method")
    |> result.unwrap("")
  let allowed =
    list.contains(["GET", "PUT", "PATCH", "POST", "DELETE"], method)
    && list.all(headers, list.contains(allowed_headers, _))
  case allowed {
    False ->
      ingress_error(
        403,
        "preflight_forbidden",
        "preflight requests an unsupported method or header",
      )
    True ->
      response.new(204)
      |> response.set_header(
        "access-control-allow-methods",
        "GET, PUT, PATCH, POST, DELETE",
      )
      |> response.set_header(
        "access-control-allow-headers",
        "Authorization, Content-Type, If-Match, If-None-Match, Accept",
      )
      |> response.set_header("access-control-max-age", "600")
      |> response.set_header("connection", "close")
      |> response.set_body(mist.Bytes(bytes_tree.from_string("")))
  }
}

fn routed(
  config: Config,
  registry: Subject(Message),
  instance_id: String,
  req: request.Request(mist.Connection),
) -> response.Response(mist.ResponseData) {
  let limit = case req.method, request.path_segments(req) {
    Put, ["sessions", _, "inputs", _] -> http_api.input_body_limit
    _, _ -> http_api.ordinary_body_limit
  }
  admitted(
    config,
    extension.Admission(extension.DaemonToken, limit),
    req,
    fn(read) { daemon_route(config, registry, instance_id, read, req) },
  )
}

/// Authenticate before touching body bytes. Every accepted route, including
/// GET and unknown routes, consumes its known-length body at this boundary.
fn admitted(
  config: Config,
  admission: extension.Admission,
  req: request.Request(mist.Connection),
  next: fn(request.Request(BitArray)) -> response.Response(mist.ResponseData),
) -> response.Response(mist.ResponseData) {
  let failure = case admission {
    extension.Admission(..) -> ingress_error
    extension.RelayAdmission(..) -> relay_error
  }
  case
    admission.authorization == extension.DaemonToken
    && request.get_header(req, "authorization") != Ok("Bearer " <> config.token)
  {
    True ->
      failure(
        401,
        "authentication_required",
        "bearer authentication is required",
      )
      |> response.set_header("www-authenticate", "Bearer")
    False -> {
      let encodings =
        list.filter(req.headers, fn(header) {
          string.lowercase(header.0) == "content-encoding"
        })
      // Ok(True) when the body arrives zstd-compressed.
      let compressed = case admission, encodings {
        extension.RelayAdmission(..), _ | _, [] -> Ok(False)
        _, [#(_, encoding)] ->
          case string.lowercase(string.trim(encoding)) {
            "identity" -> Ok(False)
            "zstd" -> Ok(True)
            _ -> Error(Nil)
          }
        _, _ -> Error(Nil)
      }
      case compressed {
        Error(_) ->
          failure(
            415,
            "unsupported_encoding",
            "content encoding is unsupported",
          )
        Ok(compressed) ->
          case body_length(req, admission.body_limit, failure) {
            Error(refusal) -> refusal
            Ok(length) -> {
              let read = case length {
                Some(_) ->
                  mist.read_body(req, admission.body_limit)
                  |> result.map(fn(read) { read.body })
                None -> {
                  use _ <- result.try(mist.stream(req))
                  http_api.read_chunked(req.body, admission.body_limit)
                }
              }
              case read {
                Ok(body) -> {
                  let size = bit_array.byte_size(body)
                  case length, compressed {
                    Some(length), _ if size != length ->
                      failure(400, "invalid_request", "invalid request body")
                    _, False -> next(request.set_body(req, body))
                    _, True ->
                      case http_coding.decompress(body, admission.body_limit) {
                        Ok(body) -> next(request.set_body(req, body))
                        Error(_) ->
                          failure(
                            400,
                            "invalid_request",
                            "request body does not decode within its limit",
                          )
                      }
                  }
                }
                Error(mist.MalformedBody) ->
                  failure(400, "invalid_request", "invalid request body")
                Error(mist.ExcessBody) ->
                  failure(
                    413,
                    "request_body_too_large",
                    "request body exceeds its limit",
                  )
              }
            }
          }
      }
    }
  }
}

fn body_length(
  req: request.Request(mist.Connection),
  limit: Int,
  failure: fn(Int, String, String) -> response.Response(mist.ResponseData),
) -> Result(Option(Int), response.Response(mist.ResponseData)) {
  let lengths =
    list.filter(req.headers, fn(header) {
      string.lowercase(header.0) == "content-length"
    })
  let encodings =
    list.filter(req.headers, fn(header) {
      string.lowercase(header.0) == "transfer-encoding"
    })
  case
    list.length(lengths) > 1
    || list.length(encodings) > 1
    || { lengths != [] && encodings != [] }
  {
    True -> Error(failure(400, "invalid_request", "ambiguous request framing"))
    False ->
      case encodings, lengths {
        [#(_, "chunked")], [] -> Ok(None)
        [_, ..], _ ->
          Error(failure(
            400,
            "unsupported_transfer_encoding",
            "transfer encoding is unsupported",
          ))
        [], [] -> Ok(Some(0))
        [], [#(_, value)] -> {
          let valid =
            value != ""
            && list.all(string.to_graphemes(value), fn(digit) {
              list.contains(
                ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"],
                digit,
              )
            })
          case valid, int.parse(value) {
            True, Ok(length) if length <= limit -> Ok(Some(length))
            True, Ok(_) ->
              Error(failure(
                413,
                "request_body_too_large",
                "request body exceeds its limit",
              ))
            _, _ ->
              Error(failure(400, "invalid_request", "invalid content length"))
          }
        }
        _, _ ->
          Error(failure(400, "invalid_request", "invalid request framing"))
      }
  }
}

/// The body has not been consumed, so Mist must close after this response.
fn ingress_error(
  status: Int,
  code: String,
  message: String,
) -> response.Response(mist.ResponseData) {
  http_api.fail(http_api.Failure(status, code, message))
  |> response.set_header("connection", "close")
}

fn relay_error(
  status: Int,
  code: String,
  detail: String,
) -> response.Response(mist.ResponseData) {
  http_api.reply(
    status,
    json.object([
      #(
        "error",
        json.object([
          #("message", json.string(detail)),
          #(
            "type",
            json.string(case status >= 500 {
              True -> "server_error"
              False -> "invalid_request_error"
            }),
          ),
          #("code", json.string(code)),
          #("param", json.null()),
        ]),
      ),
    ]),
  )
  |> response.set_header("connection", "close")
}

/// Supply extension services with daemon facts and host-owned effects.
fn daemon(
  config: Config,
  registry: Subject(Message),
  host: runtime.Runtime,
) -> extension.Daemon {
  extension.Daemon(
    config.home,
    runtime.ledger(host),
    fn(profile, model, session) {
      use provider <- result.try(configuration.named(config.home, profile))
      runtime.upstream(
        host,
        session,
        config.home,
        profile,
        provider.extension,
        model,
        provider.protocol,
        None,
      )
    },
    fn(provider, endpoint) { runtime.model_names(host, provider, endpoint) },
    fn() { actor.call(registry, 5000, List) },
  )
}

fn daemon_route(
  config: Config,
  registry: Subject(Message),
  instance_id: String,
  req: request.Request(BitArray),
  live: request.Request(mist.Connection),
) -> response.Response(mist.ResponseData) {
  let path = request.path_segments(req)
  case req.method, path {
    Get, ["server"] -> protocol_server(config, registry, instance_id, req)
    Post, ["server", "shutdown"] ->
      protocol_shutdown(registry, instance_id, req)
    Get, ["settings"] -> http_auth.settings(config, registry, req)
    Patch, ["settings"] -> http_auth.settings(config, registry, req)
    Get, ["storage"] -> http_resources.storage(config, registry, req)
    Get, ["models"] -> http_resources.models(config, registry, req)
    Get, ["workspaces"] -> http_resources.workspaces(config, registry, req)
    Get, ["hosts"] -> http_resources.hosts(config, registry, req)
    Post, ["hosts", target, "probe"] -> http_resources.probe(target, req)
    Get, ["sessions"] ->
      http_session_collection.read(config, registry, req, live)
    Put, ["sessions", id] -> http_sessions.create(config, registry, id, req)
    Get, ["sessions", id] -> http_sessions.read(config, registry, id, req, live)
    Patch, ["sessions", id] -> http_sessions.patch(config, registry, id, req)
    Delete, ["sessions", id] -> http_sessions.delete(config, registry, id, req)
    Put, ["sessions", id, "inputs", input_id] ->
      http_sessions.input(config, registry, id, input_id, req)
    Get, ["sessions", id, "inputs", input_id] ->
      http_sessions.input_read(registry, id, input_id, req)
    Post, ["sessions", id, "inputs", input_id, "cancel"] ->
      http_sessions.cancel(registry, id, input_id, req)
    Post, ["sessions", id, "interrupt"] ->
      http_sessions.interrupt(registry, id, req)
    Put, ["sessions", id, "visits", visit_id] ->
      http_sessions.visit(config, registry, id, visit_id, req)
    Get, ["sessions", id, "history"] ->
      http_transcript.history(
        config.token,
        registry.host(registry) |> result.map(runtime.ledger),
        id,
        req,
      )
    Get, ["sessions", id, "history", entry_id, field] ->
      http_transcript.image(
        registry.host(registry) |> result.map(runtime.ledger),
        id,
        entry_id,
        field,
        req,
      )
    Get, ["sessions", id, "history", entry_id] ->
      http_transcript.content(
        config.token,
        registry.host(registry) |> result.map(runtime.ledger),
        id,
        entry_id,
        req,
      )
    Get, ["sessions", id, "active-output", content_id] ->
      http_active_output.content(
        config,
        registry.host(registry) |> result.map(runtime.ledger),
        id,
        content_id,
        req,
      )
    Get, ["sessions", id, "context"] ->
      http_sessions.context(config, registry, id, req)
    Get, ["sessions", id, "catalog"] ->
      http_sessions.catalog(config, registry, id, req)
    Post, ["sessions", id, "reload"] -> http_sessions.reload(registry, id, req)
    Post, ["sessions", id, "kernel", "upgrade"] ->
      http_sessions.upgrade(registry, id, req)
    Post, ["sessions", id, "compaction"] ->
      http_sessions.compaction(registry, id, req)
    Get, ["auth"] -> http_auth.auth(config, registry, req)
    Put, ["auth", "logins", id] -> http_auth.login(config, registry, id, req)
    Get, ["auth", "logins", id] -> http_auth.login(config, registry, id, req)
    Patch, ["auth", "logins", id] -> http_auth.login(config, registry, id, req)
    Delete, ["auth", "logins", id] -> http_auth.login(config, registry, id, req)
    Delete, ["auth", "accounts", id] ->
      http_auth.account(config, registry, id, req)
    _, _ -> protocol_method(path)
  }
}

pub fn main() -> Nil {
  let assert Ok(#(home, token)) = defaults()
  let config =
    Config(
      home,
      token,
      setting("ALBEDO_IDLE_SECONDS", 10 * 60, 1, 604_800) * 1000,
      setting("ALBEDO_UNLOAD_SECONDS", 60 * 60, 1, 604_800) * 1000,
      setting("ALBEDO_KERNEL_BUDGET_MB", 2048, 64, 1_048_576) * 1024,
      setting("ALBEDO_STATE_EXPIRY_SECONDS", 1_209_600, 1, 31_536_000),
      setting("ALBEDO_SCHEDULE_TICK_MS", 15_000, 50, 60_000),
    )
  case claim_home(home) {
    Ok(_) -> Nil
    Error(sqlight.SqlightError(code: sqlight.Busy, ..))
    | Error(sqlight.SqlightError(code: sqlight.Locked, ..)) -> refuse_home(home)
    Error(error) -> panic as error.message
  }
  // A fixed port gives services such as the proxy a stable base url.
  let assert Ok(port) = start(config, setting("ALBEDO_PORT", 0, 0, 65_535))
  // Before readiness, so a client that sees the daemon can already inspect it.
  inspect(home)
  let assert Ok(_) = ready(home, port, token)
  watch_parent(env("ALBEDO_PARENT_PID"))
  process.sleep_forever()
}

/// An operator's limit, clamped to a range this daemon can honour.
fn setting(name: String, fallback: Int, low: Int, high: Int) -> Int {
  case int.parse(string.trim(env(name))) {
    Ok(value) -> int.clamp(value, low, high)
    Error(_) -> fallback
  }
}

@external(erlang, "albedo_daemon", "free_port")
fn free_port() -> Int

@external(erlang, "albedo_daemon", "env")
fn env(name: String) -> String

/// Takes an exclusive SQLite lock on `home` for the life of the calling
/// process. Startup resumes saved sessions, so a second daemon on the same home
/// would run every in-flight turn twice. Offline cleanup takes the same lock
/// before revalidation and holds it through deletion and vacuum. Neither owner
/// commits the transaction or replaces the lock file. The OS drops the lock
/// when its owner exits, so a crashed owner never leaves it stale.
pub fn claim_home(home: String) -> Result(Nil, sqlight.Error) {
  use connection <- result.try(sqlight.open(home <> "/daemon.lock"))
  case
    // The transaction is never committed: holding it open keeps the exclusive
    // lock, and a refused BEGIN leaves no lock behind on its connection.
    sqlight.exec("BEGIN EXCLUSIVE;", connection)
  {
    Ok(_) -> Ok(hold(connection))
    Error(error) -> {
      let _ = sqlight.close(connection)
      Error(error)
    }
  }
}

@external(erlang, "albedo_daemon", "hold")
fn hold(connection: sqlight.Connection) -> Nil

@external(erlang, "albedo_daemon", "build_digest")
fn build_digest() -> String

@external(erlang, "albedo_daemon", "ready")
fn ready(home: String, port: Int, token: String) -> Result(Nil, String)

@external(erlang, "albedo_inspect", "start")
fn inspect(home: String) -> Nil

@external(erlang, "albedo_daemon", "watch_parent")
fn watch_parent(pid: String) -> Nil

@external(erlang, "albedo_daemon", "defaults")
fn defaults() -> Result(#(String, String), String)

fn protocol_method(path: List(String)) -> response.Response(mist.ResponseData) {
  let methods = case path {
    ["server"]
    | ["storage"]
    | ["models"]
    | ["workspaces"]
    | ["hosts"]
    | ["auth"]
    | ["sessions"] -> Some("GET")
    ["settings"] -> Some("GET, PATCH")
    ["sessions", _] -> Some("GET, PUT, PATCH, DELETE")
    ["sessions", _, "inputs", _] -> Some("GET, PUT")
    ["sessions", _, "visits", _] -> Some("PUT")
    ["sessions", _, "history"]
    | ["sessions", _, "history", _]
    | ["sessions", _, "history", _, _]
    | ["sessions", _, "active-output", _]
    | ["sessions", _, "context"]
    | ["sessions", _, "catalog"] -> Some("GET")
    ["server", "shutdown"]
    | ["hosts", _, "probe"]
    | ["sessions", _, "interrupt"]
    | ["sessions", _, "inputs", _, "cancel"]
    | ["sessions", _, "reload"]
    | ["sessions", _, "kernel", "upgrade"]
    | ["sessions", _, "compaction"] -> Some("POST")
    ["auth", "logins", _] -> Some("GET, PUT, PATCH, DELETE")
    ["auth", "accounts", _] -> Some("DELETE")
    _ -> None
  }
  case methods {
    Some(methods) ->
      http_api.fail(http_api.Failure(
        405,
        "method_not_allowed",
        "method is not allowed for this resource",
      ))
      |> response.set_header("allow", methods)
    None ->
      http_api.fail(http_api.Failure(
        404,
        "resource_not_found",
        "resource was not found",
      ))
  }
}

fn protocol_server(
  config: Config,
  registry: Subject(Message),
  instance_id: String,
  req: request.Request(BitArray),
) -> response.Response(mist.ResponseData) {
  let outcome = {
    use parameters <- result.try(
      http_api.json_parameters(req, ["include", "limit", "next"]),
    )
    use _ <- result.try(case list.key_find(parameters, "include") {
      Error(_) if parameters == [] -> Ok(Nil)
      Ok("quota_history") -> Ok(Nil)
      _ -> Error(http_api.invalid("pagination requires include=quota_history"))
    })
    use host <- result.try(
      registry.host(registry)
      |> result.map_error(fn(_) {
        http_api.Failure(503, "daemon_unavailable", "daemon is unavailable")
      }),
    )
    use readings <- result.try(
      quota.latest(runtime.ledger(host)) |> result.map_error(http_api.failure),
    )
    use ui <- result.try(
      settings.observe_group(config.home, "ui")
      |> result.map_error(http_api.native_failure),
    )
    use dismissed <- result.try(
      json.parse(
        ui.value,
        decode.field(
          "dismissed_notices",
          decode.list(decode.string),
          decode.success,
        ),
      )
      |> result.replace_error(http_api.Failure(
        503,
        "settings_unavailable",
        "saved notice preferences are unavailable",
      )),
    )
    use enabled <- result.try(
      runtime.global(host) |> result.map_error(http_api.failure),
    )
    let service_names =
      list.filter_map(enabled, fn(item) {
        case extension.service(enabled, item.name) {
          Ok(_) -> Ok(item.name)
          Error(_) -> Error(Nil)
        }
      })
    let quota = json.array(list.take(readings, 200), http_wire.quota)
    let fields = [
      #("instance_id", json.string(instance_id)),
      #("protocol", json.int(3)),
      #("state", json.string("ready")),
      #(
        "capabilities",
        json.object(
          list.map(
            [
              "durable_inputs",
              "session_replay",
              "collection_invalidation",
              "tool_progress",
              "storage_report",
              "context",
              "catalog",
              "settings",
              "workspace_browsing",
              "host_probes",
              "provider_auth",
              "zstd_requests",
            ],
            fn(name) {
              #(
                name,
                json.int(case name {
                  "session_replay" -> 2
                  _ -> 1
                }),
              )
            },
          ),
        ),
      ),
      #("build", case env("ALBEDO_BUILD") {
        "" -> json.null()
        build -> json.string(build)
      }),
      #("digest", case build_digest() {
        "" -> json.null()
        digest -> json.string(digest)
      }),
      #(
        "extensions",
        json.array(service_names, fn(name) {
          json.object([
            #("name", json.string(name)),
            #("version", json.int(1)),
          ])
        }),
      ),
      #("quota", quota),
      #(
        "notices",
        json.array(
          credentials.migrated()
            |> list.take(100)
            |> list.filter(fn(file) {
              !list.contains(dismissed, "credentials-migrated-" <> file)
            }),
          fn(file) {
            json.object([
              #("id", json.string("credentials-migrated-" <> file)),
              #("kind", json.string("migration")),
              #(
                "message",
                json.string(
                  "Credentials from "
                  <> file
                  <> " were moved into creds.json; the original file is in backups.",
                ),
              ),
            ])
          },
        ),
      ),
    ]
    let fields = case list.key_find(parameters, "include") {
      Ok("quota_history") -> {
        use limit <- result.try(http_api.limit_parameter(parameters, 50))
        use before <- result.try(http_api.page_offset(
          config.token,
          req,
          parameters,
          "",
          0,
        ))
        use samples <- result.try(
          quota.history(runtime.ledger(host), before, limit + 1)
          |> result.map_error(http_api.failure),
        )
        let shown = list.take(samples, limit)
        let next = case list.length(samples) > limit, list.last(shown) {
          True, Ok(last) ->
            http_api.continuation(config.token, req, parameters, "", last.id)
          _, _ -> json.null()
        }
        let page =
          json.object([
            #("items", json.array(shown, http_wire.quota)),
            #("next", next),
          ])
        Ok([#("quota_history", page), ..fields])
      }
      _ -> Ok(fields)
    }
    use fields <- result.try(fields)
    Ok(http_api.reply(200, json.object(fields)))
  }
  http_api.answer(outcome)
}

fn protocol_shutdown(
  registry: Subject(Message),
  instance_id: String,
  req: request.Request(BitArray),
) -> response.Response(mist.ResponseData) {
  let outcome = {
    use _ <- result.try(http_api.json_parameters(req, []))
    use supplied <- result.try(
      http_api.body(req, ["instance_id", "timeout_ms"], {
        use instance <- decode.field("instance_id", decode.string)
        use timeout <- decode.optional_field("timeout_ms", 5000, decode.int)
        decode.success(#(instance, timeout))
      }),
    )
    use _ <- result.try(
      case supplied.0 == instance_id && supplied.1 > 0 && supplied.1 <= 30_000 {
        True -> Ok(Nil)
        False ->
          Error(http_api.Failure(
            409,
            "instance_changed",
            "daemon instance or shutdown timeout is invalid",
          ))
      },
    )
    let _ = process.send_after(registry, 100, Shutdown)
    Ok(http_api.reply(
      202,
      json.object([
        #("instance_id", json.string(instance_id)),
        #("state", json.string("draining")),
      ]),
    ))
  }
  http_api.answer(outcome)
}

@external(erlang, "albedo_daemon", "refuse_home")
fn refuse_home(home: String) -> Nil
