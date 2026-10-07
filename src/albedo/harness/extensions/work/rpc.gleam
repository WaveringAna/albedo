//// The same ledger operations used by the Python tool and other clients.

import albedo/daemon/store
import albedo/harness/extensions/work/ledger as work
import albedo/harness/rpc
import gleam/dynamic
import gleam/dynamic/decode
import gleam/json
import gleam/option.{None}
import gleam/result

pub fn handle(store: store.Store, cwd: String, request: String) -> String {
  rpc.serve(
    request,
    work.Invalid("invalid host request"),
    fn(method, args) { dispatch(store, cwd, method, args) },
    describe,
  )
}

fn describe(error: work.Error) -> #(String, String) {
  case error {
    work.Invalid(message) -> #("invalid", message)
    work.NotFound -> #("not_found", "work item not found")
    work.Conflict -> #(
      "conflict",
      "work item changed; read it again before editing",
    )
    work.Storage(message) -> #("storage", message)
  }
}

fn parse(
  args: dynamic.Dynamic,
  decoder: decode.Decoder(a),
) -> Result(a, work.Error) {
  rpc.args(args, decoder, work.Invalid("invalid work arguments"))
}

fn id_decoder() -> decode.Decoder(Int) {
  decode.field("id", decode.int, decode.success)
}

fn dispatch(
  store: store.Store,
  cwd: String,
  method: String,
  args: dynamic.Dynamic,
) -> Result(json.Json, work.Error) {
  case method {
    "work.list" -> {
      let decoder = {
        use after <- decode.optional_field("after", 0, decode.int)
        use limit <- decode.optional_field("limit", 50, decode.int)
        decode.success(#(after, limit))
      }
      use #(after, limit) <- result.try(parse(args, decoder))
      work.list(store, cwd, after, limit)
      |> result.map(json.array(_, work.to_json))
    }
    "work.get" -> {
      use id <- result.try(parse(args, id_decoder()))
      work.get(store, cwd, id) |> result.map(work.to_json)
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
      work.create(store, cwd, title, notes, parent) |> result.map(work.to_json)
    }
    "work.update" -> {
      use id <- result.try(parse(args, id_decoder()))
      use current <- result.try(work.get(store, cwd, id))
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
        cwd,
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
      use #(id, revision) <- result.try(
        parse(args, {
          use id <- decode.field("id", decode.int)
          use revision <- decode.field("revision", decode.int)
          decode.success(#(id, revision))
        }),
      )
      work.delete(store, cwd, id, revision) |> result.map(work.to_json)
    }
    _ -> Error(work.Invalid("unknown host operation"))
  }
}
