//// Albedo requests into Amazon Bedrock's Anthropic-shaped Messages route.
//// The body and headers are the same on bedrock-runtime and bedrock-mantle;
//// only the host differs, so one encoder covers both. Replay keeps text
//// and tool calls only; thinking is not carried across turns.

import albedo/harness/extensions/bedrock/sigv4.{type Credentials}
import albedo/harness/extensions/claude/schema
import albedo/openai_api
import albedo/openai_api/replay
import albedo/openai_api/types.{
  type Error, type Input, type Request, Assistant, InvalidRequest, Replay,
  ToolOutput, User, UserImage,
}
import gleam/bool
import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/string_tree

pub type Auth {
  Bearer(key: String)
  SigV4(credentials: Credentials)
}

type Message {
  Message(role: String, blocks: List(Json))
}

pub fn encode(
  auth: Auth,
  base_url: String,
  now: Int,
  request: Request,
) -> Result(openai_api.Exchange, Error) {
  use <- bool.guard(
    !string.contains(string.lowercase(request.model), "claude"),
    Error(InvalidRequest(
      "this Bedrock profile serves Claude models through the Anthropic Messages route; configure an anthropic.claude* model id",
    )),
  )
  use <- bool.guard(
    request.model == "" || request.max_output_tokens == Some(0),
    Error(InvalidRequest("invalid Bedrock model or output token limit")),
  )
  use #(host, region, service) <- result.try(target(base_url))
  use messages <- result.try(
    list.try_fold(request.input, [], fn(acc, input) { add(acc, input) }),
  )
  let messages =
    messages
    |> list.reverse
    |> list.map(fn(message) {
      json.object([
        #("role", json.string(message.role)),
        #("content", json.preprocessed_array(message.blocks)),
      ])
    })
  let fields = [
    #("model", json.string(request.model)),
    #("messages", json.preprocessed_array(messages)),
    #("max_tokens", json.int(option.unwrap(request.max_output_tokens, 8192))),
    #("stream", json.bool(True)),
  ]
  let fields = case request.instructions {
    Some(text) if text != "" -> [#("system", json.string(text)), ..fields]
    _ -> fields
  }
  let fields = case request.tools {
    [] -> fields
    tools -> [#("tools", json.array(tools, tool_block)), ..fields]
  }
  let fields = case request.options.tool_choice {
    Some(types.NoTool) -> [tool_choice("none", None), ..fields]
    Some(types.AnyTool) -> [tool_choice("any", None), ..fields]
    Some(types.NamedTool(name)) -> [tool_choice("tool", Some(name)), ..fields]
    _ -> fields
  }
  let fields = case request.options.effort {
    Some(effort) -> [
      #(
        "thinking",
        json.object([
          #("type", json.string("adaptive")),
          #("display", json.string("summarized")),
        ]),
      ),
      #("output_config", json.object([#("effort", json.string(effort))])),
      ..fields
    ]
    None -> fields
  }
  let body_tree = json.to_string_tree(json.object(fields))
  let body = string_tree.to_string(body_tree)
  let auth_headers = case auth {
    Bearer(key) -> [#("x-api-key", key)]
    SigV4(credentials) ->
      sigv4.headers(credentials, region, service, host, now, body)
  }
  Ok(openai_api.Exchange(
    "https://" <> host <> "/anthropic/v1/messages",
    list.flatten([
      auth_headers,
      [
        #("anthropic-version", "2023-06-01"),
        #("accept", "text/event-stream"),
      ],
    ]),
    body_tree,
    120_000,
    8 * 1024 * 1024,
    True,
  ))
}

/// `(host, region, service)` from a configured `baseUrl`. The SigV4
/// service name follows each endpoint's own IAM action namespace
/// (`bedrock:*` vs `bedrock-mantle:*`); mantle's has not been verified.
fn target(base_url: String) -> Result(#(String, String, String), Error) {
  let host =
    base_url
    |> string.replace("https://", "")
    |> string.replace("http://", "")
    |> string.trim
    |> string.split("/")
    |> list.first
    |> result.unwrap("")
  case string.split(host, ".") {
    ["bedrock-runtime", region, ..] -> Ok(#(host, region, "bedrock"))
    ["bedrock-mantle", region, ..] -> Ok(#(host, region, "bedrock-mantle"))
    _ ->
      Error(InvalidRequest(
        "baseUrl must be a bedrock-runtime or bedrock-mantle host, e.g. https://bedrock-runtime.us-east-1.amazonaws.com",
      ))
  }
}

fn add(acc: List(Message), input: Input) -> Result(List(Message), Error) {
  case input {
    User(text) -> Ok(push(acc, "user", [text_block(text)]))
    Assistant(text) -> Ok(push(acc, "assistant", [text_block(text)]))
    UserImage(text, images) -> {
      let image_blocks = list.map(images, image_block)
      let blocks = case text {
        "" -> image_blocks
        _ -> [text_block(text), ..image_blocks]
      }
      Ok(push(acc, "user", blocks))
    }
    ToolOutput(id, output, images) ->
      Ok(push(acc, "user", [tool_result_block(id, output, images)]))
    Replay(item) -> {
      use <- bool.guard(
        types.replay_protocol(item) == types.Responses,
        Error(InvalidRequest("cannot replay output across protocols")),
      )
      use message <- result.try(
        types.inspect_item(item, replay.message_decoder(detail_decoder()))
        |> result.replace_error(InvalidRequest(
          "replayed assistant message is not portable",
        )),
      )
      let blocks =
        list.append(
          case message.text {
            "" -> []
            text -> [text_block(text)]
          },
          list.map(message.calls, fn(call) {
            tool_use_block(call.id, call.name, call.arguments)
          }),
        )
      Ok(push(acc, "assistant", blocks))
    }
  }
}

fn detail_decoder() -> decode.Decoder(Option(Nil)) {
  decode.success(None)
}

/// Adjacent turns of one role merge: Anthropic rejects back-to-back messages
/// of the same role, and a run of tool results arrives as separate inputs.
fn push(acc: List(Message), role: String, blocks: List(Json)) -> List(Message) {
  case blocks, acc {
    [], _ -> acc
    _, [Message(last, previous), ..rest] if last == role -> [
      Message(role, list.append(previous, blocks)),
      ..rest
    ]
    _, _ -> [Message(role, blocks), ..acc]
  }
}

fn text_block(text: String) -> Json {
  json.object([#("type", json.string("text")), #("text", json.string(text))])
}

fn image_block(image: types.Image) -> Json {
  let #(mime_type, _, _, _) = types.image_meta(image)
  json.object([
    #("type", json.string("image")),
    #(
      "source",
      json.object([
        #("type", json.string("base64")),
        #("media_type", json.string(mime_type)),
        #("data", types.base64_string(types.image_data(image))),
      ]),
    ),
  ])
}

fn tool_use_block(id: String, name: String, arguments: String) -> Json {
  let input =
    json.parse(arguments, decode.dynamic)
    |> result.map(types.encode_value)
    |> result.unwrap(json.object([]))
  json.object([
    #("type", json.string("tool_use")),
    #("id", json.string(id)),
    #("name", json.string(name)),
    #("input", input),
  ])
}

fn tool_result_block(
  id: String,
  output: String,
  images: List(types.Image),
) -> Json {
  let content = case output, images {
    "", [] -> [text_block("")]
    _, _ -> [text_block(output), ..list.map(images, image_block)]
  }
  json.object([
    #("type", json.string("tool_result")),
    #("tool_use_id", json.string(id)),
    #("content", json.preprocessed_array(content)),
  ])
}

fn tool_block(tool: types.Tool) -> Json {
  json.object([
    #("name", json.string(tool.name)),
    #("description", json.string(tool.description)),
    #("input_schema", schema.normalize(tool.parameters)),
  ])
}

fn tool_choice(kind: String, name: Option(String)) -> #(String, Json) {
  let fields = [#("type", json.string(kind))]
  let fields = case name {
    Some(name) -> [#("name", json.string(name)), ..fields]
    None -> fields
  }
  #("tool_choice", json.object(fields))
}
