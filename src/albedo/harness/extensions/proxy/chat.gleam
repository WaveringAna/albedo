//// OpenAI Chat Completions as seen from the client side of the proxy:
//// requests become albedo's request types, and turns and stream events
//// become completion objects and chunks.

import albedo/daemon/events
import albedo/daemon/image
import albedo/openai_api/types
import gleam/dynamic/decode
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub type Completion {
  Completion(
    /// The requested model id, echoed back in every response.
    requested: String,
    profile: String,
    /// Empty when the client names only a profile: its saved model is used.
    model: String,
    request: types.Request,
    stream: Bool,
    include_usage: Bool,
    /// Stable across one conversation's requests; seeds upstream identity.
    conversation: String,
  )
}

type Part {
  Text(String)
  ImageUrl(String)
}

type Message {
  Message(
    role: String,
    parts: List(Part),
    calls: List(types.ToolCall),
    call_id: String,
  )
}

pub fn parse(body: BitArray) -> Result(Completion, String) {
  use #(requested, messages, tools, stream, include_usage, limit, options) <- result.try(
    json.parse_bits(body, request_decoder())
    |> result.map_error(fn(error) {
      "invalid chat completion request: " <> string.inspect(error)
    }),
  )
  let #(profile, model) = case string.split_once(requested, "/") {
    Ok(#(profile, model)) -> #(profile, model)
    Error(_) -> #(requested, "")
  }
  use #(instructions, input) <- result.try(inputs(messages))
  Ok(Completion(
    requested,
    profile,
    model,
    types.Request(model, instructions, input, tools, limit, options),
    stream,
    include_usage,
    profile <> "\n" <> first_user_text(messages),
  ))
}

fn request_decoder() {
  let tool = {
    use kind <- decode.optional_field("type", "function", decode.string)
    use name <- decode.subfield(["function", "name"], decode.string)
    use description <- decode.then(decode.optionally_at(
      ["function", "description"],
      "",
      decode.string,
    ))
    use parameters <- decode.then(decode.optionally_at(
      ["function", "parameters"],
      json.object([
        #("type", json.string("object")),
        #("properties", json.object([])),
      ]),
      decode.dynamic |> decode.map(encode),
    ))
    use strict <- decode.then(decode.optionally_at(
      ["function", "strict"],
      False,
      decode.bool,
    ))
    case kind {
      "function" ->
        decode.success(types.Tool(name, description, parameters, strict))
      _ ->
        decode.failure(
          types.Tool(name, description, parameters, strict),
          "function tool",
        )
    }
  }
  use model <- decode.field("model", decode.string)
  use messages <- decode.field("messages", decode.list(message_decoder()))
  use tools <- decode.optional_field("tools", [], decode.list(tool))
  use stream <- decode.optional_field("stream", False, decode.bool)
  use include_usage <- decode.then(decode.optionally_at(
    ["stream_options", "include_usage"],
    False,
    decode.bool,
  ))
  use completion <- decode.optional_field(
    "max_completion_tokens",
    None,
    decode.optional(decode.int),
  )
  use tokens <- decode.optional_field(
    "max_tokens",
    None,
    decode.optional(decode.int),
  )
  use options <- decode.then(options_decoder())
  decode.success(#(
    model,
    messages,
    tools,
    stream,
    include_usage,
    option.or(completion, tokens),
    options,
  ))
}

fn maybe(
  name: String,
  decoder: decode.Decoder(a),
) -> decode.Decoder(Option(a)) {
  decode.optional_field(name, None, decode.optional(decoder), decode.success)
}

