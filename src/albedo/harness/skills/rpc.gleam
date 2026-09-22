//// Session-scoped Python RPC over one immutable skills catalog snapshot.

import albedo/harness/skills/catalog
import gleam/dynamic/decode
import gleam/json
import gleam/result

pub fn handle(snapshot: catalog.Catalog, request: String) -> String {
  let decoder = {
    use method <- decode.field("method", decode.string)
    use args <- decode.field("args", decode.dynamic)
    decode.success(#(method, args))
  }
  let answer = {
    use #(method, args) <- result.try(
      json.parse(request, decoder)
      |> result.replace_error("invalid skills host request"),
    )
    dispatch(snapshot, method, args)
  }
  case answer {
    Ok(value) -> json.object([#("ok", json.bool(True)), #("value", value)])
    Error(message) ->
      json.object([
        #("ok", json.bool(False)),
        #("code", json.string("skills")),
        #("message", json.string(message)),
      ])
  }
  |> json.to_string
}

fn dispatch(snapshot, method, args) {
  case method {
    "skills.resources" -> {
      use name <- result.try(parse(
        args,
        decode.field("name", decode.string, decode.success),
      ))
      catalog.resources(snapshot, name) |> result.map(resources_json)
    }
    "skills.read" -> {
      let decoder = {
        use name <- decode.field("name", decode.string)
        use resource <- decode.optional_field(
          "resource",
          "SKILL.md",
          decode.string,
        )
        use offset <- decode.optional_field("offset", 0, decode.int)
        use limit <- decode.optional_field("limit", 16_384, decode.int)
        decode.success(#(name, resource, offset, limit))
      }
      use values <- result.try(parse(args, decoder))
      catalog.read(snapshot, values.0, values.1, values.2, values.3)
      |> result.map(page_json)
    }
    _ -> Error("unknown skills host operation")
  }
}

fn parse(args, decoder) {
  decode.run(args, decoder)
  |> result.replace_error("invalid skills arguments")
}

pub fn activation_json(activation: catalog.Activation) -> json.Json {
  json.object([
    #("name", json.string(activation.name)),
    #("description", json.string(activation.description)),
    #("source", json.string(activation.source)),
    #("arguments", json.string(activation.arguments)),
    #("instructions", json.string(activation.instructions)),
  ])
}

fn resources_json(resources: catalog.Resources) -> json.Json {
  json.object([
    #("resources", json.array(resources.names, json.string)),
    #("truncated", json.bool(resources.truncated)),
    #("diagnostics", json.array(resources.diagnostics, json.string)),
  ])
}

fn page_json(page: catalog.Page) -> json.Json {
  json.object([
    #("path", json.string(page.path)),
    #("encoding", json.string(page.encoding)),
    #("content", json.string(page.content)),
    #("next_offset", json.int(page.next_offset)),
    #("truncated", json.bool(page.truncated)),
    #("size", json.int(page.size)),
  ])
}
