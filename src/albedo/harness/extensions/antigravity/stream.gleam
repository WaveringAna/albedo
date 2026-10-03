//// Cloud Code Assist stream chunks reduced to albedo events and one
//// chat-shaped replay message that also carries the exact Gemini parts.

import albedo/harness/extensions/antigravity/catalog.{type Model}
import albedo/harness/extensions/antigravity/wire
import albedo/openai_api/decoding
import albedo/openai_api/replay
import albedo/openai_api/stream as reducer
import albedo/openai_api/types
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

type Block {
  Thought(text: List(String), signature: Option(String))
  Text(text: List(String), signature: Option(String))
  Call(call: types.ToolCall, args: Json, signature: Option(String))
}

type State {
  State(
    model: Model,
    response_id: Option(String),
    /// Newest first; each block's text fragments are newest first too.
    blocks: List(Block),
    usage: Option(types.Usage),
    finish: Option(String),
  )
}

type Chunk {
  Chunk(
    response_id: Option(String),
    parts: List(Part),
    finish: Option(String),
    usage: Option(types.Usage),
    blocked: Option(String),
  )
}

type Part {
  Part(
    text: String,
    thought: Bool,
    signature: Option(String),
    call: Option(#(String, String, Dynamic)),
  )
}

pub fn reducer(model: Model) -> reducer.Reducer {
  reducer.wrap(State(model, None, [], None, None), step, finish)
}

fn step(
  state: State,
  data: String,
) -> Result(#(State, List(types.Event), Option(types.Turn)), types.Error) {
  use #(state, events) <- result.map(feed(state, data))
  #(state, events, None)
}

fn feed(
  state: State,
  data: String,
) -> Result(#(State, List(types.Event)), types.Error) {
  use value <- result.try(
    json.parse(data, decode.dynamic)
    |> result.map_error(fn(error) {
      types.InvalidEvent(
        "invalid Cloud Code Assist JSON: " <> decoding.json_error(error),
      )
    }),
  )
  case decode.run(value, decode.at(["error"], error_decoder())) {
    Ok(message) -> Error(types.ProviderError(message))
    Error(_) ->
      decode.run(value, chunk_decoder())
      |> result.map_error(fn(e) {
        types.InvalidEvent(
          "invalid Cloud Code Assist chunk: " <> string.inspect(e),
        )
      })
      |> result.try(apply(state, _))
  }
}

fn apply(
  state: State,
  chunk: Chunk,
) -> Result(#(State, List(types.Event)), types.Error) {
  case chunk.blocked, chunk.parts {
    Some(reason), [] ->
      Error(types.ProviderError("request blocked by Google (" <> reason <> ")"))
    _, _ -> {
      let #(response_id, started) = case state.response_id, chunk.response_id {
        None, Some(id) -> #(Some(id), [types.Started(id)])
        current, _ -> #(current, [])
      }
      let #(blocks, events) =
        list.fold(chunk.parts, #(state.blocks, []), fn(acc, part) {
          let #(blocks, new) = add(acc.0, part)
          #(blocks, list.append(acc.1, new))
        })
      Ok(#(
        State(
          ..state,
          response_id: response_id,
          blocks: blocks,
          usage: option.or(chunk.usage, state.usage),
          finish: option.or(chunk.finish, state.finish),
        ),
        list.append(started, events),
      ))
    }
  }
}

