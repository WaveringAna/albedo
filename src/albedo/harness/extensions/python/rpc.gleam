import albedo/harness/extensions/python/cells as journal
import albedo/harness/extensions/python/kernel as python
import albedo/harness/extensions/work/ledger as work
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string

pub fn handle(store: work.Store, session: String, request: String) -> String {
  let decoder = {
    use method <- decode.field("method", decode.string)
    use args <- decode.field("args", decode.dynamic)
    decode.success(#(method, args))
  }
  case json.parse(request, decoder) {
    Ok(#("cells.list", args)) -> {
      let limit =
        decode.run(
          args,
          decode.optional_field("limit", 20, decode.int, decode.success),
        )
        |> result.unwrap(20)
      case limit < 1 || limit > 200 {
        True -> Error("1 <= limit <= 200 required")
        False ->
          journal.recent(store, session, limit)
          |> result.map(json.array(_, summary_json))
      }
      |> answer
    }
    Ok(#(method, args))
      if method == "cells.read"
      || method == "cells.trace"
      || method == "cells.draft"
      || method == "cells.prepare"
      || method == "cells.started"
      || method == "cells.finish"
    -> {
      cells(store, session, method, args) |> answer
    }
    _ ->
      "{\"ok\":false,\"code\":\"cell\",\"message\":\"unknown cells operation\"}"
  }
}

fn answer(result: Result(json.Json, String)) -> String {
  case result {
    Ok(value) -> json.object([#("ok", json.bool(True)), #("value", value)])
    Error(message) ->
      json.object([
        #("ok", json.bool(False)),
        #("code", json.string("cell")),
        #("message", json.string(message)),
      ])
  }
  |> json.to_string
}

/// A cell without its source: what `cells.info` and `cells.list` show.
fn summary_json(cell: journal.Cell) -> json.Json {
  json.object([
    #("id", json.string(cell.id)),
    #("status", json.string(status(cell))),
    #("started", json.bool(cell.started)),
    #("parent", json.nullable(cell.parent, json.string)),
    #("finished", json.bool(cell.outcome != None)),
    #(
      "first_line",
      json.string(
        cell.source
        |> string.split("\n")
        |> list.find(fn(line) { string.trim(line) != "" })
        |> result.unwrap("")
        |> string.slice(0, 120),
      ),
    ),
  ])
}

/// ok, error, or interrupted once finished; lost or unavailable when the
/// kernel could not run it; started when it began without a recorded end
/// (effects unknown); saved when it never started.
fn status(cell: journal.Cell) -> String {
  case cell.outcome, cell.started {
    Some(Ok(outcome)), _ ->
      case outcome.status {
        python.Succeeded -> "ok"
        python.Failed -> "error"
        python.Interrupted -> "interrupted"
      }
    Some(Error(python.Lost)), _ -> "lost"
    Some(Error(_)), _ -> "unavailable"
    None, True -> "started"
    None, False -> "saved"
  }
}

fn parse(args, decoder) {
  decode.run(args, decoder) |> result.replace_error("invalid cell arguments")
}

fn replacements_decoder() -> decode.Decoder(List(#(String, String))) {
  let pair = {
    use old <- decode.field(0, decode.string)
    use new <- decode.field(1, decode.string)
    decode.success(#(old, new))
  }
  decode.field("replacements", decode.list(pair), decode.success)
}

fn cells(store, session, method, args) {
  use id <- result.try(parse(
    args,
    decode.field("id", decode.string, decode.success),
  ))
  use cell <- result.try(journal.get(store, id))
  use _ <- result.try(case cell.session == session {
    True -> Ok(Nil)
    False -> Error("cell belongs to another session")
  })
  case method {
    "cells.read" -> Ok(to_json(cell))
    "cells.trace" ->
      journal.trace(store, id)
      |> option.to_result(
        "no trace for that cell; a trace is recorded when the cell finishes",
      )
    "cells.started" ->
      journal.mark_started(store, id) |> result.map(fn(_) { json.null() })
    "cells.finish" -> {
      use outcome <- result.try(parse(
        args,
        decode.field("outcome", python.outcome_decoder(), decode.success),
      ))
      case outcome.id == id {
        True ->
          journal.finish(store, id, Ok(outcome))
          |> result.map(fn(_) { json.null() })
        False -> Error("cell result id differs")
      }
    }
    "cells.draft" -> {
      use replacements <- result.try(parse(args, replacements_decoder()))
      journal.draft(store, id, replacements) |> result.map(json.string)
    }
    "cells.prepare" -> {
      let decoder = {
        use replacements <- decode.then(replacements_decoder())
        use allow <- decode.field("allow_partial", decode.bool)
        decode.success(#(replacements, allow))
      }
      use #(replacements, allow) <- result.try(parse(args, decoder))
      journal.prepare(store, id, replacements, allow) |> result.map(to_json)
    }
    _ -> Error("unknown cell operation")
  }
}

fn to_json(cell: journal.Cell) -> json.Json {
  json.object([
    #("id", json.string(cell.id)),
    #("source", json.string(cell.source)),
    #("started", json.bool(cell.started)),
    #("parent", json.nullable(cell.parent, json.string)),
    #("finished", json.bool(cell.outcome != None)),
    #("status", json.string(status(cell))),
  ])
}
