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

/// Encode to iodata; the request is never flattened. Each input's small
/// fragments are coalesced as it is encoded (see `flatten`).
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
      let max_tokens = case policy {
        OpenAI -> request.max_output_tokens
        Codex(_, _) -> None
      }
      [
        #("input", json.preprocessed_array(input)),
        #("store", json.bool(False)),
        #("include", json.array(["reasoning.encrypted_content"], json.string)),
        ..fields
      ]
      |> optional("instructions", request.instructions, json.string)
      |> optional("max_output_tokens", max_tokens, json.int)
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
  let options = request.options
  let tools = request.tools != []
  let fields = case policy, protocol {
    // The ChatGPT reasoning backend fixes sampling; only what it accepts
    // overrides its defaults.
    Codex(_, session_id), Responses -> [
      #(
        "tool_choice",
        option.map(options.tool_choice, tool_choice(protocol, _))
          |> option.unwrap(json.string("auto")),
      ),
      #(
        "parallel_tool_calls",
        json.bool(option.unwrap(options.parallel_tool_calls, True)),
      ),
      #(
        "text",
        json.object(
          [#("verbosity", json.string("low"))]
          |> optional("format", options.format, response_format(protocol, _)),
        ),
      ),
      #(
        "reasoning",
        json.object([
          #("effort", json.string(option.unwrap(options.effort, "medium"))),
          #("summary", json.string("auto")),
        ]),
      ),
      #("prompt_cache_key", json.string(session_id)),
      ..fields
    ]
    _, _ -> {
      let fields =
        fields
        |> sampling(options)
        |> optional("tool_choice", options.tool_choice, tool_choice(protocol, _))
        |> optional(
          "parallel_tool_calls",
          when_tools(tools, options.parallel_tool_calls),
          json.bool,
        )
      case protocol {
        Responses ->
          fields
          |> optional("reasoning", options.effort, fn(effort) {
            json.object([#("effort", json.string(effort))])
          })
          |> optional("text", options.format, fn(format) {
            json.object([#("format", response_format(protocol, format))])
          })
        ChatCompletions ->
          fields
          |> optional(
            "stop",
            case options.stop {
              [] -> None
              stop -> Some(stop)
            },
            json.array(_, json.string),
          )
          |> optional("reasoning_effort", options.effort, json.string)
          |> optional("response_format", options.format, response_format(
            protocol,
            _,
          ))
      }
    }
  }
  Ok(json.to_string_tree(json.object(fields)))
}

fn validate(request: Request) -> Result(Nil, Error) {
  case string.is_empty(string.trim(request.model)), request.max_output_tokens {
    True, _ -> Error(InvalidRequest("model must not be empty"))
    _, Some(n) if n <= 0 ->
      Error(InvalidRequest("max_output_tokens must be positive"))
    _, _ -> validate_tools(request.tools)
  }
}

fn validate_tools(tools: List(Tool)) -> Result(Nil, Error) {
  list.try_fold(tools, [], fn(seen, tool) {
    case string.is_empty(tool.name), list.contains(seen, tool.name) {
      True, _ -> Error(InvalidRequest("tool name must not be empty"))
      _, True -> Error(InvalidRequest("duplicate tool name: " <> tool.name))
      _, _ -> Ok([tool.name, ..seen])
    }
  })
  |> result.replace(Nil)
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
          flatten(
            json.object([
              #("role", json.string("user")),
              #("content", json.preprocessed_array(images)),
            ]),
          ),
          ..encoded
        ]
      }
      encode_inputs(protocol, rest, encoded)
    }
    _, [input, ..rest] -> {
      use json <- result.try(encode_input(protocol, input))
      encode_inputs(protocol, rest, [flatten(json), ..encoded])
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
      let tool = chat_tool_message(id, text, attached)
      let images = case attached {
        [] -> images
        _ ->
          list.flatten([
            images,
            [text_part(ChatCompletions, "Images from tool call " <> id <> ":")],
            list.map(attached, image_part(ChatCompletions, _)),
          ])
      }
      chat_tool_run(rest, [flatten(tool), ..encoded], images)
    }
    rest -> #(encoded, images, rest)
  }
}

fn chat_tool_message(
  id: String,
  text: String,
  images: List(types.Image),
) -> Json {
  json.object([
    #("role", json.string("tool")),
    #("tool_call_id", json.string(id)),
    #("content", json.string(tool_text(text, images))),
  ])
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
              _ -> {
                let parts = list.map(images, image_part(Responses, _))
                json.preprocessed_array(case text {
                  "" -> parts
                  _ -> [text_part(Responses, text), ..parts]
                })
              }
            }),
          ])
        ChatCompletions -> chat_tool_message(id, text, images)
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
  // An empty text part is rejected by some endpoints, and frame archives
  // attach images with no text by design.
  let img = image_part(protocol, image)
  let parts = case text {
    "" -> [img]
    _ -> [text_part(protocol, text), img]
  }
  json.object([
    #("role", json.string("user")),
    #("content", json.preprocessed_array(parts)),
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
  let #(mime_type, _, _, _) = types.image_meta(image)
  let url = data_url(mime_type, types.image_data(image))
  case protocol {
    Responses ->
      json.object([
        #("type", json.string("input_image")),
        #("detail", json.string("auto")),
        #("image_url", url),
      ])
    ChatCompletions ->
      json.object([
        #("type", json.string("image_url")),
        #("image_url", json.object([#("url", url)])),
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

/// OpenAI rejects `parallel_tool_calls` on a request without tools.
fn when_tools(tools: Bool, value: Option(Bool)) -> Option(Bool) {
  case tools {
    True -> value
    False -> None
  }
}

fn sampling(
  fields: List(#(String, Json)),
  options: types.Options,
) -> List(#(String, Json)) {
  fields
  |> optional("temperature", options.temperature, json.float)
  |> optional("top_p", options.top_p, json.float)
}

fn tool_choice(protocol: Protocol, choice: types.ToolChoice) -> Json {
  case choice, protocol {
    types.AutoTool, _ -> json.string("auto")
    types.NoTool, _ -> json.string("none")
    types.AnyTool, _ -> json.string("required")
    types.NamedTool(name), Responses ->
      json.object([
        #("type", json.string("function")),
        #("name", json.string(name)),
      ])
    types.NamedTool(name), ChatCompletions ->
      json.object([
        #("type", json.string("function")),
        #("function", json.object([#("name", json.string(name))])),
      ])
  }
}

/// Chat Completions nests a schema under `json_schema`; Responses flattens it
/// into `text.format`.
fn response_format(protocol: Protocol, format: types.Format) -> Json {
  case format {
    types.JsonObject -> json.object([#("type", json.string("json_object"))])
    types.JsonSchema(name, schema, strict) -> {
      let fields = [
        #("name", json.string(name)),
        #("schema", schema),
        #("strict", json.bool(strict)),
      ]
      json.object(case protocol {
        Responses -> [#("type", json.string("json_schema")), ..fields]
        ChatCompletions -> [
          #("type", json.string("json_schema")),
          #("json_schema", json.object(fields)),
        ]
      })
    }
  }
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

/// One encoded input with its small fragments coalesced while only that
/// input's fragments are live. The request then crosses to the HTTP connection
/// process as a short list of binaries, large ones shared rather than copied.
@external(erlang, "albedo_openai_json", "flatten")
fn flatten(json: Json) -> Json

@external(erlang, "albedo_openai_json", "data_url")
fn data_url(mime_type: String, data: types.ImageData) -> Json
