//// Vertex Gemini SSE chunks reduced to albedo events and a plain
//// chat-shaped replay message: text, thinking text, and tool calls only.

import albedo/openai_api/decoding
import albedo/openai_api/replay
import albedo/openai_api/stream as reducer
import albedo/openai_api/types
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

type Block {
  Thought(text: List(String))
  Text(text: List(String))
  Call(call: types.ToolCall)
}

type State {
  State(blocks: List(Block), usage: Option(types.Usage), finish: Option(String))
}

type Chunk {
  Chunk(
    parts: List(Part),
    finish: Option(String),
    usage: Option(types.Usage),
    blocked: Option(String),
  )
}

type Part {
  Part(text: String, thought: Bool, call: Option(#(String, String)))
}

pub fn reducer() -> reducer.Reducer {
  reducer.wrap(State([], None, None), step, finish)
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
      types.InvalidEvent("invalid Vertex JSON: " <> decoding.json_error(error))
    }),
  )
  case decode.run(value, decode.at(["error", "message"], decode.string)) {
    Ok(message) -> Error(types.ProviderError(message))
    Error(_) -> apply(state, parse_chunk(value))
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
      let #(blocks, events) =
        list.fold(chunk.parts, #(state.blocks, []), fn(acc, part) {
          let #(blocks, new) = add(acc.0, part)
          #(blocks, list.append(acc.1, new))
        })
      Ok(#(
        State(
          blocks,
          option.or(chunk.usage, state.usage),
          option.or(chunk.finish, state.finish),
        ),
        events,
      ))
    }
  }
}

fn add(blocks: List(Block), part: Part) -> #(List(Block), List(types.Event)) {
  case part {
    Part(call: Some(#(name, arguments)), ..) -> {
      let index = list.length(calls(blocks))
      let id = "call_" <> int.to_string(index)
      #([Call(types.ToolCall(id, name, arguments)), ..blocks], [
        types.ArgumentsDelta(index, name, arguments),
      ])
    }
    Part(text: "", ..) -> #(blocks, [])
    Part(text: text, thought: True, ..) ->
      case blocks {
        [Thought(previous), ..rest] -> #([Thought([text, ..previous]), ..rest], [
          types.ThinkingDelta(text),
        ])
        _ -> #([Thought([text]), ..blocks], [types.ThinkingDelta(text)])
      }
    Part(text: text, ..) ->
      case blocks {
        [Text(previous), ..rest] -> #([Text([text, ..previous]), ..rest], [
          types.TextDelta(0, 0, text),
        ])
        _ -> #([Text([text]), ..blocks], [types.TextDelta(0, 0, text)])
      }
  }
}

fn calls(blocks: List(Block)) -> List(types.ToolCall) {
  blocks
  |> list.filter_map(fn(block) {
    case block {
      Call(call) -> Ok(call)
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
      let joined = fn(pick) { blocks |> list.filter_map(pick) |> string.concat }
      let text =
        joined(fn(block) {
          case block {
            Text(chunks) -> Ok(flat(chunks))
            _ -> Error(Nil)
          }
        })
      let thinking =
        joined(fn(block) {
          case block {
            Thought(chunks) -> Ok(flat(chunks))
            _ -> Error(Nil)
          }
        })
      use item <- result.map(
        json.parse(
          json.to_string(message(text, thinking, calls)),
          types.replay_decoder(types.ChatCompletions),
        )
        |> result.map_error(fn(error) {
          types.InvalidEvent(
            "could not build the Vertex replay message: "
            <> decoding.json_error(error),
          )
        }),
      )
      let call_indices =
        list.index_map(calls, fn(call, index) { #(call.id, index) })
      types.Turn(None, [item], calls, state.usage, finish, None, call_indices)
    }
  }
}

fn message(
  text: String,
  thinking: String,
  calls: List(types.ToolCall),
) -> json.Json {
  let content = case text {
    "" -> json.null()
    text -> json.string(text)
  }
  replay.message(content, thinking, None, calls)
}

fn flat(chunks: List(String)) -> String {
  chunks |> list.reverse |> string.concat
}

fn parse_chunk(value: Dynamic) -> Chunk {
  let candidate =
    decode.run(value, decode.at(["candidates"], decode.list(decode.dynamic)))
    |> result.unwrap([])
    |> list.first
    |> option.from_result
  let parts = case candidate {
    Some(c) ->
      decode.run(
        c,
        decode.at(["content", "parts"], decode.list(part_decoder())),
      )
      |> result.unwrap([])
    None -> []
  }
  let finish = case candidate {
    Some(c) ->
      decode.run(c, decode.at(["finishReason"], decode.string))
      |> option.from_result
    None -> None
  }
  let blocked =
    decode.run(
      value,
      decode.at(["promptFeedback", "blockReason"], decode.string),
    )
    |> option.from_result
  let usage =
    decode.run(value, decode.at(["usageMetadata"], usage_decoder()))
    |> option.from_result
  Chunk(parts, finish, usage, blocked)
}

fn part_decoder() -> decode.Decoder(Part) {
  use value <- decode.then(decode.dynamic)
  let text =
    decode.run(value, decode.at(["text"], decode.string)) |> result.unwrap("")
  let thought =
    decode.run(value, decode.at(["thought"], decode.bool))
    |> result.unwrap(False)
  let call =
    decode.run(value, decode.at(["functionCall", "name"], decode.string))
    |> option.from_result
    |> option.map(fn(name) {
      let args =
        decode.run(value, decode.at(["functionCall", "args"], decode.dynamic))
        |> result.map(types.encode_value)
        |> result.map(json.to_string)
        |> result.unwrap("{}")
      #(name, args)
    })
  decode.success(Part(text, thought, call))
}

fn usage_decoder() -> decode.Decoder(types.Usage) {
  use prompt <- decode.optional_field("promptTokenCount", 0, decode.int)
  use candidates <- decode.optional_field("candidatesTokenCount", 0, decode.int)
  use cached <- decode.optional_field(
    "cachedContentTokenCount",
    None,
    decode.optional(decode.int),
  )
  use thoughts <- decode.optional_field(
    "thoughtsTokenCount",
    None,
    decode.optional(decode.int),
  )
  decode.success(types.Usage(
    prompt,
    candidates,
    cached,
    None,
    None,
    None,
    thoughts,
  ))
}
