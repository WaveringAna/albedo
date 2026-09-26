//// Albedo chat history into Anthropic Messages. Replay preserves Claude's
//// signed thinking blocks; foreign-model turns replay as text and tool calls.

import albedo/openai_api
import albedo/openai_api/types
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

type Message {
  Message(role: String, blocks: List(Json))
}

type History {
  History(messages: List(Message), calls: Dict(String, String))
}

pub const blocks_detail = "claude.blocks"

pub fn encode(
  access: String,
  request: types.Request,
) -> Result(openai_api.Exchange, types.Error) {
  use _ <- result.try(
    case
      access != ""
      && !string.contains(access, "\r")
      && !string.contains(access, "\n")
    {
      True -> Ok(Nil)
      False -> Error(types.InvalidRequest("invalid Claude access token"))
    },
  )
  use history <- result.try(
    list.try_fold(request.input, History([], dict.new()), fn(history, input) {
      add(history, input, request.model)
    }),
  )
  let messages =
    history.messages
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
    #(
      "system",
      json.array(
        [
          "You are Claude Code, Anthropic's official CLI for Claude.",
          ..case request.instructions {
            Some(text) -> [text]
            None -> []
          }
        ],
        fn(text) { text_block(text) },
      ),
    ),
  ]
  let fields = case request.tools {
    [] -> fields
    tools -> [
      #(
        "tools",
        json.array(tools, fn(tool) {
          json.object([
            #("name", json.string(claude_name(tool.name))),
            #("description", json.string(tool.description)),
            #("input_schema", normalize_schema(tool.parameters)),
          ])
        }),
      ),
      ..fields
    ]
  }
  let fields = case request.options.tool_choice {
    Some(types.NoTool) -> [
      #("tool_choice", json.object([#("type", json.string("none"))])),
      ..fields
    ]
    Some(types.AnyTool) -> [
      #("tool_choice", json.object([#("type", json.string("any"))])),
      ..fields
    ]
    Some(types.NamedTool(name)) -> [
      #(
        "tool_choice",
        json.object([
          #("type", json.string("tool")),
          #("name", json.string(claude_name(name))),
        ]),
      ),
      ..fields
    ]
    _ -> fields
  }
  let fields = case request.options.effort {
    Some(effort) if request.model != "claude-haiku-4-5" -> [
      #("thinking", json.object([#("type", json.string("adaptive"))])),
      #("output_config", json.object([#("effort", json.string(effort))])),
      ..fields
    ]
    _ -> fields
  }
  case request.model == "" || request.max_output_tokens == Some(0) {
    True ->
      Error(types.InvalidRequest("invalid Claude model or output token limit"))
    False ->
      Ok(openai_api.Exchange(
        "https://api.anthropic.com/v1/messages",
        [
          #("authorization", "Bearer " <> access),
          #("anthropic-version", "2023-06-01"),
          #("anthropic-beta", "claude-code-20250219,oauth-2025-04-20"),
          #("user-agent", "claude-cli/2.1.261"),
          #("x-app", "cli"),
          #("anthropic-dangerous-direct-browser-access", "true"),
          #("content-type", "application/json"),
          #("accept", "text/event-stream"),
        ],
        json.to_string_tree(json.object(fields)),
        120_000,
        8 * 1024 * 1024,
        True,
      ))
  }
}

fn add(
  history: History,
  input: types.Input,
  model: String,
) -> Result(History, types.Error) {
  case input {
    types.User(text) -> Ok(push(history, "user", [text_block(text)]))
    types.Assistant(text) -> Ok(push(history, "assistant", [text_block(text)]))
    types.UserImage(text, image) ->
      Ok(push(history, "user", [text_block(text), image_block(image)]))
    types.ToolOutput(id, text, images) -> {
      use _ <- result.try(
        dict.get(history.calls, id)
        |> result.replace_error(types.InvalidRequest(
          "tool output without preceding Claude tool call: " <> id,
        )),
      )
      let content = case images {
        [] -> json.string(text)
        images ->
          json.preprocessed_array([
            text_block(text),
            ..list.map(images, image_block)
          ])
      }
      Ok(
        push(history, "user", [
          json.object([
            #("type", json.string("tool_result")),
            #("tool_use_id", json.string(id)),
            #("content", content),
          ]),
        ]),
      )
    }
    types.Replay(item) -> {
      use message <- result.try(
        types.inspect_item(item, replay_decoder())
        |> result.map_error(fn(_) {
          types.InvalidRequest("invalid assistant replay message")
        }),
      )
      let blocks = case
        message.original_model == model,
        message.original_blocks
      {
        True, Some(blocks) -> blocks
        _, _ -> portable_blocks(message)
      }
      let calls =
        list.fold(message.calls, history.calls, fn(calls, call) {
          dict.insert(calls, call.id, call.name)
        })
      Ok(push(History(..history, calls: calls), "assistant", blocks))
    }
  }
}

