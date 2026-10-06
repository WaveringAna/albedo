//// Cursor-bound reads of unfinished model output. The session owns writes.

import albedo/daemon/active_output
import albedo/daemon/conversation
import albedo/daemon/http_api
import albedo/daemon/registry
import albedo/daemon/store
import gleam/dynamic/decode
import gleam/http/request
import gleam/http/response
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/uri
import mist

const content_page_bytes = 262_144

type Boundary {
  Boundary(generation: String, field: String, bytes: Int)
}

pub fn snapshot(
  secret: String,
  session_id: String,
  generation: String,
  output: active_output.Snapshot,
) -> json.Json {
  let reference = case output.content_id {
    None -> json.null()
    Some(content_id) -> {
      let path =
        "/sessions/"
        <> uri.percent_encode(session_id)
        <> "/active-output/"
        <> uri.percent_encode(content_id)
      let token =
        http_api.page_token(
          secret,
          path,
          boundary_json(Boundary(generation, output.kind, output.bytes))
            |> json.to_string,
        )
      json.object([
        #("url", json.string(path <> "?snapshot=" <> token)),
        #("field", json.string(output.kind)),
        #("bytes", json.int(output.bytes)),
      ])
    }
  }
  json.object([
    #("message_id", json.string(output.message_id)),
    #("run_id", json.string(output.run_id)),
    #("kind", json.string(output.kind)),
    #("bytes", json.int(output.bytes)),
    #("elapsed_ms", json.nullable(output.elapsed_ms, json.int)),
    #("text", json.nullable(output.text, json.string)),
    #("reference", reference),
  ])
}

fn boundary_json(boundary: Boundary) -> json.Json {
  json.object([
    #("generation", json.string(boundary.generation)),
    #("field", json.string(boundary.field)),
    #("bytes", json.int(boundary.bytes)),
  ])
}

fn captured_boundary(
  secret: String,
  path: String,
  token: String,
) -> Result(Boundary, http_api.Failure) {
  use state <- result.try(
    http_api.page_state(secret, path, token)
    |> result.map_error(fn(error) {
      case error {
        "continuation_expired" ->
          http_api.Failure(
            410,
            "active_output_expired",
            "refresh the session snapshot",
          )
        _ ->
          http_api.invalid(
            "active output snapshot does not belong to this resource",
          )
      }
    }),
  )
  use boundary <- result.try(
    json.parse(state, {
      use generation <- decode.field("generation", decode.string)
      use field <- decode.field("field", decode.string)
      use bytes <- decode.field("bytes", decode.int)
      decode.success(Boundary(generation, field, bytes))
    })
    |> result.replace_error(http_api.invalid("invalid active output snapshot")),
  )
  case
    boundary.generation != ""
    && boundary.bytes >= 0
    && { boundary.field == "text" || boundary.field == "thinking" }
  {
    True -> Ok(boundary)
    False -> Error(http_api.invalid("invalid active output snapshot"))
  }
}

pub fn content(
  config: registry.Config,
  storage: Result(store.Store, String),
  session_id: String,
  content_id: String,
  req: request.Request(BitArray),
) -> response.Response(mist.ResponseData) {
  let outcome = {
    use parameters <- result.try(
      http_api.json_parameters(req, ["snapshot", "next"]),
    )
    use token <- result.try(
      list.key_find(parameters, "snapshot")
      |> result.replace_error(http_api.invalid(
        "active output snapshot is required",
      )),
    )
    use boundary <- result.try(captured_boundary(config.token, req.path, token))
    use ledger <- result.try(storage |> result.map_error(http_api.failure))
    use _ <- result.try(
      conversation.get(ledger, session_id)
      |> result.map_error(fn(error) {
        case error {
          "session not found" ->
            http_api.Failure(
              410,
              "active_output_expired",
              "refresh the session snapshot",
            )
          _ -> http_api.failure(error)
        }
      }),
    )
    let binding = req.path <> "?snapshot=" <> token
    use offset <- result.try(case list.key_find(parameters, "next") {
      Error(_) -> Ok(0)
      Ok(next) -> {
        use state <- result.try(
          http_api.page_state(config.token, binding, next)
          |> result.replace_error(http_api.invalid(
            "invalid active output continuation",
          )),
        )
        json.parse(state, decode.int)
        |> result.replace_error(http_api.invalid("invalid active output offset"))
      }
    })
    use _ <- result.try(case offset >= 0 && offset <= boundary.bytes {
      True -> Ok(Nil)
      False ->
        Error(http_api.invalid("active output offset is outside the snapshot"))
    })
    use read <- result.try(
      active_output.read(
        config.home,
        session_id,
        content_id,
        offset,
        content_page_bytes,
        boundary.bytes,
      )
      |> result.map_error(fn(error) {
        case error {
          "active_output_expired" ->
            http_api.Failure(
              410,
              "active_output_expired",
              "refresh the session snapshot",
            )
          _ ->
            http_api.Failure(
              503,
              "active_output_unavailable",
              "unfinished output is unavailable",
            )
        }
      }),
    )
    use page <- result.try(encoded_page(read, offset))
    let next = case page.2 {
      True -> json.null()
      False ->
        json.string(http_api.page_token(
          config.token,
          binding,
          json.to_string(json.int(page.1)),
        ))
    }
    Ok(http_api.reply(
      200,
      json.object([
        #("entry_id", json.string(content_id)),
        #(
          "parts",
          json.array(
            [
              json.object([
                #("field", json.string(boundary.field)),
                #("offset_bytes", json.int(offset)),
                #("encoding", json.string("utf8")),
                #("text", page.0),
                #("complete", json.bool(page.2)),
              ]),
            ],
            fn(value) { value },
          ),
        ),
        #("next", next),
      ]),
    ))
  }
  http_api.answer(outcome)
}

fn encoded_page(
  read: #(String, Int, Bool),
  offset: Int,
) -> Result(#(json.Json, Int, Bool), http_api.Failure) {
  use _ <- result.try(case read.1 > offset || read.2 {
    True -> Ok(Nil)
    False ->
      Error(http_api.Failure(
        503,
        "active_output_unavailable",
        "unfinished output read made no progress",
      ))
  })
  let value = json.string(read.0)
  case http_api.encoded_size(value) <= content_page_bytes {
    True -> Ok(#(value, read.1, read.2))
    False -> {
      // One scalar escapes to at most six ASCII bytes. This fallback bounds
      // escape-heavy pages without shrinking ordinary UTF-8 reads.
      use slice <- result.try(
        http_api.content_slice(read.0, 0, 43_000)
        |> result.replace_error(http_api.Failure(
          503,
          "active_output_unavailable",
          "unfinished output is unavailable",
        )),
      )
      Ok(#(json.string(slice.0), offset + slice.1, read.2 && slice.2))
    }
  }
}
