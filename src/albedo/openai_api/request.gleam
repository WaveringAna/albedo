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
  use input <- result.try(
    list.try_map(request.input, encode_input(protocol, _)),
  )
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

fn encode_input(protocol: Protocol, input: Input) -> Result(Json, Error) {
  case input {
    User(text) -> Ok(message("user", text))
    UserImage(text, image) -> Ok(image_message(protocol, text, image))
    Assistant(text) -> Ok(message("assistant", text))
    ToolOutput(id, text) ->
      Ok(case protocol {
        Responses ->
          json.object([
            #("type", json.string("function_call_output")),
            #("call_id", json.string(id)),
            #("output", json.string(text)),
          ])
        ChatCompletions ->
          json.object([
            #("role", json.string("tool")),
            #("tool_call_id", json.string(id)),
            #("content", json.string(text)),
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
  let #(mime_type, data, _, _, _) = types.image_parts(image)
  let url = "data:" <> mime_type <> ";base64," <> data
  let content = case protocol {
    Responses -> [
      json.object([
        #("type", json.string("input_text")),
        #("text", json.string(text)),
      ]),
      json.object([
        #("type", json.string("input_image")),
        #("detail", json.string("auto")),
        #("image_url", json.string(url)),
      ]),
    ]
    ChatCompletions -> [
      json.object([
        #("type", json.string("text")),
        #("text", json.string(text)),
      ]),
      json.object([
        #("type", json.string("image_url")),
        #("image_url", json.object([#("url", json.string(url))])),
      ]),
    ]
  }
  json.object([
    #("role", json.string("user")),
    #("content", json.preprocessed_array(content)),
  ])
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