type Replay {
  Replay(
    text: String,
    calls: List(types.ToolCall),
    original_model: String,
    original_blocks: Option(List(Json)),
  )
}

fn replay_decoder() -> decode.Decoder(Replay) {
  let call = {
    use id <- decode.field("id", decode.string)
    use name <- decode.subfield(["function", "name"], decode.string)
    use args <- decode.subfield(["function", "arguments"], decode.string)
    decode.success(types.ToolCall(id, name, args))
  }
  let detail = {
    use kind <- decode.field("type", decode.string)
    use model <- decode.optional_field("model", "", decode.string)
    use blocks <- decode.optional_field(
      "blocks",
      [],
      decode.list(decode.dynamic),
    )
    decode.success(case kind == blocks_detail {
      True -> Some(#(model, list.map(blocks, encode_value)))
      False -> None
    })
  }
  use text <- decode.optional_field(
    "content",
    None,
    decode.optional(decode.string),
  )
  use calls <- decode.optional_field(
    "tool_calls",
    [],
    decode.optional(decode.list(call)) |> decode.map(option.unwrap(_, [])),
  )
  use details <- decode.optional_field(
    "reasoning_details",
    [],
    decode.optional(decode.list(detail)) |> decode.map(option.unwrap(_, [])),
  )
  let original =
    details
    |> list.filter_map(fn(x) {
      case x {
        Some(v) -> Ok(v)
        None -> Error(Nil)
      }
    })
    |> list.first
    |> option.from_result
  let #(model, blocks) = case original {
    Some(#(model, blocks)) -> #(model, Some(blocks))
    None -> #("", None)
  }
  decode.success(Replay(option.unwrap(text, ""), calls, model, blocks))
}

fn portable_blocks(message: Replay) -> List(Json) {
  let text = case message.text {
    "" -> []
    text -> [text_block(text)]
  }
  list.append(
    text,
    list.map(message.calls, fn(call) {
      let input =
        json.parse(call.arguments, decode.dynamic)
        |> result.map(encode_value)
        |> result.unwrap(json.object([]))
      json.object([
        #("type", json.string("tool_use")),
        #("id", json.string(call.id)),
        #("name", json.string(claude_name(call.name))),
        #("input", input),
      ])
    }),
  )
}

/// Merge adjacent roles; Anthropic requires alternating user/assistant turns.
fn push(history: History, role: String, blocks: List(Json)) -> History {
  case history.messages {
    [Message(last, previous), ..rest] if last == role ->
      History(..history, messages: [
        Message(role, list.append(previous, blocks)),
        ..rest
      ])
    messages ->
      History(..history, messages: [Message(role, blocks), ..messages])
  }
}

fn text_block(text: String) -> Json {
  json.object([#("type", json.string("text")), #("text", json.string(text))])
}

fn image_block(image: types.Image) -> Json {
  let #(mime, _, _, _) = types.image_meta(image)
  json.object([
    #("type", json.string("image")),
    #(
      "source",
      json.object([
        #("type", json.string("base64")),
        #("media_type", json.string(mime)),
        #("data", base64_string(types.image_data(image))),
      ]),
    ),
  ])
}

/// Only canonical Claude Code names are changed; other albedo tool names stay intact.
pub fn claude_name(name: String) -> String {
  let known = [
    "Read",
    "Write",
    "Edit",
    "Bash",
    "Grep",
    "Glob",
    "AskUserQuestion",
    "EnterPlanMode",
    "ExitPlanMode",
    "KillShell",
    "NotebookEdit",
    "Skill",
    "Task",
    "TaskOutput",
    "TodoWrite",
    "WebFetch",
    "WebSearch",
  ]
  known
  |> list.find(fn(canonical) {
    string.lowercase(canonical) == string.lowercase(name)
  })
  |> result.unwrap(name)
}

@external(erlang, "albedo_claude_schema", "normalize")
pub fn normalize_schema(schema: Json) -> Json

@external(erlang, "albedo_openai_json", "base64_string")
fn base64_string(data: types.ImageData) -> Json

@external(erlang, "albedo_antigravity", "encode")
pub fn encode_value(value: Dynamic) -> Json
