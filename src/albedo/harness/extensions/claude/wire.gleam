//// Albedo chat history into Anthropic Messages. Replay preserves Claude's
//// signed thinking blocks; foreign-model turns replay as text and tool calls.

import albedo/openai_api
import albedo/openai_api/types
import gleam/bit_array
import gleam/crypto.{Sha256}
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

type Files {
  Files(home: String, account: String)
}

type History {
  History(messages: List(Message), calls: Dict(String, String))
}

pub const blocks_detail = "claude.blocks"

const claude_code_version = "2.1.283"

pub fn encode(
  home: String,
  access: String,
  account: String,
  device: String,
  session: String,
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
  let files = Files(home, account)
  let input_count = list.length(request.input)
  use history <- result.try(
    list.try_fold(
      list.index_map(request.input, fn(input, index) { #(input, index) }),
      History([], dict.new()),
      fn(history, indexed) {
        add(
          history,
          indexed.0,
          request.model,
          files,
          indexed.1 + 1 == input_count,
        )
      },
    ),
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
  let first_user =
    request.input
    |> list.find_map(fn(input) {
      case input {
        types.User(text) | types.UserImage(text, _) -> Ok(text)
        _ -> Error(Nil)
      }
    })
    |> result.unwrap("")
  let fields = [
    #("model", json.string(request.model)),
    #("messages", json.preprocessed_array(messages)),
    #("max_tokens", json.int(option.unwrap(request.max_output_tokens, 8192))),
    #("stream", json.bool(True)),
    #(
      "metadata",
      json.object([
        #(
          "user_id",
          json.string(
            json.to_string(
              json.object([
                #("device_id", json.string(device)),
                #("account_uuid", json.string(account)),
                #("session_id", json.string(session)),
              ]),
            ),
          ),
        ),
      ]),
    ),
    #(
      "context_management",
      json.object([
        #(
          "edits",
          json.preprocessed_array([
            json.object([
              #("type", json.string("clear_thinking_20251015")),
              #("keep", json.string("all")),
            ]),
          ]),
        ),
      ]),
    ),
    #(
      "system",
      json.array(system_blocks(request, first_user), fn(block) { block }),
    ),
  ]
  let fields = case request.tools {
    [] -> fields
    tools -> [
      #(
        "tools",
        json.array(
          mark_last(tools, fn(tool, last) { tool_block(tool, last) }),
          fn(block) { block },
        ),
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
      // Newer models omit thinking text unless asked for a summary.
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
    _ -> fields
  }
  let betas =
    list.flatten([
      [
        "claude-code-20250219", "oauth-2025-04-20",
        "interleaved-thinking-2025-05-14", "thinking-token-count-2026-05-13",
        "context-management-2025-06-27", "prompt-caching-scope-2026-01-05",
      ],
      case request.model {
        "claude-haiku-4-5" -> []
        "claude-sonnet-5" -> ["mid-conversation-system-2026-04-07"]
        "claude-opus-5-5" | "claude-fable-5-1" -> [
          "mid-conversation-system-2026-04-07",
          "per-turn-control-2026-07-01",
          "mid-conversation-tool-changes-2026-07-01",
        ]
        _ -> [
          "mid-conversation-system-2026-04-07",
          "mid-conversation-tool-changes-2026-07-01",
        ]
      },
      case request.options.effort {
        Some(_) if request.model != "claude-haiku-4-5" -> ["effort-2025-11-24"]
        _ -> []
      },
      ["extended-cache-ttl-2025-04-11"],
    ])
  case request.model == "" || request.max_output_tokens == Some(0) {
    True ->
      Error(types.InvalidRequest("invalid Claude model or output token limit"))
    False ->
      Ok(openai_api.Exchange(
        "https://api.anthropic.com/v1/messages",
        [
          #("authorization", "Bearer " <> access),
          #("anthropic-version", "2023-06-01"),
          #("anthropic-beta", string.join(betas, ",")),
          #(
            "user-agent",
            "claude-cli/" <> claude_code_version <> " (external, cli)",
          ),
          #("x-app", "cli"),
          #("x-stainless-lang", "js"),
          #("x-stainless-runtime", "node"),
          #("x-stainless-package-version", "0.112.1"),
          #("x-stainless-retry-count", "0"),
          #("x-stainless-timeout", "600"),
          #("x-stainless-arch", "arm64"),
          #("x-stainless-os", "MacOS"),
          #("x-stainless-runtime-version", "v26.3.0"),
          #("x-claude-code-session-id", session),
          #("anthropic-dangerous-direct-browser-access", "true"),
          #("content-type", "application/json"),
          #("accept", "application/json"),
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
  files: Files,
  last: Bool,
) -> Result(History, types.Error) {
  case input {
    types.User(text) -> Ok(push(history, "user", [text_block(text, last)]))
    types.Assistant(text) ->
      Ok(push(history, "assistant", [text_block(text, last)]))
    types.UserImage(text, image) -> {
      // An empty text carries no block: compaction frames follow the archive
      // prompt as bare images in one user message.
      let blocks = case text {
        "" -> [image_block(files, image, last)]
        _ -> [text_block(text, False), image_block(files, image, last)]
      }
      Ok(push(history, "user", blocks))
    }
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
            text_block(text, False),
            ..list.map(images, image_block(files, _, False))
          ])
      }
      Ok(
        push(history, "user", [
          json.object([
            #("type", json.string("tool_result")),
            #("tool_use_id", json.string(id)),
            #("content", content),
            ..case last {
              True -> [tail_cache()]
              False -> []
            }
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
    text -> [text_block(text, False)]
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

fn system_blocks(request: types.Request, first_user: String) -> List(Json) {
  let identity = "You are Claude Code, Anthropic's official CLI for Claude."
  [
    billing_block(claude_code_version, first_user),
    ..case request.instructions {
      Some(text) -> [text_block(identity, False), cached_text_block(text)]
      None -> [cached_text_block(identity)]
    }
  ]
}

fn cached_text_block(text: String) -> Json {
  json.object([
    #("type", json.string("text")),
    #("text", json.string(text)),
    head_cache(),
  ])
}

fn text_block(text: String, cache: Bool) -> Json {
  json.object([
    #("type", json.string("text")),
    #("text", json.string(text)),
    ..case cache {
      True -> [tail_cache()]
      False -> []
    }
  ])
}

fn tool_block(tool: types.Tool, last: Bool) -> Json {
  json.object([
    #("name", json.string(claude_name(tool.name))),
    #("description", json.string(tool.description)),
    #("input_schema", normalize_schema(tool.parameters)),
    ..case last {
      True -> [head_cache()]
      False -> []
    }
  ])
}

fn image_block(files: Files, image: types.Image, cache: Bool) -> Json {
  let #(mime, _, _, _) = types.image_meta(image)
  json.object([
    #("type", json.string("image")),
    #(
      "source",
      case file_source(files.home, files.account, types.image_data(image)) {
        Ok(source) -> source
        Error(Nil) ->
          json.object([
            #("type", json.string("base64")),
            #("media_type", json.string(mime)),
            #("data", base64_string(types.image_data(image))),
          ])
      },
    ),
    ..case cache {
      True -> [tail_cache()]
      False -> []
    }
  ])
}

// 1-hour TTL for stable head (tools, system); tail uses default 5m.
fn head_cache() -> #(String, Json) {
  #(
    "cache_control",
    json.object([
      #("type", json.string("ephemeral")),
      #("ttl", json.string("1h")),
    ]),
  )
}

/// Maps a list, telling the mapper when it is holding the final item.
fn mark_last(items: List(a), mapper: fn(a, Bool) -> b) -> List(b) {
  case items {
    [] -> []
    [last] -> [mapper(last, True)]
    [first, ..rest] -> [mapper(first, False), ..mark_last(rest, mapper)]
  }
}

fn tail_cache() -> #(String, Json) {
  #("cache_control", json.object([#("type", json.string("ephemeral"))]))
}

/// Albedo MCP tool names need Claude Code's MCP namespace on OAuth requests.
/// Stable aliases keep historical tool references valid across turns.
pub fn claude_name(name: String) -> String {
  case string.starts_with(name, "mcp_") {
    True -> {
      let digest =
        <<name:utf8>>
        |> crypto.hash(Sha256, _)
        |> bit_array.base16_encode
        |> string.lowercase
        |> string.slice(0, 16)
      "mcp__albedo__" <> string.slice(name, 4, 24) <> "_" <> digest
    }
    False -> canonical_name(name)
  }
}

fn canonical_name(name: String) -> String {
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

@external(erlang, "albedo_claude_billing", "billing_block")
fn billing_block(version: String, first_user: String) -> Json

@external(erlang, "albedo_claude_schema", "normalize")
pub fn normalize_schema(schema: Json) -> Json

@external(erlang, "albedo_claude_files", "file_source")
fn file_source(
  home: String,
  account: String,
  data: types.ImageData,
) -> Result(Json, Nil)

@external(erlang, "albedo_openai_json", "base64_string")
fn base64_string(data: types.ImageData) -> Json

@external(erlang, "albedo_antigravity", "encode")
pub fn encode_value(value: Dynamic) -> Json
