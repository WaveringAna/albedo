//// The vent operations the Python tool calls: filing, listing, and closing a
//// vent the model fixed. The user's triage runs through the /paperclips
//// command against the same global ledger.

import albedo/harness/extensions/paperclips/ledger as paperclips
import albedo/harness/rpc
import gleam/dynamic/decode
import gleam/json
import gleam/option.{Some}
import gleam/result

pub fn handle(
  store: paperclips.Store,
  cwd: String,
  session: String,
  request: String,
) -> String {
  rpc.serve(
    request,
    paperclips.Invalid("invalid host request"),
    fn(method, args) { dispatch(store, cwd, session, method, args) },
    describe,
  )
}

fn describe(error: paperclips.Error) -> #(String, String) {
  case error {
    paperclips.Invalid(message) -> #("invalid", message)
    paperclips.NotFound -> #("not_found", "vent not found")
    paperclips.Storage(message) -> #("storage", message)
  }
}

fn parse(args, decoder) {
  rpc.args(args, decoder, paperclips.Invalid("invalid vent arguments"))
}

fn dispatch(store, cwd, session, method, args) {
  case method {
    "paperclips.vent" -> {
      let decoder = {
        use topic <- decode.field("topic", decode.string)
        use message <- decode.field("message", decode.string)
        use title <- decode.optional_field("title", "", decode.string)
        use suggestion <- decode.optional_field("suggestion", "", decode.string)
        decode.success(#(topic, message, title, suggestion))
      }
      use #(topic, message, title, suggestion) <- result.try(parse(
        args,
        decoder,
      ))
      use topic <- result.try(paperclips.parse_topic(topic))
      paperclips.create(
        store,
        cwd,
        topic,
        title,
        message,
        suggestion,
        Some(session),
      )
      |> result.map(paperclips.to_json)
    }
    "paperclips.resolve" -> {
      let decoder = {
        use id <- decode.field("id", decode.int)
        use note <- decode.field("note", decode.string)
        decode.success(#(id, note))
      }
      use #(id, note) <- result.try(parse(args, decoder))
      paperclips.resolve(store, id, note, session)
      |> result.map(paperclips.to_json)
    }
    "paperclips.list" -> {
      let decoder = {
        use limit <- decode.optional_field("limit", 20, decode.int)
        decode.success(limit)
      }
      use limit <- result.try(parse(args, decoder))
      paperclips.list(store, limit)
      |> result.map(json.array(_, paperclips.to_json))
    }
    _ -> Error(paperclips.Invalid("unknown host operation"))
  }
}
