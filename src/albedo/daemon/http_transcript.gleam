//// Bounded transcript pages and content reads over durable session history.

import albedo/daemon/conversation
import albedo/daemon/http_api
import albedo/daemon/http_history
import albedo/daemon/images
import albedo/daemon/store
import albedo/openai_api/types
import gleam/bytes_tree
import gleam/dynamic/decode
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import mist

pub type Cursor {
  Cursor(
    upper: Int,
    continuation_upper: Int,
    direction: String,
    position: Int,
    continuation_after: Int,
    entry_offset: Int,
    only_continuations: Bool,
    rows: Int,
  )
}

fn history_cursor_decoder() -> decode.Decoder(Cursor) {
  use upper <- decode.field("upper", decode.int)
  use continuation_upper <- decode.field("continuation_upper", decode.int)
  use direction <- decode.field("direction", decode.string)
  use position <- decode.field("position", decode.int)
  use continuation_after <- decode.field("continuation_after", decode.int)
  use entry_offset <- decode.field("entry_offset", decode.int)
  use only_continuations <- decode.field("only_continuations", decode.bool)
  use rows <- decode.field("rows", decode.int)
  decode.success(Cursor(
    upper,
    continuation_upper,
    direction,
    position,
    continuation_after,
    entry_offset,
    only_continuations,
    rows,
  ))
}

pub fn token(
  secret: String,
  id: String,
  view: String,
  limit: Int,
  cursor: Cursor,
) -> json.Json {
  let value =
    json.object([
      #("upper", json.int(cursor.upper)),
      #("continuation_upper", json.int(cursor.continuation_upper)),
      #("direction", json.string(cursor.direction)),
      #("position", json.int(cursor.position)),
      #("continuation_after", json.int(cursor.continuation_after)),
      #("entry_offset", json.int(cursor.entry_offset)),
      #("only_continuations", json.bool(cursor.only_continuations)),
      #("rows", json.int(cursor.rows)),
    ])
    |> json.to_string
  json.string(http_api.page_token(
    secret,
    "/sessions/" <> id <> "/history?" <> view <> ":" <> int.to_string(limit),
    value,
  ))
}

pub fn project(
  secret: String,
  ledger: store.Store,
  id: String,
  view: String,
  limit: Int,
  cursor: Cursor,
) -> Result(json.Json, http_api.Failure) {
  let direction = case cursor.direction {
    "before" -> conversation.Before(cursor.position)
    _ -> conversation.After(cursor.position)
  }
  use source <- result.try(
    conversation.read_range(
      ledger,
      conversation.Range(
        conversation.Snapshot(id, cursor.upper, cursor.continuation_upper),
        direction,
        cursor.rows,
        cursor.continuation_after,
      ),
    )
    |> result.map_error(http_api.failure),
  )
  let entries = http_history.project(source)
  let entries = case cursor.only_continuations {
    True -> list.filter(entries, fn(entry) { entry.kind == "continuation" })
    False -> entries
  }
  let projected = case view {
    "checkpoints" ->
      list.filter(entries, fn(entry) { entry.checkpoint != None })
    _ -> entries
  }
  let #(skipped, shown) = case cursor.direction, cursor.entry_offset {
    "before", 0 -> newest(projected, limit)
    _, offset -> #(offset, list.drop(projected, offset) |> list.take(limit))
  }
  let first_position = case cursor.direction, shown {
    "before", [first, ..] -> first.position
    _, _ ->
      list.first(source.entries)
      |> result.map(fn(entry) { entry.source.seq })
      |> result.unwrap(cursor.position)
  }
  let last_position =
    list.last(source.entries)
    |> result.map(fn(entry) { entry.source.seq })
    |> result.unwrap(cursor.position)
  let older = case
    source.has_older || skipped > 0 && cursor.direction == "before"
  {
    True ->
      token(
        secret,
        id,
        view,
        limit,
        Cursor(
          cursor.upper,
          cursor.continuation_upper,
          "before",
          first_position,
          0,
          0,
          False,
          limit,
        ),
      )
    False -> json.null()
  }
  let newer = case skipped + list.length(shown) < list.length(projected) {
    True ->
      token(
        secret,
        id,
        view,
        limit,
        Cursor(..cursor, entry_offset: skipped + list.length(shown)),
      )
    False ->
      case source.more_continuations {
        True -> {
          let after =
            list.last(source.continuations)
            |> result.map(fn(marker) { marker.order })
            |> result.unwrap(cursor.continuation_after)
          token(
            secret,
            id,
            view,
            limit,
            Cursor(
              ..cursor,
              continuation_after: after,
              entry_offset: 0,
              only_continuations: True,
            ),
          )
        }
        False ->
          case source.has_newer {
            True ->
              token(
                secret,
                id,
                view,
                limit,
                Cursor(
                  cursor.upper,
                  cursor.continuation_upper,
                  "after",
                  last_position,
                  list.last(source.continuations)
                    |> result.map(fn(marker) { marker.order })
                    |> result.unwrap(cursor.continuation_after),
                  0,
                  False,
                  limit,
                ),
              )
            False -> json.null()
          }
      }
  }
  let items = case view {
    "checkpoints" ->
      json.array(
        list.filter_map(shown, fn(entry) {
          http_history.checkpoint(entry) |> option.to_result(Nil)
        }),
        fn(item) { item },
      )
    _ ->
      json.array(shown, http_history.encode(
        id,
        _,
        262_144 / int.max(1, list.length(shown)),
      ))
  }
  Ok(
    json.object([
      #("items", items),
      #("older", older),
      #("newer", newer),
      #("high_water", json.int(cursor.upper)),
    ]),
  )
}

