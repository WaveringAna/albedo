//// The artifacts HTTP service: the gallery for clients, and the frame routes
//// `albedo web` forwards pages through (robot-docs/artifacts.md).

import albedo/clock
import albedo/daemon/http_api as api
import albedo/harness/extension
import albedo/harness/extensions/artifacts/frame
import albedo/harness/extensions/artifacts/ledger
import albedo/text_scalars
import gleam/bit_array
import gleam/bytes_tree
import gleam/dict
import gleam/dynamic/decode
import gleam/http.{Delete, Get, Post}
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

@external(erlang, "albedo_artifacts", "bridge")
fn bridge() -> Result(String, String)

/// What each operation may send: a page's whole storage, one failure, or
/// nothing much.
pub fn admission(
  path: List(String),
  method: http.Method,
) -> extension.Admission {
  let limit = case method, path {
    Post, ["frame", _, _, ".albedo", "state"] -> ledger.state_limit + 4096
    Post, ["frame", _, _, ".albedo", "errors"] -> 16_384
    _, _ -> 65_536
  }
  extension.Admission(extension.DaemonToken, limit)
}

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
    ledger.NotFound -> not_found()
    ledger.Storage(detail) -> api.Failure(503, "storage_failed", detail)
  }
}

fn not_found() -> api.Failure {
  api.Failure(404, "not_found", "no such artifact")
}

fn dispatch(
  daemon: extension.Daemon,
  path: List(String),
  req: request.Request(BitArray),
) -> Result(response.Response(mist.ResponseData), api.Failure) {
  case req.method, path {
    Get, ["items"] -> gallery(daemon, req)
    Get, ["items", id] -> {
      use _ <- result.try(json_only(req))
      use id <- result.try(identifier(id))
      use artifact <- result.try(
        ledger.get(daemon.ledger, id) |> result.map_error(failure),
      )
      use history <- result.try(
        ledger.history(daemon.ledger, id) |> result.map_error(failure),
      )
      use labels <- result.try(
        ledger.sessions(daemon.ledger, [artifact.session])
        |> result.map_error(failure),
      )
      Ok(api.reply(
        200,
        json.object(
          list.append(fields(artifact, labels), [
            #("history", json.array(history, version_json)),
          ]),
        ),
      ))
    }
    Delete, ["items", id] -> {
      use id <- result.try(identifier(id))
      use _ <- result.try(
        ledger.delete(daemon.ledger, id) |> result.map_error(failure),
      )
      Ok(no_content())
    }
    Post, ["frame", capability, version, ".albedo", "state"] -> {
      use #(artifact, _) <- result.try(framed(daemon, capability, version))
      use state <- result.try(
        text(req)
        |> result.try(fn(body) {
          json.parse(body, decode.dict(decode.string, decode.string))
          |> result.replace_error(api.invalid(
            "state is a JSON object of strings",
          ))
        }),
      )
      use _ <- result.try(
        ledger.set_state(daemon.ledger, artifact.id, state)
        |> result.map_error(failure),
      )
      Ok(no_content())
    }
    Post, ["frame", capability, version, ".albedo", "errors"] -> {
      use #(artifact, found) <- result.try(framed(daemon, capability, version))
      use reported <- result.try(
        text(req)
        |> result.try(fn(body) {
          json.parse(body, reported_decoder(found.version))
          |> result.replace_error(api.invalid("an error needs a message"))
        }),
      )
      use _ <- result.try(
        ledger.record_failure(
          daemon.ledger,
          artifact.id,
          ledger.Failure(..reported, at: clock.system_ms()),
        )
        |> result.map_error(failure),
      )
      Ok(no_content())
    }
    Get, ["frame", capability, version, ..rest] -> {
      use #(artifact, found) <- result.try(framed(daemon, capability, version))
      // A page asks for `my%20photo.png`; the manifest names `my photo.png`.
      let path =
        rest
        |> list.map(fn(segment) {
          uri.percent_decode(segment) |> result.unwrap(segment)
        })
        |> string.join("/")
      use file <- result.try(
        frame.resolve(found.files, path)
        |> result.replace_error(api.Failure(
          404,
          "not_found",
          "this artifact has no " <> text_scalars.take(path, 200),
        )),
      )
      use data <- result.try(
        ledger.data(daemon.ledger, file.hash) |> result.map_error(failure),
      )
      case frame.is_html(file.path) {
        False ->
          Ok(
            response.new(200)
            |> response.set_header(
              "content-type",
              frame.content_type(file.path),
            )
            // A version's files never change, so they keep for good.
            |> response.set_header(
              "cache-control",
              "private, max-age=31536000, immutable",
            )
            |> response.set_header("etag", "\"" <> file.hash <> "\"")
            |> response.set_body(mist.Bytes(bytes_tree.from_bit_array(data))),
          )
        True -> {
          use source <- result.try(
            bridge() |> result.map_error(api.Failure(503, "bridge_missing", _)),
          )
          use state <- result.try(
            ledger.state(daemon.ledger, artifact.id)
            |> result.map_error(failure),
          )
          let page = frame.inject(data, source, artifact, found.version, state)
          Ok(
            response.new(200)
            |> response.set_header(
              "content-type",
              frame.content_type(file.path),
            )
            // The page carries its saved storage, which changes.
            |> response.set_header("cache-control", "no-store")
            |> response.set_body(mist.Bytes(bytes_tree.from_bit_array(page))),
          )
        }
      }
    }
    _, ["items"] | _, ["items", _] -> Error(method_not_allowed())
    _, _ -> Error(not_found())
  }
}

fn method_not_allowed() -> api.Failure {
  api.Failure(405, "method_not_allowed", "method not allowed")
}