fn add(blocks: List(Block), part: Part) -> #(List(Block), List(types.Event)) {
  case part {
    Part(call: Some(#(id, name, args)), signature: signature, ..) -> {
      let calls = calls(blocks)
      let id = case id == "" || list.any(calls, fn(call) { call.id == id }) {
        True -> call_id()
        False -> id
      }
      let args = wire.encode_value(args)
      let arguments = json.to_string(args)
      #([Call(types.ToolCall(id, name, arguments), args, signature), ..blocks], [
        types.ArgumentsDelta(list.length(calls), name, arguments),
      ])
    }
    Part(text: "", signature: Some(signature), ..) -> #(
      sign(blocks, signature),
      [],
    )
    Part(text: "", ..) -> #(blocks, [])
    Part(text: text, thought: True, signature: signature, ..) ->
      case blocks {
        [Thought(previous, old), ..rest] -> #(
          [Thought([text, ..previous], option.or(signature, old)), ..rest],
          [types.ThinkingDelta(text)],
        )
        _ -> #([Thought([text], signature), ..blocks], [
          types.ThinkingDelta(text),
        ])
      }
    Part(text: text, signature: signature, ..) ->
      case blocks {
        [Text(previous, old), ..rest] -> #(
          [Text([text, ..previous], option.or(signature, old)), ..rest],
          [types.TextDelta(0, 0, text)],
        )
        _ -> #([Text([text], signature), ..blocks], [
          types.TextDelta(0, 0, text),
        ])
      }
  }
}

/// A terminal signature can arrive on an empty text part after its block.
fn sign(blocks: List(Block), signature: String) -> List(Block) {
  case blocks {
    [Thought(text, _), ..rest] -> [Thought(text, Some(signature)), ..rest]
    [Text(text, _), ..rest] -> [Text(text, Some(signature)), ..rest]
    blocks -> blocks
  }
}

fn calls(blocks: List(Block)) -> List(types.ToolCall) {
  blocks
  |> list.filter_map(fn(block) {
    case block {
      Call(call, _, _) -> Ok(call)
      _ -> Error(Nil)
    }
  })
  |> list.reverse
}