/// The newest `limit` entries of a backwards page and how many come before
/// them. A position cut in two is dropped whole, so the older page, which
/// starts before the first shown position, repeats nothing and skips nothing.
fn newest(
  projected: List(http_history.Entry),
  limit: Int,
) -> #(Int, List(http_history.Entry)) {
  let skipped = int.max(0, list.length(projected) - limit)
  let tail = list.drop(projected, skipped)
  case skipped, tail {
    0, _ | _, [] -> #(skipped, tail)
    _, [first, ..] -> {
      let cut =
        list.drop(projected, skipped - 1)
        |> list.first
        |> result.map(fn(before) { before.position == first.position })
        |> result.unwrap(False)
      let whole = case cut {
        True ->
          list.drop_while(tail, fn(entry) { entry.position == first.position })
        False -> tail
      }
      case whole {
        [] -> #(skipped, tail)
        _ -> #(list.length(projected) - list.length(whole), whole)
      }
    }
  }
}

pub fn history(
  secret: String,
  storage: Result(store.Store, String),
  id: String,
  req: request.Request(BitArray),
) -> response.Response(mist.ResponseData) {
  let outcome = {
    use parameters <- result.try(
      http_api.json_parameters(req, ["view", "before", "after", "limit", "next"]),
    )
    use limit <- result.try(http_api.limit_parameter(parameters, 100))
    let view = list.key_find(parameters, "view") |> result.unwrap("entries")
    use _ <- result.try(
      case
        list.contains(["entries", "checkpoints"], view)
        && list.length(
          list.filter(parameters, fn(pair) {
            list.contains(["before", "after", "next"], pair.0)
          }),
        )
        <= 1
      {
        True -> Ok(Nil)
        False ->
          Error(http_api.invalid(
            "choose a history view and only one of before, after or next",
          ))
      },
    )
    use ledger <- result.try(storage |> result.map_error(http_api.failure))
    use _ <- result.try(
      conversation.get(ledger, id) |> result.map_error(http_api.failure),
    )
    use cursor <- result.try(case list.key_find(parameters, "next") {
      Ok(token) -> {
        use state <- result.try(
          http_api.page_state(
            secret,
            "/sessions/"
              <> id
              <> "/history?"
              <> view
              <> ":"
              <> int.to_string(limit),
            token,
          )
          |> result.map_error(fn(_) {
            http_api.invalid(
              "history continuation does not belong to this view",
            )
          }),
        )
        json.parse(state, history_cursor_decoder())
        |> result.map_error(fn(_) {
          http_api.invalid("invalid history continuation")
        })
      }
      Error(_) -> {
        use snapshot <- result.try(
          conversation.snapshot(ledger, id)
          |> result.map_error(http_api.failure),
        )
        use position <- result.try(http_api.integer_parameter(
          parameters,
          case list.key_find(parameters, "after") {
            Ok(_) -> "after"
            _ -> "before"
          },
          snapshot.upper + 1,
          9_007_199_254_740_991,
        ))
        Ok(Cursor(
          snapshot.upper,
          snapshot.continuation_upper,
          case list.key_find(parameters, "after") {
            Ok(_) -> "after"
            _ -> "before"
          },
          position,
          0,
          0,
          False,
          limit,
        ))
      }
    })
    use page <- result.try(project(secret, ledger, id, view, limit, cursor))
    Ok(http_api.reply(200, page))
  }
  http_api.answer(outcome)
}

