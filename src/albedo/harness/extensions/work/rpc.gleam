//// The same ledger operations used by the Python tool and other clients.

import albedo/harness/extensions/work/ledger as work
import gleam/dynamic/decode
import gleam/json
import gleam/option.{None}
import gleam/result

pub fn handle(store: work.Store, request: String) -> String {
  let decoder = {
    use method <- decode.field("method", decode.string)
    use args <- decode.field("args", decode.dynamic)
    decode.success(#(method, args))
  }
  let answer = {
    use #(method, args) <- result.try(
      json.parse(request, decoder)
      |> result.replace_error(work.Invalid("invalid host request")),
    )
    dispatch(store, method, args)
  }
  case answer {
    Ok(value) -> json.object([#("ok", json.bool(True)), #("value", value)])
    Error(error) -> {
      let #(code, message) = case error {
        work.Invalid(message) -> #("invalid", message)
        work.NotFound -> #("not_found", "work item not found")
        work.Conflict -> #(
          "conflict",
          "work item changed; read it again before editing",
        )
        work.Storage(message) -> #("storage", message)
      }
      json.object([
        #("ok", json.bool(False)),
        #("code", json.string(code)),
        #("message", json.string(message)),
      ])
    }
  }
  |> json.to_string
}

fn parse(args, decoder) {
  decode.run(args, decoder)
  |> result.replace_error(work.Invalid("invalid work arguments"))
}

fn dispatch(store, method, args) {
  case method {
    "work.list" -> {
      let decoder = {
        use after <- decode.optional_field("after", 0, decode.int)
        use limit <- decode.optional_field("limit", 50, decode.int)
        decode.success(#(after, limit))
      }
      use #(after, limit) <- result.try(parse(args, decoder))
      work.list(store, after, limit) |> result.map(json.array(_, work.to_json))
    }
    "work.get" -> {
      use id <- result.try(parse(
        args,
        decode.field("id", decode.int, decode.success),
      ))
      work.get(store, id) |> result.map(work.to_json)
    }
    "work.create" -> {
      let decoder = {
        use title <- decode.field("title", decode.string)
        use notes <- decode.optional_field("notes", "", decode.string)
        use parent <- decode.optional_field(
          "parent",
          None,
          decode.optional(decode.int),
        )
        decode.success(#(title, notes, parent))
      }
      use #(title, notes, parent) <- result.try(parse(args, decoder))
      work.create(store, title, notes, parent) |> result.map(work.to_json)
    }
    "work.update" -> {
      use id <- result.try(parse(
        args,
        decode.field("id", decode.int, decode.success),
      ))
      use current <- result.try(work.get(store, id))
      let decoder = {
        use revision <- decode.field("revision", decode.int)
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
        use status <- decode.optional_field(
          "status",
          work.status_name(current.status),
          decode.string,
        )
        use session <- decode.optional_field(
          "session",
          current.session,
          decode.optional(decode.string),
        )
        use run <- decode.optional_field(
          "run",
          current.run,
          decode.optional(decode.string),
        )
        decode.success(#(revision, title, notes, status, session, run))
      }
      use #(revision, title, notes, status, session, run) <- result.try(parse(
        args,
        decoder,
      ))
      use status <- result.try(work.parse_status(status))
      work.update(
        store,
        work.Item(
          ..current,
          revision: revision,
          title: title,
          notes: notes,
          status: status,
          session: session,
          run: run,
        ),
      )
      |> result.map(work.to_json)
    }
    "work.delete" -> {
      let decoder = {
        use id <- decode.field("id", decode.int)
        use revision <- decode.field("revision", decode.int)
        decode.success(#(id, revision))
      }
      use #(id, revision) <- result.try(parse(args, decoder))
      work.delete(store, id, revision) |> result.map(work.to_json)
    }
    _ -> Error(work.Invalid("unknown host operation"))
  }
}