fn options_decoder() -> decode.Decoder(types.Options) {
  let number =
    decode.one_of(decode.float, [decode.int |> decode.map(int.to_float)])
  let choice =
    decode.one_of(
      decode.string
        |> decode.then(fn(choice) {
          case choice {
            "auto" -> decode.success(types.AutoTool)
            "none" -> decode.success(types.NoTool)
            "required" | "any" -> decode.success(types.AnyTool)
            other ->
              decode.failure(types.AutoTool, "tool choice, got " <> other)
          }
        }),
      [
        decode.at(["function", "name"], decode.string)
        |> decode.map(types.NamedTool),
      ],
    )
  let format = {
    use kind <- decode.field("type", decode.string)
    case kind {
      "json_object" -> decode.success(Some(types.JsonObject))
      "json_schema" -> {
        use name <- decode.subfield(["json_schema", "name"], decode.string)
        use schema <- decode.subfield(
          ["json_schema", "schema"],
          decode.dynamic |> decode.map(encode),
        )
        use strict <- decode.then(decode.optionally_at(
          ["json_schema", "strict"],
          False,
          decode.bool,
        ))
        decode.success(Some(types.JsonSchema(name, schema, strict)))
      }
      _ -> decode.success(None)
    }
  }
  use temperature <- decode.then(maybe("temperature", number))
  use top_p <- decode.then(maybe("top_p", number))
  use stop <- decode.optional_field(
    "stop",
    [],
    decode.one_of(decode.list(decode.string), [
      decode.string |> decode.map(fn(stop) { [stop] }),
      decode.success([]),
    ]),
  )
  use tool_choice <- decode.then(maybe("tool_choice", choice))
  use parallel <- decode.then(maybe("parallel_tool_calls", decode.bool))
  use effort <- decode.then(maybe("reasoning_effort", decode.string))
  use nested_effort <- decode.then(decode.optionally_at(
    ["reasoning", "effort"],
    None,
    decode.optional(decode.string),
  ))
  use format <- decode.optional_field(
    "response_format",
    None,
    decode.optional(format) |> decode.map(option.flatten),
  )
  decode.success(types.Options(
    temperature,
    top_p,
    stop,
    tool_choice,
    parallel,
    option.or(effort, nested_effort),
    format,
  ))
}

fn message_decoder() -> decode.Decoder(Message) {
  let part = {
    use kind <- decode.field("type", decode.string)
    case kind {
      "text" | "input_text" ->
        decode.field("text", decode.string, fn(text) {
          decode.success(Text(text))
        })
      "image_url" -> {
        use url <- decode.field(
          "image_url",
          decode.one_of(decode.at(["url"], decode.string), [decode.string]),
        )
        decode.success(ImageUrl(url))
      }
      other -> decode.failure(Text(""), "text or image_url part, got " <> other)
    }
  }
  let content =
    decode.one_of(decode.string |> decode.map(fn(text) { [Text(text)] }), [
      decode.list(part),
      decode.optional(decode.string) |> decode.map(fn(_) { [] }),
    ])
  let call = {
    use id <- decode.field("id", decode.string)
    use name <- decode.subfield(["function", "name"], decode.string)
    use arguments <- decode.subfield(["function", "arguments"], decode.string)
    decode.success(types.ToolCall(id, name, arguments))
  }
  use role <- decode.field("role", decode.string)
  use parts <- decode.optional_field("content", [], content)
  use calls <- decode.optional_field(
    "tool_calls",
    [],
    decode.optional(decode.list(call)) |> decode.map(option.unwrap(_, [])),
  )
  use call_id <- decode.optional_field("tool_call_id", "", decode.string)
  decode.success(Message(role, parts, calls, call_id))
}

/// Leading system and developer messages are the instructions. A later one
/// stays where the client put it, as a note the model reads in order.
fn inputs(
  messages: List(Message),
) -> Result(#(Option(String), List(types.Input)), String) {
  let #(leading, rest) =
    list.split_while(messages, fn(message) { system(message.role) })
  let instructions = case list.map(leading, fn(m) { text(m.parts) }) {
    [] -> None
    texts -> Some(string.join(texts, "\n\n"))
  }
  use input <- result.map(list.try_map(rest, input) |> result.map(list.flatten))
  #(instructions, input)
}

fn system(role: String) -> Bool {
  role == "system" || role == "developer"
}

