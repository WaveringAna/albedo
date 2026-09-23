import albedo/openai_api/types.{
  type Error, type Input, type Protocol, type ProviderPolicy, type Request,
  type Tool, Assistant, ChatCompletions, Codex, InvalidRequest, OpenAI, Replay,
  Responses, ToolOutput, User, UserImage,
}
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/string_tree.{type StringTree}

/// Encode directly to iodata; never flatten the complete request for HTTP.
pub fn encode(
  protocol: Protocol,
  request: Request,
) -> Result(StringTree, Error) {
  encode_with_policy(protocol, OpenAI, request)
}

pub fn encode_with_policy(
  protocol: Protocol,
  policy: ProviderPolicy,
  request: Request,
) -> Result(StringTree, Error) {
  use _ <- result.try(validate(request))
  use input <- result.try(encode_inputs(protocol, request.input, []))
  let fields = [
    #("model", json.string(request.model)),
    #("stream", json.bool(True)),
  ]
  let fields = case protocol {
    Responses -> {
      let fields = [
        #("input", json.preprocessed_array(input)),
        #("store", json.bool(False)),
        #("include", json.array(["reasoning.encrypted_content"], json.string)),
        ..fields
      ]
      let fields =
        optional(fields, "instructions", request.instructions, json.string)
      case policy {
        OpenAI ->
          optional(
            fields,
            "max_output_tokens",
            request.max_output_tokens,
            json.int,
          )
        Codex(_, _) -> fields
      }
    }
    ChatCompletions -> {
      let messages = case request.instructions {
        None -> input
        Some(text) -> [message("system", text), ..input]
      }
      [
        #("messages", json.preprocessed_array(messages)),
        #("n", json.int(1)),
        #("stream_options", json.object([#("include_usage", json.bool(True))])),
        ..fields
      ]
      |> optional("max_completion_tokens", request.max_output_tokens, json.int)
    }
  }
  let fields = case request.tools {
    [] -> fields
    tools -> [
      #("tools", json.array(tools, encode_tool(protocol, policy, _))),
      ..fields
    ]
  }
  let fields = case policy, protocol {
    Codex(_, session_id), Responses -> [
      #("tool_choice", json.string("auto")),
      #("parallel_tool_calls", json.bool(True)),
      #("text", json.object([#("verbosity", json.string("low"))])),
      #(
        "reasoning",
        json.object([
          #("effort", json.string("medium")),
          #("summary", json.string("auto")),
        ]),
      ),
      #("prompt_cache_key", json.string(session_id)),
      ..fields
    ]
    _, _ -> fields
  }
  Ok(json.to_string_tree(json.object(fields)))
}

fn validate(request: Request) -> Result(Nil, Error) {
  case string.is_empty(string.trim(request.model)), request.max_output_tokens {
    True, _ -> Error(InvalidRequest("model must not be empty"))
    _, Some(n) if n <= 0 ->
      Error(InvalidRequest("max_output_tokens must be positive"))
    _, _ -> validate_tools(request.tools, [])
  }
}

fn validate_tools(tools: List(Tool), seen: List(String)) -> Result(Nil, Error) {
  case tools {
    [] -> Ok(Nil)
    [tool, ..rest] ->
      case string.is_empty(tool.name), list.contains(seen, tool.name) {
        True, _ -> Error(InvalidRequest("tool name must not be empty"))
        _, True -> Error(InvalidRequest("duplicate tool name: " <> tool.name))
        _, _ -> validate_tools(rest, [tool.name, ..seen])
      }
  }
}

fn encode_inputs(
  protocol: Protocol,
  inputs: List(Input),
  encoded: List(Json),
) -> Result(List(Json), Error) {
  case protocol, inputs {
    _, [] -> Ok(list.reverse(encoded))
    // Chat Completions tool messages carry text only, and nothing may come
    // between an assistant's tool calls and their results. The images of a
    // whole run of results follow it in one user message, labelled per call.
    ChatCompletions, [ToolOutput(..), ..] -> {
      let #(encoded, images, rest) = chat_tool_run(inputs, encoded, [])
      let encoded = case images {
        [] -> encoded
        _ -> [
          json.object([
            #("role", json.string("user")),
            #("content", json.preprocessed_array(images)),
          ]),
          ..encoded
        ]
      }
      encode_inputs(protocol, rest, encoded)
    }
    _, [input, ..rest] -> {
      use json <- result.try(encode_input(protocol, input))
      encode_inputs(protocol, rest, [json, ..encoded])
    }
  }
}

