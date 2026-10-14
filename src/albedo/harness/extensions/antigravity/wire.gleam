//// Albedo requests as Cloud Code Assist `streamGenerateContent` envelopes.

import albedo/clock

import albedo/harness/extensions/antigravity/catalog.{type Model}
import albedo/harness/extensions/antigravity/schema
import albedo/openai_api
import albedo/openai_api/replay
import albedo/openai_api/types.{
  type Error, type Input, type Request, Assistant, InvalidRequest, Replay,
  ToolOutput, User, UserImage,
}
import gleam/bool
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

const path = "/v1internal:streamGenerateContent?alt=sse"

/// Where an albedo turn's exact Gemini parts ride inside its chat-shaped replay.
pub const parts_detail = "antigravity.parts"

/// Google's documented placeholder for a function call whose signature was
/// produced elsewhere; Gemini 3 rejects unsigned calls in the current turn.
const foreign_signature = "skip_thought_signature_validator"

pub type Context {
  Context(
    token: String,
    project: String,
    session: String,
    model: Model,
    user_agent: String,
  )
}

type Content {
  Content(role: String, parts: List(Json))
}

type History {
  History(contents: List(Content), calls: Dict(String, String))
}

/// Which earlier turns replay their exact parts (thoughts, signatures),
/// rather than only their text and calls.
pub type Replay {
  /// Turns of any effort tier of this model: an effort switch keeps the
  /// history byte for byte, so the cached prefix survives it.
  AcrossEfforts
  /// Only turns of this exact variant, for a request whose cross-tier
  /// signatures the provider refused.
  ExactVariant
}

pub fn encode(
  context: Context,
  request: Request,
) -> Result(openai_api.Exchange, Error) {
  encode_with(context, request, [], AcrossEfforts)
}

