//// Albedo requests into Vertex AI's `generateContent` wire shape — the
//// same request and response body Google documents for the public Gemini
//// API; only the host, path, and OAuth token are Vertex's own. Replay
//// keeps text and tool calls only, each marked with Google's placeholder
//// signature for a call this encoder cannot prove it produced.

import albedo/openai_api
import albedo/openai_api/replay
import albedo/openai_api/types.{
  type Error, type Input, type Request, Assistant, InvalidRequest, Replay,
  ToolOutput, User, UserImage,
}
import gleam/bool
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// Google's documented placeholder for a function call whose signature
/// cannot be verified. Thinking models reject an unsigned call otherwise;
/// every call this encoder replays counts as foreign, signed or not.
const foreign_signature = "skip_thought_signature_validator"

type Content {
  Content(role: String, parts: List(Json))
}

type History {
  History(contents: List(Content), calls: Dict(String, String))
}

pub fn encode(
  token: String,
  project: String,
  location: String,
  request: Request,
) -> Result(openai_api.Exchange, Error) {
  use <- bool.guard(
    !string.contains(string.lowercase(request.model), "gemini"),
    Error(InvalidRequest(
      "this Vertex profile serves Gemini models; configure a gemini* model id",
    )),
  )
  use history <- result.try(
    list.try_fold(request.input, History([], dict.new()), fn(h, i) { add(h, i) }),
  )
  let contents =
    history.contents
    |> list.reverse
    |> list.map(fn(content) {
      json.object([
        #("role", json.string(content.role)),
        #("parts", json.preprocessed_array(content.parts)),
      ])
    })
  use config <- result.try(generation_config(request))
  let fields = [
    #("contents", json.preprocessed_array(contents)),
    #("generationConfig", config),
  ]
  let fields = case request.instructions {
    Some(text) if text != "" -> [
      #(
        "systemInstruction",
        json.object([
          #("role", json.string("user")),
          #("parts", json.preprocessed_array([text_part(text)])),
        ]),
      ),
      ..fields
    ]
    _ -> fields
  }
  let fields = case request.tools {
    [] -> fields
    tools -> [
      #(
        "tools",
        json.preprocessed_array([
          json.object([
            #(
              "functionDeclarations",
              json.array(tools, fn(tool) {
                json.object([
                  #("name", json.string(tool.name)),
                  #("description", json.string(tool.description)),
                  #("parametersJsonSchema", tool.parameters),
                ])
              }),
            ),
          ]),
        ]),
      ),
      #("toolConfig", tool_config(request.options.tool_choice)),
      ..fields
    ]
  }
  let path =
    "/v1/projects/"
    <> project
    <> "/locations/"
    <> location
    <> "/publishers/google/models/"
    <> request.model
    <> ":streamGenerateContent?alt=sse"
  Ok(openai_api.Exchange(
    endpoint(location) <> path,
    [
      #("authorization", "Bearer " <> token),
      #("content-type", "application/json"),
      #("accept", "text/event-stream"),
    ],
    json.to_string_tree(json.object(fields)),
    120_000,
    8 * 1024 * 1024,
    True,
  ))
}

/// The global Vertex endpoint is not a region-prefixed hostname.
pub fn endpoint(location: String) -> String {
  case location {
    "global" -> "https://aiplatform.googleapis.com"
    _ -> "https://" <> location <> "-aiplatform.googleapis.com"
  }
}

