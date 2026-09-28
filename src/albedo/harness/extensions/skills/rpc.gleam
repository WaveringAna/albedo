//// Session-scoped Python RPC over one immutable skills catalog snapshot.

import albedo/harness/extensions/skills/catalog
import albedo/harness/rpc
import gleam/dynamic/decode
import gleam/json
import gleam/result

pub fn handle(snapshot: catalog.Catalog, request: String) -> String {
  rpc.serve(
    request,
    "invalid skills host request",
    fn(method, args) { dispatch(snapshot, method, args) },
    fn(message) { #("skills", message) },
  )
}

fn parse(args, decoder) {
  rpc.args(args, decoder, "invalid skills arguments")
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
      use #(name, resource, offset, limit) <- result.try(parse(args, decoder))
      catalog.read(snapshot, name, resource, offset, limit)
      |> result.map(page_json)
    }
    _ -> Error("unknown skills host operation")
  }
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
