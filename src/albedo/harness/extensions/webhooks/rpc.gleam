import albedo/daemon/store
import albedo/harness/extensions/webhooks/ledger as hooks
import gleam/bit_array
import gleam/dynamic/decode
import gleam/json
import gleam/option.{None}
import gleam/result

pub fn handle(db: store.Store, session: String, request: String) -> String {
  let decoder = {
    use method <- decode.field("method", decode.string)
    use args <- decode.field("args", decode.dynamic)
    decode.success(#(method, args))
  }
  let answer = {
    use #(method, args) <- result.try(
      json.parse(request, decoder)
      |> result.replace_error(hooks.Invalid("invalid request")),
    )
    dispatch(db, session, method, args)
  }
  case answer {
    Ok(value) -> json.object([#("ok", json.bool(True)), #("value", value)])
    Error(error) -> {
      let #(code, message) = case error {
        hooks.Invalid(message) -> #("invalid", message)
        hooks.Denied -> #("denied", "agent webhook management is disabled")
        hooks.NotFound -> #("not_found", "hook or delivery not found")
        hooks.Conflict -> #("conflict", "hook changed; list and retry")
        hooks.Unauthorized -> #("unauthorized", "invalid signature")
        hooks.Overloaded -> #("overloaded", "inbox full")
        hooks.Storage(message) -> #("storage", message)
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
  |> result.replace_error(hooks.Invalid("invalid webhook arguments"))
}

fn dispatch(db, session, method, args) {
  let actor = hooks.Agent(session)
  case method {
    "webhooks.list" ->
      hooks.list(db, actor, session) |> result.map(json.array(_, hooks.to_json))
    "webhooks.delivery" -> {
      use id <- result.try(parse(
        args,
        decode.field("id", decode.string, decode.success),
      ))
      use item <- result.try(hooks.delivery(db, session, id))
      let body =
        bit_array.to_string(item.body) |> result.unwrap("[binary payload]")
      Ok(
        json.object([
          #("id", json.string(item.id)),
          #("hook", json.string(item.hook)),
          #("name", json.string(item.name)),
          #("body", json.string(body)),
        ]),
      )
    }
    "webhooks.create" -> {
      let decoder = {
        use name <- decode.field("name", decode.string)
        use secret <- decode.optional_field(
          "secret",
          None,
          decode.optional(decode.string),
        )
        decode.success(#(name, secret))
      }
      use #(name, secret) <- result.try(parse(args, decoder))
      hooks.create(db, actor, session, name, secret)
      |> result.map(provisioned)
    }
    "webhooks.rotate" -> {
      let decoder = {
        use id <- decode.field("id", decode.string)
        use revision <- decode.field("revision", decode.int)
        use secret <- decode.optional_field(
          "secret",
          None,
          decode.optional(decode.string),
        )
        decode.success(#(id, revision, secret))
      }
      use #(id, revision, secret) <- result.try(parse(args, decoder))
      use hook <- result.try(hooks.get(db, actor, session, id))
      case hook.revision == revision {
        False -> Error(hooks.Conflict)
        True ->
          hooks.rotate(db, actor, session, id, revision, secret)
          |> result.map(provisioned)
      }
    }
    "webhooks.configure" -> {
      let decoder = {
        use id <- decode.field("id", decode.string)
        use revision <- decode.field("revision", decode.int)
        use header <- decode.field("header", decode.string)
        use prefix <- decode.field("prefix", decode.string)
        decode.success(#(id, revision, header, prefix))
      }
      use #(id, revision, header, prefix) <- result.try(parse(args, decoder))
      hooks.configure(db, actor, session, id, revision, header, prefix)
      |> result.map(hooks.to_json)
    }
    "webhooks.enable" | "webhooks.disable" | "webhooks.delete" -> {
      let decoder = {
        use id <- decode.field("id", decode.string)
        use revision <- decode.field("revision", decode.int)
        decode.success(#(id, revision))
      }
      use #(id, revision) <- result.try(parse(args, decoder))
      let changed = case method {
        "webhooks.delete" -> hooks.delete(db, actor, session, id, revision)
        _ ->
          hooks.set_enabled(
            db,
            actor,
            session,
            id,
            revision,
            method == "webhooks.enable",
          )
      }
      changed |> result.map(hooks.to_json)
    }
    _ -> Error(hooks.Invalid("unknown webhook method"))
  }
}

fn provisioned(receipt: hooks.Provisioned) -> json.Json {
  json.object([
    #("hook", hooks.to_json(receipt.hook)),
    #("secret", json.string(receipt.secret)),
  ])
}