fn input(message: Message) -> Result(List(types.Input), String) {
  let Message(role, parts, calls, call_id) = message
  case role {
    "user" -> user(parts)
    "system" | "developer" ->
      Ok([types.User("<system>\n" <> text(parts) <> "\n</system>")])
    "tool" -> Ok([types.ToolOutput(call_id, text(parts), [])])
    "assistant" ->
      case calls {
        [] -> Ok([types.Assistant(text(parts))])
        calls ->
          assistant(text(parts), calls) |> result.map(fn(item) { [item] })
      }
    other -> Error("unsupported message role " <> other)
  }
}

fn user(parts: List(Part)) -> Result(List(types.Input), String) {
  use images <- result.map(
    list.filter_map(parts, fn(part) {
      case part {
        ImageUrl(url) -> Ok(url)
        Text(_) -> Error(Nil)
      }
    })
    |> list.try_map(data_image),
  )
  case images {
    [] -> [types.User(text(parts))]
    [first, ..more] -> [
      types.UserImage(text(parts), first),
      ..list.map(more, types.UserImage("", _))
    ]
  }
}

/// Only inline images: the proxy never fetches a url on a client's behalf.
fn data_image(url: String) -> Result(types.Image, String) {
  case string.split_once(url, ";base64,") {
    Ok(#("data:" <> _, data)) -> image.from_base64(data)
    _ -> Error("images must be base64 data urls")
  }
}

fn assistant(
  content: String,
  calls: List(types.ToolCall),
) -> Result(types.Input, String) {
  json.object([
    #("role", json.string("assistant")),
    #("content", case content {
      "" -> json.null()
      text -> json.string(text)
    }),
    #(
      "tool_calls",
      json.array(calls, fn(call) {
        json.object([
          #("id", json.string(call.id)),
          #("type", json.string("function")),
          #(
            "function",
            json.object([
              #("name", json.string(call.name)),
              #("arguments", json.string(call.arguments)),
            ]),
          ),
        ])
      }),
    ),
  ])
  |> json.to_string
  |> json.parse(types.replay_decoder(types.ChatCompletions))
  |> result.map(types.Replay)
  |> result.replace_error("invalid assistant tool calls")
}

fn text(parts: List(Part)) -> String {
  parts
  |> list.filter_map(fn(part) {
    case part {
      Text(text) -> Ok(text)
      ImageUrl(_) -> Error(Nil)
    }
  })
  |> string.join("\n")
}

fn first_user_text(messages: List(Message)) -> String {
  messages
  |> list.find(fn(message) { message.role == "user" })
  |> result.map(fn(message) { text(message.parts) })
  |> result.unwrap("")
}

// ---- responses -----------------------------------------------------------

pub type Reply {
  Reply(id: String, created: Int, model: String)
}

pub fn completion(reply: Reply, turn: types.Turn) -> Json {
  let content = string.concat(list.map(turn.output, events.output_text))
  let thinking = string.concat(list.map(turn.output, events.thinking_text))
  let message =
    [
      #("role", json.string("assistant")),
      #("content", case content {
        "" -> json.null()
        text -> json.string(text)
      }),
    ]
    |> when(thinking != "", #("reasoning_content", json.string(thinking)))
    |> when(turn.tool_calls != [], #(
      "tool_calls",
      json.array(turn.tool_calls, call_json(None, _)),
    ))
  json.object(
    [
      #("id", json.string(reply.id)),
      #("object", json.string("chat.completion")),
      #("created", json.int(reply.created)),
      #("model", json.string(reply.model)),
      #(
        "choices",
        json.preprocessed_array([
          json.object([
            #("index", json.int(0)),
            #("message", json.object(message)),
            #("finish_reason", json.string(finish(turn.finish))),
          ]),
        ]),
      ),
    ]
    |> when(turn.usage != None, #("usage", usage(turn.usage))),
  )
}

