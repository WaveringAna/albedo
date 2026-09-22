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
    "skills.list" ->
      Ok(
        json.object([
          #("skills", json.array(catalog.commands(snapshot), command_json)),
          #("diagnostics", json.array(snapshot.diagnostics, json.string)),
        ]),
      )
    "skills.activate" -> {
      let decoder = {
        use name <- decode.field("name", decode.string)
        use arguments <- decode.optional_field("arguments", "", decode.string)
        decode.success(#(name, arguments))
      }
      use values <- result.try(parse(args, decoder))
      catalog.activate(snapshot, values.0, values.1)
      |> result.map(activation_json)
    }
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

pub fn command_json(command: catalog.Command) -> json.Json {
  json.object([
    #("name", json.string(command.name)),
    #("description", json.string(command.description)),
    #("command", json.string(command.command)),
    #("source", json.string(command.source)),
  ])
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

pub fn decode_commands_response(
  response: String,
) -> Result(#(List(catalog.Command), List(String)), String) {
  let command = {
    use name <- decode.field("name", decode.string)
    use description <- decode.field("description", decode.string)
    use command <- decode.field("command", decode.string)
    use source <- decode.field("source", decode.string)
    decode.success(catalog.Command(name, description, command, source))
  }
  let value = {
    use skills <- decode.field("skills", decode.list(command))
    use diagnostics <- decode.field("diagnostics", decode.list(decode.string))
    decode.success(#(skills, diagnostics))
  }
  case response_ok(response) {
    Error(error) -> Error(error)
    Ok(_) ->
      json.parse(response, decode.field("value", value, decode.success))
      |> result.replace_error("invalid skills list response")
  }
}

pub fn decode_activation_response(
  response: String,
) -> Result(catalog.Activation, String) {
  let value = {
    use name <- decode.field("name", decode.string)
    use description <- decode.field("description", decode.string)
    use source <- decode.field("source", decode.string)
    use arguments <- decode.field("arguments", decode.string)
    use instructions <- decode.field("instructions", decode.string)
    decode.success(catalog.Activation(
      name,
      description,
      source,
      arguments,
      instructions,
    ))
  }
  case response_ok(response) {
    Error(error) -> Error(error)
    Ok(_) ->
      json.parse(response, decode.field("value", value, decode.success))
      |> result.replace_error("invalid skill activation response")
  }
}

fn response_ok(response: String) -> Result(Nil, String) {
  case json.parse(response, decode.field("ok", decode.bool, decode.success)) {
    Ok(True) -> Ok(Nil)
    Ok(False) ->
      case
        json.parse(
          response,
          decode.field("message", decode.string, decode.success),
        )
      {
        Ok(message) -> Error(message)
        Error(_) -> Error("skills extension request failed")
      }
    Error(_) -> Error("invalid skills extension response")
  }
}