fn generation_config(request: Request) -> Result(Json, Error) {
  use thinking <- result.try(thinking_config(
    request.model,
    request.options.effort,
  ))
  let fields = case thinking {
    [] -> []
    fields -> [#("thinkingConfig", json.object(fields))]
  }
  let fields = case request.max_output_tokens {
    Some(n) -> [#("maxOutputTokens", json.int(n)), ..fields]
    None -> fields
  }
  let fields = case request.options.temperature {
    Some(t) -> [#("temperature", json.float(t)), ..fields]
    None -> fields
  }
  let fields = case request.options.top_p {
    Some(p) -> [#("topP", json.float(p)), ..fields]
    None -> fields
  }
  let fields = case request.options.stop {
    [] -> fields
    stops -> [#("stopSequences", json.array(stops, json.string)), ..fields]
  }
  let fields =
    list.append(fields, case request.options.format {
      None -> []
      Some(types.JsonObject) -> [
        #("responseMimeType", json.string("application/json")),
      ]
      Some(types.JsonSchema(_, schema, _)) -> [
        #("responseMimeType", json.string("application/json")),
        #("responseJsonSchema", schema),
      ]
    })
  Ok(json.object(fields))
}

type Thinking {
  Budget(low: Int, medium: Int, high: Int, disable: Bool)
  Levels(efforts: List(String))
}

/// Vertex's documented controls, kept local rather than importing another
/// provider's catalog. Only known families and their version suffixes match.
fn thinking_config(
  model: String,
  effort: Option(String),
) -> Result(List(#(String, Json)), Error) {
  let model = string.lowercase(model)
  let levels = Levels(["minimal", "low", "medium", "high"])
  let pro_levels = Levels(["low", "medium", "high"])
  let flash = Budget(1024, 8192, 24_576, True)
  let policy =
    list.find(
      [
        #("gemini-2.5-pro", Budget(1024, 8192, 32_768, False)),
        #("gemini-2.5-flash-lite", flash),
        #("gemini-2.5-flash", flash),
        #("gemini-3-pro", Levels(["low", "high"])),
        #("gemini-3-flash", levels),
        #("gemini-3.1-pro", pro_levels),
        #("gemini-3.1-flash-lite", levels),
        #("gemini-3.5-flash-lite", levels),
        #("gemini-3.5-flash", levels),
        #("gemini-3.6-flash", levels),
        #("gemini-3.7-flash", pro_levels),
        #("gemini-3.8-flash", pro_levels),
      ],
      fn(entry) {
        model == entry.0
        || model == entry.0 <> "-001"
        || model == entry.0 <> "-preview"
        || string.starts_with(model, entry.0 <> "-preview-")
      },
    )
  let thoughts = [#("includeThoughts", json.bool(True))]
  case effort {
    None ->
      Ok(case policy {
        Ok(_) -> thoughts
        Error(_) -> []
      })
    Some(effort) -> {
      let unsupported =
        InvalidRequest(
          "unsupported Vertex effort " <> effort <> " for " <> model,
        )
      use #(_, thinking) <- result.try(result.replace_error(policy, unsupported))
      let control = case thinking {
        Budget(low, medium, high, disable) -> {
          let budget = case effort {
            "minimal" if disable -> Ok(0)
            "low" -> Ok(low)
            "medium" -> Ok(medium)
            "high" -> Ok(high)
            _ -> Error(unsupported)
          }
          result.map(budget, fn(n) { #("thinkingBudget", json.int(n)) })
        }
        Levels(efforts) ->
          case list.contains(efforts, effort) {
            True ->
              Ok(#("thinkingLevel", json.string(string.uppercase(effort))))
            False -> Error(unsupported)
          }
      }
      use control <- result.map(control)
      [control, ..thoughts]
    }
  }
}

fn tool_config(tool_choice: Option(types.ToolChoice)) -> Json {
  let mode = case tool_choice {
    Some(types.NoTool) -> "NONE"
    Some(types.AnyTool) | Some(types.NamedTool(_)) -> "ANY"
    _ -> "AUTO"
  }
  let fields = [#("mode", json.string(mode))]
  let fields = case tool_choice {
    Some(types.NamedTool(name)) -> [
      #("allowedFunctionNames", json.array([name], json.string)),
      ..fields
    ]
    _ -> fields
  }
  json.object([#("functionCallingConfig", json.object(fields))])
}

fn add(history: History, input: Input) -> Result(History, Error) {
  case input {
    User(text) -> Ok(push(history, "user", [text_part(text)]))
    UserImage(text, images) -> {
      let image_parts = list.map(images, inline_part)
      let parts = case text {
        "" -> image_parts
        _ -> [text_part(text), ..image_parts]
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
      let response =
        json.object([
          #(
            "functionResponse",
            json.object([
              #("name", json.string(name)),
              #("response", json.object([#("output", json.string(text))])),
            ]),
          ),
        ])
      let history = push(history, "user", [response])
      Ok(case images {
        [] -> history
        _ ->
          push(history, "user", [
            text_part("Tool result image:"),
            ..list.map(images, inline_part)
          ])
      })
    }
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
      let calls =
        list.fold(message.calls, history.calls, fn(calls, call) {
          dict.insert(calls, call.id, call.name)
        })
      Ok(push(
        History(..history, calls: calls),
        "model",
        portable_parts(message),
      ))
    }
  }
}

fn detail_decoder() -> decode.Decoder(Option(Nil)) {
  decode.success(None)
}

fn portable_parts(message: replay.Message(Nil)) -> List(Json) {
  let text = case message.text {
    "" -> []
    text -> [text_part(text)]
  }
  let calls =
    list.map(message.calls, fn(call) {
      json.object([
        #(
          "functionCall",
          json.object([
            #("name", json.string(call.name)),
            #("args", arguments(call.arguments)),
          ]),
        ),
        #("thoughtSignature", json.string(foreign_signature)),
      ])
    })
  list.append(text, calls)
}

fn arguments(encoded: String) -> Json {
  json.parse(encoded, decode.dynamic)
  |> result.map(types.encode_value)
  |> result.unwrap(json.object([]))
}

/// Adjacent turns of one role merge: Gemini expects a run of tool results
/// in one turn, and repeated roles are otherwise rejected.
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

fn inline_part(image: types.Image) -> Json {
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