fn chat_tool_run(
  inputs: List(Input),
  encoded: List(Json),
  images: List(Json),
) -> #(List(Json), List(Json), List(Input)) {
  case inputs {
    [ToolOutput(id, text, attached), ..rest] -> {
      let tool =
        json.object([
          #("role", json.string("tool")),
          #("tool_call_id", json.string(id)),
          #("content", json.string(tool_text(text, attached))),
        ])
      let images = case attached {
        [] -> images
        _ ->
          list.flatten([
            images,
            [text_part(ChatCompletions, "Images from tool call " <> id <> ":")],
            list.map(attached, image_part(ChatCompletions, _)),
          ])
      }
      chat_tool_run(rest, [tool, ..encoded], images)
    }
    rest -> #(encoded, images, rest)
  }
}

/// Some providers reject an empty tool result even when images accompany it.
fn tool_text(text: String, images: List(types.Image)) -> String {
  case text, images {
    "", [_, ..] -> "(see attached image)"
    _, _ -> text
  }
}

fn encode_input(protocol: Protocol, input: Input) -> Result(Json, Error) {
  case input {
    User(text) -> Ok(message("user", text))
    UserImage(text, image) -> Ok(image_message(protocol, text, image))
    Assistant(text) -> Ok(message("assistant", text))
    ToolOutput(id, text, images) ->
      Ok(case protocol {
        Responses ->
          json.object([
            #("type", json.string("function_call_output")),
            #("call_id", json.string(id)),
            #("output", case images {
              [] -> json.string(text)
              _ ->
                json.preprocessed_array(case text {
                  "" -> list.map(images, image_part(Responses, _))
                  _ -> [
                    text_part(Responses, text),
                    ..list.map(images, image_part(Responses, _))
                  ]
                })
            }),
          ])
        ChatCompletions ->
          json.object([
            #("role", json.string("tool")),
            #("tool_call_id", json.string(id)),
            #("content", json.string(tool_text(text, images))),
          ])
      })
    Replay(item) ->
      case types.replay_protocol(item) == protocol {
        True -> Ok(types.replay_json(item))
        False -> Error(InvalidRequest("cannot replay output across protocols"))
      }
  }
}

fn message(role: String, content: String) -> Json {
  json.object([#("role", json.string(role)), #("content", json.string(content))])
}

fn image_message(protocol: Protocol, text: String, image: types.Image) -> Json {
  json.object([
    #("role", json.string("user")),
    #(
      "content",
      json.preprocessed_array([
        text_part(protocol, text),
        image_part(protocol, image),
      ]),
    ),
  ])
}

fn text_part(protocol: Protocol, text: String) -> Json {
  let kind = case protocol {
    Responses -> "input_text"
    ChatCompletions -> "text"
  }
  json.object([#("type", json.string(kind)), #("text", json.string(text))])
}

fn image_part(protocol: Protocol, image: types.Image) -> Json {
  let #(mime_type, data, _, _, _) = types.image_parts(image)
  let url = "data:" <> mime_type <> ";base64," <> data
  case protocol {
    Responses ->
      json.object([
        #("type", json.string("input_image")),
        #("detail", json.string("auto")),
        #("image_url", json.string(url)),
      ])
    ChatCompletions ->
      json.object([
        #("type", json.string("image_url")),
        #("image_url", json.object([#("url", json.string(url))])),
      ])
  }
}

/// The exact provider-facing tool schema array used by `encode`.
/// Context inspection can reuse this without rebuilding request policy.
pub fn encode_tools(protocol: Protocol, tools: List(Tool)) -> Json {
  json.array(tools, encode_tool(protocol, OpenAI, _))
}

fn encode_tool(protocol: Protocol, policy: ProviderPolicy, tool: Tool) -> Json {
  let fields = [
    #("name", json.string(tool.name)),
    #("description", json.string(tool.description)),
    #("parameters", tool.parameters),
    #("strict", case policy {
      Codex(_, _) -> json.null()
      OpenAI -> json.bool(tool.strict)
    }),
  ]
  json.object(case protocol {
    Responses -> [#("type", json.string("function")), ..fields]
    ChatCompletions -> [
      #("type", json.string("function")),
      #("function", json.object(fields)),
    ]
  })
}

fn optional(
  fields: List(#(String, Json)),
  key: String,
  value: Option(a),
  encode: fn(a) -> Json,
) -> List(#(String, Json)) {
  case value {
    None -> fields
    Some(value) -> [#(key, encode(value)), ..fields]
  }
}