/// Whether `request` replays exact parts from another effort tier of the
/// context's model, which `ExactVariant` would send portably instead.
pub fn crosses_efforts(context: Context, request: Request) -> Bool {
  list.any(request.input, fn(input) {
    case input {
      Replay(item) ->
        case types.inspect_item(item, message_decoder()) {
          Ok(Message(parts: Some(#(from, _)), ..)) ->
            from != context.model.id && replayable(from, context.model)
          _ -> False
        }
      _ -> False
    }
  })
}

/// The variant that wrote the newest replayed turn of `model`'s base model.
/// Cloud Code caches each variant apart, so a session stays on the one that
/// holds its prefix.
pub fn last_variant(model: Model, request: Request) -> Option(String) {
  list.reverse(request.input)
  |> list.find_map(fn(input) {
    case input {
      Replay(item) ->
        case types.inspect_item(item, message_decoder()) {
          Ok(Message(parts: Some(#(from, _)), ..)) ->
            case catalog.base_id(from) == catalog.base_id(model.id) {
              True -> Ok(from)
              False -> Error(Nil)
            }
          _ -> Error(Nil)
        }
      _ -> Error(Nil)
    }
  })
  |> option.from_result
}

/// Whether a 400 body is Gemini refusing a thought signature.
pub fn signature_refusal(body: String) -> Bool {
  string.contains(string.lowercase(body), "signature")
}

/// `encode`, with `hosted` tools, such as Google Search grounding, after the
/// request's own function declarations.
pub fn encode_with(
  context: Context,
  request: Request,
  hosted: List(Json),
  replay: Replay,
) -> Result(openai_api.Exchange, Error) {
  let model = context.model
  use history <- result.try(
    list.try_fold(request.input, History([], dict.new()), fn(h, i) {
      add(h, i, model, replay)
    }),
  )
  let history = case request.tools, forced(model, request.options.tool_choice) {
    [_, ..], Some(directive) -> push(history, "user", [text_part(directive)])
    _, _ -> history
  }
  let contents =
    history.contents
    |> list.reverse
    |> list.map(fn(content) {
      json.object([
        #("role", json.string(content.role)),
        #("parts", json.preprocessed_array(content.parts)),
      ])
    })
  let fields =
    [
      #("contents", json.preprocessed_array(contents)),
      #(
        "generationConfig",
        generation(model, request.max_output_tokens, request.options),
      ),
      #("labels", labels(context, request.input)),
      #("sessionId", json.string(session_number(context.session))),
    ]
    |> optional("systemInstruction", request.instructions, fn(text) {
      json.object([
        #("role", json.string("user")),
        #("parts", json.preprocessed_array([text_part(text)])),
      ])
    })
  let declared = case request.tools {
    [] -> []
    tools -> [
      json.object([
        #(
          "functionDeclarations",
          json.array(tools, fn(tool) {
            json.object([
              #("name", json.string(tool.name)),
              #("description", json.string(tool.description)),
              #("parameters", schema.normalize(tool.parameters)),
            ])
          }),
        ),
      ]),
    ]
  }
  let fields = case list.append(declared, hosted) {
    [] -> fields
    tools -> [#("tools", json.preprocessed_array(tools)), ..fields]
  }
  let fields = case request.tools, catalog.family(model) {
    [], catalog.Gemini -> fields
    _, _ -> [
      #("toolConfig", tool_config(model, request.options.tool_choice)),
      ..fields
    ]
  }
  let envelope =
    json.object([
      #("project", json.string(context.project)),
      #("requestId", json.string(request_id(context, request.input))),
      #("request", json.object(fields)),
      #("model", json.string(model.id)),
      #("userAgent", json.string("antigravity")),
      #("requestType", json.string("agent")),
    ])
  let headers = [
    #("authorization", "Bearer " <> context.token),
    #("content-type", "application/json"),
    #("accept", "text/event-stream"),
    #("user-agent", context.user_agent),
  ]
  let headers = case catalog.family(model) {
    catalog.Claude -> [
      #("anthropic-beta", "interleaved-thinking-2025-05-14"),
      ..headers
    ]
    catalog.Gemini | catalog.GptOss -> headers
  }
  Ok(openai_api.Exchange(
    catalog.endpoint <> path,
    headers,
    json.to_string_tree(envelope),
    // Gemini streams no thought parts for some models (argon), so a long
    // think is a silent socket: before the first event and between chunks
    // alike. Five minutes each, as oh-my-pi allows Cloud Code Assist; argon
    // has been seen to think silently past two.
    timeout_ms: 300_000,
    first_event_timeout_ms: Some(300_000),
    max_event_bytes: 8 * 1024 * 1024,
    require_event_stream: True,
  ))
}

fn add(
  history: History,
  input: Input,
  model: Model,
  replay: Replay,
) -> Result(History, Error) {
  case input {
    User(text) -> Ok(push(history, "user", [text_part(text)]))
    UserImage(text, images) -> {
      // An empty text carries no part: compaction frames follow the archive
      // prompt as bare images in one user content, and Claude routes reject
      // the empty text part Cloud Code Assist translates for them.
      let images = list.map(images, inline)
      let parts = case text {
        "" -> images
        _ -> [text_part(text), ..images]
      }
      Ok(push(history, "user", parts))
    }
    Assistant(text) -> Ok(push(history, "model", [text_part(text)]))
    ToolOutput(id, output, images) -> {
      use name <- result.try(
        dict.get(history.calls, id)
        |> result.replace_error(InvalidRequest(
          "tool output " <> id <> " has no preceding call",
        )),
      )
      let text = case output, images {
        "", [_, ..] -> "(see attached image)"
        _, _ -> output
      }
      let nested = images != [] && catalog.images_in_tool_results(model)
      let response =
        [
          #("name", json.string(name)),
          #("response", json.object([#("output", json.string(text))])),
        ]
        |> when(catalog.correlates_calls(model), #("id", json.string(id)))
        |> when(nested, #("parts", json.array(images, inline)))
      let history =
        push(history, "user", [
          json.object([#("functionResponse", json.object(response))]),
        ])
      Ok(case images, nested {
        [], _ | _, True -> history
        _, False ->
          push(history, "user", [
            text_part("Tool result image:"),
            ..list.map(images, inline)
          ])
      })
    }
    Replay(item) -> {
      use <- bool.guard(
        types.replay_protocol(item) == types.Responses,
        Error(InvalidRequest("cannot replay output across protocols")),
      )
      use message <- result.try(
        types.inspect_item(item, message_decoder())
        |> result.replace_error(InvalidRequest(
          "replayed assistant message is not portable",
        )),
      )
      let calls =
        list.fold(message.calls, history.calls, fn(calls, call) {
          dict.insert(calls, call.id, call.name)
        })
      let exact = case message.parts, replay {
        Some(#(from, _)), ExactVariant -> from == model.id
        Some(#(from, _)), AcrossEfforts -> replayable(from, model)
        None, _ -> False
      }
      let parts = case message.parts, exact {
        Some(#(_, parts)), True -> list.map(parts, encode_value)
        _, _ -> portable_parts(message, model)
      }
      Ok(push(History(..history, calls: calls), "model", parts))
    }
  }
}

/// Output from `from` replays exactly to `model` when both are effort tiers
/// of one model. oh-my-pi keys replay on the collapsed id the same way.
fn replayable(from: String, model: Model) -> Bool {
  from == model.id || catalog.base_id(from) == catalog.base_id(model.id)
}

type Message {
  Message(
    text: String,
    calls: List(types.ToolCall),
    parts: Option(#(String, List(Dynamic))),
  )
}

fn message_decoder() -> decode.Decoder(Message) {
  let detail = {
    use kind <- decode.field("type", decode.string)
    use model <- decode.optional_field("model", "", decode.string)
    use parts <- decode.optional_field("parts", [], decode.list(decode.dynamic))
    decode.success(case kind == parts_detail && parts != [] {
      True -> Some(#(model, parts))
      False -> None
    })
  }
  use message <- decode.then(replay.message_decoder(detail))
  decode.success(Message(
    message.text,
    message.calls,
    list.first(message.details) |> option.from_result,
  ))
}

/// Output from another model keeps its text and calls. Its thoughts and
/// signatures cannot be verified here, so they are dropped.
fn portable_parts(message: Message, model: Model) -> List(Json) {
  let text = case message.text {
    "" -> []
    text -> [text_part(text)]
  }
  let calls =
    list.map(message.calls, fn(call) {
      let function =
        [#("name", json.string(call.name)), #("args", arguments(call))]
        |> when(catalog.correlates_calls(model), #("id", json.string(call.id)))
      [#("functionCall", json.object(function))]
      |> when(catalog.family(model) == catalog.Gemini, #(
        "thoughtSignature",
        json.string(foreign_signature),
      ))
      |> json.object
    })
  list.append(text, calls)
}

fn arguments(call: types.ToolCall) -> Json {
  case json.parse(call.arguments, decode.dict(decode.string, decode.dynamic)) {
    Ok(_) ->
      json.parse(call.arguments, decode.dynamic)
      |> result.map(encode_value)
      |> result.unwrap(json.object([]))
    Error(_) -> json.object([])
  }
}

/// Adjacent turns of one role merge: Claude routes reject repeated roles, and
/// Gemini expects a run of tool results in one turn.
fn push(history: History, role: String, parts: List(Json)) -> History {
  case parts, history.contents {
    [], _ -> history
    _, [Content(last, previous), ..rest] if last == role ->
      History(..history, contents: [
        Content(role, list.append(previous, parts)),
        ..rest
      ])
    _, contents ->
      History(..history, contents: [Content(role, parts), ..contents])
  }
}

fn text_part(text: String) -> Json {
  json.object([#("text", json.string(text))])
}

fn inline(image: types.Image) -> Json {
  let #(mime_type, _, _, _) = types.image_meta(image)
  json.object([
    #(
      "inlineData",
      json.object([
        #("mimeType", json.string(mime_type)),
        #("data", types.base64_string(types.image_data(image))),
      ]),
    ),
  ])
}

fn generation(
  model: Model,
  requested: Option(Int),
  options: types.Options,
) -> Json {
  let limit = model.max_output_tokens
  // Without a requested effort the variant resolved to its default tier, so
  // the thinking setting follows the tier its id names.
  let effort =
    options.effort
    |> option.lazy_or(fn() { catalog.variant_effort(model) })
    |> option.unwrap("high")
  let #(output, thinking) = case model.thinking {
    catalog.Budget(low, medium, high) -> {
      let budget = case effort {
        "minimal" | "extra-low" | "low" -> low
        "medium" -> medium
        _ -> high
      }
      let output = case requested {
        Some(n) -> int.min(n + budget, limit)
        None -> limit
      }
      let budget = case output <= budget {
        True -> int.max(0, output - 1024)
        False -> budget
      }
      #(output, #("thinkingBudget", json.int(budget)))
    }
    catalog.Level -> #(
      option.unwrap(requested, limit),
      #(
        "thinkingLevel",
        json.string(case effort {
          "minimal" | "extra-low" | "low" -> "LOW"
          "medium" -> "MEDIUM"
          _ -> "HIGH"
        }),
      ),
    )
  }
  let output = case model.pinned_output {
    True -> limit
    False -> output
  }
  [
    #("maxOutputTokens", json.int(output)),
    #(
      "thinkingConfig",
      json.object([#("includeThoughts", json.bool(True)), thinking]),
    ),
  ]
  |> optional("temperature", options.temperature, json.float)
  |> optional("topP", options.top_p, json.float)
  |> optional(
    "stopSequences",
    case options.stop {
      [] -> None
      stop -> Some(stop)
    },
    json.array(_, json.string),
  )
  |> list.append(case options.format {
    None -> []
    Some(types.JsonObject) -> [
      #("responseMimeType", json.string("application/json")),
    ]
    Some(types.JsonSchema(_, schema, _)) -> [
      #("responseMimeType", json.string("application/json")),
      #("responseSchema", schema.normalize(schema)),
    ]
  })
  |> json.object
}

/// Claude routes always run tools VALIDATED. Gemini routes take the mode,
/// but Cloud Code Assist drops it there, so `forced` restates a forced
/// choice in the transcript.
fn tool_config(model: Model, choice: Option(types.ToolChoice)) -> Json {
  let #(mode, names) = case catalog.family(model), choice {
    catalog.Claude, _ | _, None -> #("VALIDATED", [])
    _, Some(types.AutoTool) -> #("AUTO", [])
    _, Some(types.NoTool) -> #("NONE", [])
    _, Some(types.AnyTool) -> #("ANY", [])
    _, Some(types.NamedTool(name)) -> #("ANY", [name])
  }
  json.object([
    #(
      "functionCallingConfig",
      json.object(
        [#("mode", json.string(mode))]
        |> when(names != [], #(
          "allowedFunctionNames",
          json.array(names, json.string),
        )),
      ),
    ),
  ])
}

fn forced(model: Model, choice: Option(types.ToolChoice)) -> Option(String) {
  case catalog.family(model), choice {
    catalog.Gemini, Some(types.AnyTool) -> Some(forced_directive)
    catalog.Gemini, Some(types.NamedTool(name)) ->
      Some(forced_directive <> "Call " <> name <> ".\n")
    _, _ -> None
  }
}

const forced_directive =
  "TOOL-ONLY TURN. This turn accepts a tool call and nothing else; a text reply here is discarded unread and you will be re-prompted. Emit the tool call now.\n"

/// The antigravity/hub client numbers each agent step within a trajectory.
/// Deriving it from history keeps it stable across daemon restarts.
fn step(input: List(Input)) -> Int {
  2
  + list.count(input, fn(input) {
    case input {
      Assistant(_) | Replay(_) -> True
      _ -> False
    }
  })
}

fn trajectory(context: Context) -> String {
  uuid(context.session <> ":trajectory")
}

fn labels(context: Context, input: List(Input)) -> Json {
  let claude = case catalog.family(context.model) {
    catalog.Claude -> "true"
    catalog.Gemini | catalog.GptOss -> "false"
  }
  [
    #("last_step_index", json.string(int.to_string(step(input) - 1))),
    #("trajectory_id", json.string(trajectory(context))),
    #("used_claude", json.string(claude)),
    #("used_claude_conservative", json.string(claude)),
  ]
  |> optional("model_enum", context.model.model_enum, json.string)
  |> json.object
}

fn request_id(context: Context, input: List(Input)) -> String {
  "agent/"
  <> uuid(context.session <> ":agent")
  <> "/"
  <> int.to_string(clock.system_ms())
  <> "/"
  <> trajectory(context)
  <> "/"
  <> int.to_string(step(input))
}

fn when(
  fields: List(#(String, Json)),
  condition: Bool,
  field: #(String, Json),
) -> List(#(String, Json)) {
  case condition {
    True -> [field, ..fields]
    False -> fields
  }
}

fn optional(
  fields: List(#(String, Json)),
  key: String,
  value: Option(a),
  encode: fn(a) -> Json,
) -> List(#(String, Json)) {
  case value {
    Some(value) -> [#(key, encode(value)), ..fields]
    None -> fields
  }
}

@external(erlang, "albedo_antigravity", "encode")
pub fn encode_value(value: Dynamic) -> Json

@external(erlang, "albedo_antigravity", "session_number")
fn session_number(seed: String) -> String

@external(erlang, "albedo_antigravity", "uuid")
fn uuid(seed: String) -> String