fn no_content() -> response.Response(mist.ResponseData) {
  response.new(204)
  |> response.set_header("cache-control", "no-store")
  |> response.set_body(mist.Bytes(bytes_tree.new()))
}

fn json_only(req: request.Request(BitArray)) -> Result(Nil, api.Failure) {
  use events <- result.try(api.wants_events(req))
  case events {
    True -> Error(api.Failure(406, "not_acceptable", "artifacts use JSON"))
    False -> Ok(Nil)
  }
}

fn identifier(id: String) -> Result(String, api.Failure) {
  case ledger.valid_id(id) {
    True -> Ok(id)
    False -> Error(not_found())
  }
}

fn text(req: request.Request(BitArray)) -> Result(String, api.Failure) {
  bit_array.to_string(req.body)
  |> result.replace_error(api.invalid("the body is not UTF-8"))
}

// `{id}.{key}` and a version number; anything wrong is the same 404, so a
// frame path says nothing about artifacts it cannot open.
fn framed(
  daemon: extension.Daemon,
  capability: String,
  version: String,
) -> Result(#(ledger.Artifact, ledger.Version), api.Failure) {
  case string.split_once(capability, "."), int.parse(version) {
    Ok(#(id, key)), Ok(version) ->
      case ledger.valid_id(id) {
        True ->
          ledger.framed(daemon.ledger, id, key, version)
          |> result.replace_error(not_found())
        False -> Error(not_found())
      }
    _, _ -> Error(not_found())
  }
}

fn reported_decoder(version: Int) -> decode.Decoder(ledger.Failure) {
  use message <- decode.field("message", decode.string)
  use source <- decode.optional_field("source", "", decode.string)
  use line <- decode.optional_field("line", 0, decode.int)
  use column <- decode.optional_field("column", 0, decode.int)
  use stack <- decode.optional_field("stack", "", decode.string)
  case string.trim(message) {
    "" ->
      decode.failure(ledger.Failure(version, 0, "", "", 0, 0, ""), "message")
    _ ->
      decode.success(ledger.Failure(
        version:,
        at: 0,
        message: text_scalars.take(message, 4000),
        source: text_scalars.take(source, 2000),
        line: int.max(line, 0),
        column: int.max(column, 0),
        stack: text_scalars.take(stack, 8000),
      ))
  }
}

fn gallery(
  daemon: extension.Daemon,
  req: request.Request(BitArray),
) -> Result(response.Response(mist.ResponseData), api.Failure) {
  use _ <- result.try(json_only(req))
  use query <- result.try(api.parameters(req, ["limit", "next", "session"]))
  use limit <- result.try(api.integer_parameter(query, "limit", 50, 200))
  use after <- result.try(case list.key_find(query, "next") {
    Error(_) -> Ok(None)
    Ok(token) ->
      api.page_state(daemon.home, "artifacts", token)
      |> result.replace_error(api.invalid("invalid page token"))
      |> result.try(cursor)
      |> result.map(Some)
  })
  let session = list.key_find(query, "session") |> option.from_result
  use items <- result.try(
    ledger.page(daemon.ledger, after, limit, session)
    |> result.map_error(failure),
  )
  use labels <- result.try(
    ledger.sessions(
      daemon.ledger,
      items |> list.map(fn(item) { item.session }) |> list.unique,
    )
    |> result.map_error(failure),
  )
  let next =
    api.next_page(
      daemon.home,
      "artifacts",
      list.length(items) == limit,
      list.last(items)
        |> result.map(fn(item) {
          int.to_string(item.updated_at) <> ":" <> item.id
        }),
    )
  Ok(api.reply(
    200,
    json.object([
      #(
        "items",
        json.array(items, fn(item) { json.object(fields(item, labels)) }),
      ),
      #("next", next),
    ]),
  ))
}

fn cursor(state: String) -> Result(#(Int, String), api.Failure) {
  case string.split_once(state, ":") {
    Ok(#(at, id)) ->
      int.parse(at)
      |> result.map(fn(at) { #(at, id) })
      |> result.replace_error(api.invalid("invalid page token"))
    Error(_) -> Error(api.invalid("invalid page token"))
  }
}

fn fields(
  artifact: ledger.Artifact,
  labels: dict.Dict(String, Option(String)),
) -> List(#(String, json.Json)) {
  let #(name, deleted) = case dict.get(labels, artifact.session) {
    Ok(label) -> #(label, False)
    Error(_) -> #(None, True)
  }
  [
    #("id", json.string(artifact.id)),
    #("key", json.string(artifact.key)),
    #("title", json.string(artifact.title)),
    #("version", json.int(artifact.version)),
    #("versions", json.int(artifact.versions)),
    #("entry", json.string(artifact.entry)),
    #("session_id", json.string(artifact.session)),
    #("session_name", json.nullable(name, json.string)),
    #("session_deleted", json.bool(deleted)),
    #("workspace", json.string(artifact.workspace)),
    #("created_at", json.int(artifact.created_at)),
    #("updated_at", json.int(artifact.updated_at)),
    #("bytes", json.int(artifact.bytes)),
  ]
}

fn version_json(version: ledger.Version) -> json.Json {
  json.object([
    #("version", json.int(version.version)),
    #("entry", json.string(version.entry)),
    #("created_at", json.int(version.created_at)),
    #("cell_id", json.nullable(version.cell, json.string)),
    #(
      "files",
      json.array(version.files, fn(file) {
        json.object([
          #("path", json.string(file.path)),
          #("size", json.int(file.size)),
        ])
      }),
    ),
    #("bytes", json.int(version.bytes)),
  ])
}