fn finish(state: State) -> Result(types.Turn, types.Error) {
  let blocks = list.reverse(state.blocks)
  let calls = calls(state.blocks)
  case blocks, state.finish {
    // An empty body is a failed attempt the loop may retry, not an answer.
    [], None -> Error(types.UnexpectedEnd)
    _, _ -> {
      let finish = case calls {
        [_, ..] -> types.ToolCalls
        [] ->
          case state.finish {
            None | Some("STOP") -> types.Complete
            Some("MAX_TOKENS") -> types.LengthLimit
            Some("SAFETY")
            | Some("RECITATION")
            | Some("PROHIBITED_CONTENT")
            | Some("BLOCKLIST")
            | Some("SPII")
            | Some("IMAGE_SAFETY") -> types.ContentFiltered
            Some(other) -> types.OtherFinish(other)
          }
      }
      use item <- result.map(
        json.parse(
          json.to_string(message(state.model, blocks, calls)),
          types.replay_decoder(types.ChatCompletions),
        )
        |> result.map_error(fn(error) {
          types.InvalidEvent(
            "could not build the Antigravity replay message: "
            <> decoding.json_error(error),
          )
        }),
      )
      let call_indices =
        calls
        |> list.index_map(fn(call, index) { #(call.id, index) })
      types.Turn(
        state.response_id,
        [item],
        calls,
        state.usage,
        finish,
        None,
        call_indices,
      )
    }
  }
}

fn message(
  model: Model,
  blocks: List(Block),
  calls: List(types.ToolCall),
) -> Json {
  let joined = fn(pick) { blocks |> list.filter_map(pick) |> string.concat }
  let text =
    joined(fn(block) {
      case block {
        Text(text, _) -> Ok(flatten(text))
        _ -> Error(Nil)
      }
    })
  let thinking =
    joined(fn(block) {
      case block {
        Thought(text, _) -> Ok(flatten(text))
        _ -> Error(Nil)
      }
    })
  let details = case list.filter_map(blocks, part(_, model)) {
    [] -> None
    parts ->
      Some(
        json.preprocessed_array([
          json.object([
            #("type", json.string(wire.parts_detail)),
            #("index", json.int(0)),
            #("model", json.string(model.id)),
            #("parts", json.preprocessed_array(parts)),
          ]),
        ]),
      )
  }
  replay.message(
    case text {
      "" -> json.null()
      text -> json.string(text)
    },
    thinking,
    details,
    calls,
  )
}

/// The Gemini part this block replays as, for this same model only.
fn part(block: Block, model: Model) -> Result(Json, Nil) {
  let signed = fn(fields, signature) {
    case signature {
      Some(signature) -> [
        #("thoughtSignature", json.string(signature)),
        ..fields
      ]
      None -> fields
    }
    |> json.object
  }
  case block, catalog.family(model) {
    // Claude routes reject replayed thinking without its signature.
    Thought(_, None), catalog.Claude -> Error(Nil)
    Thought(text, signature), _ ->
      Ok(signed(
        [#("thought", json.bool(True)), #("text", json.string(flatten(text)))],
        signature,
      ))
    Text(text, signature), _ ->
      Ok(signed([#("text", json.string(flatten(text)))], signature))
    Call(call, args, signature), _ -> {
      let function = [#("name", json.string(call.name)), #("args", args)]
      let function = case catalog.correlates_calls(model) {
        True -> [#("id", json.string(call.id)), ..function]
        False -> function
      }
      Ok(signed([#("functionCall", json.object(function))], signature))
    }
  }
}

fn flatten(fragments: List(String)) -> String {
  fragments |> list.reverse |> string.concat
}

fn error_decoder() -> decode.Decoder(String) {
  use message <- decode.optional_field("message", "", decode.string)
  use status <- decode.optional_field("status", "", decode.string)
  decode.success(case message, status {
    "", "" -> "unknown Cloud Code Assist stream error"
    "", status -> status
    message, _ -> message
  })
}

fn chunk_decoder() -> decode.Decoder(Chunk) {
  let part = {
    use text <- decode.optional_field("text", "", decode.string)
    use thought <- decode.optional_field("thought", False, decode.bool)
    use signature <- decode.optional_field(
      "thoughtSignature",
      None,
      decode.optional(decode.string),
    )
    use call <- decode.optional_field(
      "functionCall",
      None,
      decode.optional({
        use id <- decode.optional_field("id", "", decode.string)
        use name <- decode.field("name", decode.string)
        use args <- decode.optional_field(
          "args",
          dynamic.properties([]),
          decode.dynamic,
        )
        decode.success(#(id, name, args))
      }),
    )
    let signature = case signature {
      Some("") -> None
      other -> other
    }
    decode.success(Part(text, thought, signature, call))
  }
  let candidate = {
    use parts <- decode.optional_field(
      "content",
      [],
      decode.optional_field("parts", [], decode.list(part), decode.success),
    )
    use finish <- decode.optional_field(
      "finishReason",
      None,
      decode.optional(decode.string),
    )
    decode.success(#(parts, finish))
  }
  let usage = {
    use input <- decode.optional_field("promptTokenCount", 0, decode.int)
    use output <- decode.optional_field("candidatesTokenCount", 0, decode.int)
    use thoughts <- decode.optional_field("thoughtsTokenCount", 0, decode.int)
    use cached <- decode.optional_field(
      "cachedContentTokenCount",
      None,
      decode.optional(decode.int),
    )
    // Output keeps folding thoughts in; the thought count is also reported
    // as reasoning so usage can tell the two apart.
    decode.success(types.Usage(
      input,
      output + thoughts,
      cached,
      None,
      None,
      None,
      Some(thoughts),
    ))
  }
  let response = {
    use response_id <- decode.optional_field(
      "responseId",
      None,
      decode.optional(decode.string),
    )
    use candidates <- decode.optional_field(
      "candidates",
      [],
      decode.list(candidate),
    )
    use usage <- decode.optional_field(
      "usageMetadata",
      None,
      decode.optional(usage),
    )
    use blocked <- decode.optional_field(
      "promptFeedback",
      None,
      decode.optional_field(
        "blockReason",
        None,
        decode.optional(decode.string),
        decode.success,
      ),
    )
    let #(parts, finish) = case candidates {
      [first, ..] -> first
      [] -> #([], None)
    }
    decode.success(Chunk(response_id, parts, finish, usage, blocked))
  }
  decode.optional_field(
    "response",
    Chunk(None, [], None, None, None),
    response,
    decode.success,
  )
}

@external(erlang, "albedo_antigravity", "call_id")
fn call_id() -> String