/// The chunk announcing the assistant's turn.
pub fn opening(reply: Reply) -> Json {
  chunk(
    reply,
    [#("role", json.string("assistant")), #("content", json.string(""))],
    None,
  )
}

/// Text and thinking stream as they arrive; argument fragments do not,
/// because each call is sent whole with its id and name when the turn ends.
pub fn delta(reply: Reply, event: types.Event) -> Option(Json) {
  case event {
    types.TextDelta(_, _, text) ->
      Some(chunk(reply, [#("content", json.string(text))], None))
    types.ThinkingDelta(text) ->
      Some(chunk(reply, [#("reasoning_content", json.string(text))], None))
    types.ArgumentsDelta(..) | types.Started(_) -> None
  }
}

/// The chunks that settle a streamed turn, ending with usage when asked.
pub fn closing(
  reply: Reply,
  turn: types.Turn,
  include_usage: Bool,
) -> List(Json) {
  let calls = case turn.tool_calls {
    [] -> []
    calls -> [
      chunk(
        reply,
        [
          #(
            "tool_calls",
            json.preprocessed_array(
              list.index_map(calls, fn(call, index) {
                call_json(Some(index), call)
              }),
            ),
          ),
        ],
        None,
      ),
    ]
  }
  let usage = case include_usage {
    False -> []
    True -> [
      json.object([
        #("id", json.string(reply.id)),
        #("object", json.string("chat.completion.chunk")),
        #("created", json.int(reply.created)),
        #("model", json.string(reply.model)),
        #("choices", json.preprocessed_array([])),
        #("usage", usage(turn.usage)),
      ]),
    ]
  }
  list.flatten([calls, [chunk(reply, [], Some(finish(turn.finish)))], usage])
}

pub fn error(message: String) -> Json {
  json.object([
    #(
      "error",
      json.object([
        #("message", json.string(message)),
        #("type", json.string("albedo_proxy_error")),
      ]),
    ),
  ])
}

fn chunk(
  reply: Reply,
  delta: List(#(String, Json)),
  finish: Option(String),
) -> Json {
  json.object([
    #("id", json.string(reply.id)),
    #("object", json.string("chat.completion.chunk")),
    #("created", json.int(reply.created)),
    #("model", json.string(reply.model)),
    #(
      "choices",
      json.preprocessed_array([
        json.object([
          #("index", json.int(0)),
          #("delta", json.object(delta)),
          #("finish_reason", json.nullable(finish, json.string)),
        ]),
      ]),
    ),
  ])
}

fn call_json(index: Option(Int), call: types.ToolCall) -> Json {
  [
    #("id", json.string(call.id)),
    #("type", json.string("function")),
    #(
      "function",
      json.object([
        #("name", json.string(call.name)),
        #("arguments", json.string(call.arguments)),
      ]),
    ),
  ]
  |> fn(fields) {
    case index {
      Some(index) -> [#("index", json.int(index)), ..fields]
      None -> fields
    }
  }
  |> json.object
}

fn finish(finish: types.Finish) -> String {
  case finish {
    types.Complete | types.OtherFinish(_) -> "stop"
    types.ToolCalls -> "tool_calls"
    types.LengthLimit -> "length"
    types.ContentFiltered -> "content_filter"
  }
}

fn usage(usage: Option(types.Usage)) -> Json {
  let types.Usage(input, output, cached) =
    option.unwrap(usage, types.Usage(0, 0, None))
  json.object([
    #("prompt_tokens", json.int(input)),
    #("completion_tokens", json.int(output)),
    #("total_tokens", json.int(input + output)),
    #(
      "prompt_tokens_details",
      json.object([#("cached_tokens", json.int(option.unwrap(cached, 0)))]),
    ),
  ])
}

fn when(
  fields: List(#(String, Json)),
  condition: Bool,
  field: #(String, Json),
) -> List(#(String, Json)) {
  case condition {
    True -> list.append(fields, [field])
    False -> fields
  }
}

pub fn id(seed: Int) -> String {
  "chatcmpl-" <> int.to_base36(seed)
}

@external(erlang, "albedo_proxy", "encode")
fn encode(value: decode.Dynamic) -> Json