pub fn content(
  secret: String,
  storage: Result(store.Store, String),
  id: String,
  entry_id: String,
  req: request.Request(BitArray),
) -> response.Response(mist.ResponseData) {
  let outcome = {
    use parameters <- result.try(http_api.json_parameters(req, ["next"]))
    use ledger <- result.try(storage |> result.map_error(http_api.failure))
    use entry <- result.try(history_entry(ledger, id, entry_id))
    let revision = http_api.etag(string.inspect(entry_id))
    use cursor <- result.try(case list.key_find(parameters, "next") {
      Error(_) -> Ok(#(0, 0))
      Ok(token) -> {
        use state <- result.try(
          http_api.page_state(secret, req.path <> revision, token)
          |> result.map_error(fn(_) {
            http_api.invalid(
              "content continuation does not belong to this entry",
            )
          }),
        )
        json.parse(state, {
          use part <- decode.field("part", decode.int)
          use offset <- decode.field("offset", decode.int)
          decode.success(#(part, offset))
        })
        |> result.map_error(fn(_) {
          http_api.invalid("invalid content continuation")
        })
      }
    })
    // Image fields are served whole by `image`, never as pages here.
    let parts =
      list.filter(entry.parts, fn(part) {
        case part {
          http_history.Image(..) -> False
          _ -> True
        }
      })
    use page <- result.try(case list.drop(parts, cursor.0), cursor {
      [], #(0, 0) -> Ok(None)
      [], _ ->
        Error(http_api.Failure(
          404,
          "content_unknown",
          "entry content was not found",
        ))
      [part, ..], _ -> {
        use #(field, text) <- result.try(stored_text(ledger, id, part))
        use sliced <- result.try(
          text
          |> result.try(http_api.content_slice(_, cursor.1, 262_144))
          |> result.replace_error(http_api.Failure(
            503,
            "content_unavailable",
            "entry content is unavailable",
          )),
        )
        Ok(Some(#(field, sliced)))
      }
    })
    let parts_json = case page {
      None -> []
      Some(#(field, sliced)) -> [
        json.object([
          #("field", json.string(field)),
          #("offset_bytes", json.int(cursor.1)),
          #("encoding", json.string("utf8")),
          #("text", json.string(sliced.0)),
          #("complete", json.bool(sliced.2)),
        ]),
      ]
    }
    let next_state = case page {
      Some(#(_, #(_, offset, False))) -> #(cursor.0, offset)
      _ -> #(cursor.0 + 1, 0)
    }
    let next = case next_state.0 < list.length(parts) {
      False -> json.null()
      True ->
        json.string(http_api.page_token(
          secret,
          req.path <> revision,
          json.object([
            #("part", json.int(next_state.0)),
            #("offset", json.int(next_state.1)),
          ])
            |> json.to_string,
        ))
    }
    Ok(http_api.reply(
      200,
      json.object([
        #("entry_id", json.string(entry_id)),
        #("parts", json.array(parts_json, fn(value) { value })),
        #("next", next),
      ]),
    ))
  }
  http_api.answer(outcome)
}

/// A part's field name and stored UTF-8, read from the entry a reference
/// names. Images and unresolved references have no text.
fn stored_text(
  ledger: store.Store,
  id: String,
  part: http_history.Part,
) -> Result(#(String, Result(String, String)), http_api.Failure) {
  case part {
    http_history.Reference(field, source_id, _) -> {
      use source <- result.try(history_entry(ledger, id, source_id))
      list.find(source.parts, fn(part) { part.field == field })
      |> result.map(fn(part) { #(field, part_text(part)) })
      |> result.replace_error(http_api.Failure(
        503,
        "content_unavailable",
        "associated tool content is unavailable",
      ))
    }
    _ -> Ok(#(part.field, part_text(part)))
  }
}

fn part_text(part: http_history.Part) -> Result(String, String) {
  case part {
    http_history.Text(_, text) -> Ok(text)
    http_history.Value(_, value) | http_history.Trace(_, value) ->
      Ok(json.to_string(value))
    http_history.Image(..) | http_history.Reference(..) ->
      Error("part has no stored text")
  }
}

/// One image field's decoded bytes with its own MIME type.
pub fn image(
  storage: Result(store.Store, String),
  id: String,
  entry_id: String,
  field: String,
  req: request.Request(BitArray),
) -> response.Response(mist.ResponseData) {
  let outcome = {
    use _ <- result.try(http_api.parameters(req, []))
    use ledger <- result.try(storage |> result.map_error(http_api.failure))
    use entry <- result.try(history_entry(ledger, id, entry_id))
    use image <- result.try(
      list.find_map(entry.parts, fn(part) {
        case part {
          http_history.Image(key, image) if key == field -> Ok(image)
          _ -> Error(Nil)
        }
      })
      |> result.replace_error(http_api.Failure(
        404,
        "content_unknown",
        "entry image was not found",
      )),
    )
    use bytes <- result.try(
      images.bytes(ledger, image)
      |> result.replace_error(http_api.Failure(
        503,
        "content_unavailable",
        "entry image is unavailable",
      )),
    )
    Ok(
      response.new(200)
      |> response.set_header("content-type", types.image_meta(image).0)
      |> response.set_header("cache-control", "no-store")
      |> response.set_body(mist.Bytes(bytes_tree.from_bit_array(bytes))),
    )
  }
  http_api.answer(outcome)
}

fn history_entry(
  ledger: store.Store,
  id: String,
  entry_id: String,
) -> Result(http_history.Entry, http_api.Failure) {
  use snapshot <- result.try(
    conversation.snapshot(ledger, id) |> result.map_error(http_api.failure),
  )
  use _ <- result.try(
    conversation.get(ledger, id) |> result.map_error(http_api.failure),
  )
  case entry_id {
    "continue-" <> input_id -> {
      use marker <- result.try(
        conversation.continuation(ledger, id, input_id)
        |> result.map_error(http_api.failure),
      )
      use marker <- result.try(option.to_result(
        marker,
        http_api.Failure(404, "entry_unknown", "history entry was not found"),
      ))
      Ok(http_history.Entry(
        entry_id,
        marker.position,
        "continuation",
        marker.turn_id,
        Some(marker.input_id),
        marker.timestamp,
        [http_history.Text("text", marker.display.text)],
        None,
        None,
        None,
        "continue",
        None,
      ))
    }
    _ -> {
      use position <- result.try(
        string.split(entry_id, "-")
        |> list.first
        |> result.try(int.parse)
        |> result.map_error(fn(_) {
          http_api.Failure(404, "entry_unknown", "history entry was not found")
        }),
      )
      use source <- result.try(
        conversation.read_range(
          ledger,
          conversation.Range(snapshot, conversation.After(position - 1), 1, 0),
        )
        |> result.map_error(http_api.failure),
      )
      http_history.project(source)
      |> list.find(fn(entry) { entry.id == entry_id })
      |> result.map_error(fn(_) {
        http_api.Failure(404, "entry_unknown", "history entry was not found")
      })
    }
  }
}
