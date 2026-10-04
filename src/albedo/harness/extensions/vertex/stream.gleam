//// Vertex Gemini SSE chunks reduced to albedo events and a plain
//// chat-shaped replay message: text, thinking text, and tool calls only.

import albedo/openai_api/decoding
import albedo/openai_api/replay
import albedo/openai_api/stream as reducer
import albedo/openai_api/types
import gleam/dynamic
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
  use error <- result.try(
    decode.run(
      value,
      object({
        use error <- decode.optional_field(
          "error",
          None,
          present(
            object({
              use message <- decode.optional_field("message", "", decode.string)
              use status <- decode.optional_field("status", "", decode.string)
              decode.success(case message, status {
                "", "" -> "unknown Vertex stream error"
                "", status -> status
                message, _ -> message
              })
            }),
          ),
        )
        decode.success(error)
      }),
    )
    |> result.map_error(fn(_) {
      types.InvalidEvent("invalid Vertex stream error")
    }),
  )
  case error {
    Some(message) -> Error(types.ProviderError(message))
    None -> {
      use chunk <- result.try(
        decode.run(value, chunk_decoder())
        |> result.map_error(fn(_) {
          types.InvalidEvent("invalid Vertex stream chunk")
        }),
      )
      apply(state, chunk)
    }
  }
}

fn apply(
  state: State,
  chunk: Chunk,
) -> Result(#(State, List(types.Event)), types.Error) {
  case chunk.blocked {
    Some(reason) ->
      Error(types.ProviderError("request blocked by Google (" <> reason <> ")"))
    None -> {
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
  case state.finish {
    // Even a nonempty body can be truncated midway through a function call.
    None -> Error(types.UnexpectedEnd)
    Some(reason) -> {
      let finish = case reason {
        "STOP" ->
          case calls(state.blocks) {
            [] -> types.Complete
            _ -> types.ToolCalls
          }
        "MAX_TOKENS" -> types.LengthLimit
        "SAFETY"
        | "RECITATION"
        | "PROHIBITED_CONTENT"
        | "BLOCKLIST"
        | "SPII"
        | "IMAGE_SAFETY" -> types.ContentFiltered
        other -> types.OtherFinish(other)
      }
      // The loop executes any nonempty tool_calls regardless of finish.
      // Never publish calls from a limited, filtered or failed completion.
      let calls = case finish {
        types.ToolCalls -> calls(state.blocks)
        _ -> []
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

// Validate object containers too: optional fields alone would accept a
// scalar/null container as if every field were absent.
fn object(decoder: decode.Decoder(a)) -> decode.Decoder(a) {
  use _ <- decode.then(decode.dict(decode.string, decode.dynamic))
  decoder
}

fn present(decoder: decode.Decoder(a)) -> decode.Decoder(Option(a)) {
  use value <- decode.then(decoder)
  decode.success(Some(value))
}

fn chunk_decoder() -> decode.Decoder(Chunk) {
  let candidate =
    object({
      use parts <- decode.optional_field(
        "content",
        [],
        object({
          use parts <- decode.optional_field(
            "parts",
            [],
            decode.list(part_decoder()),
          )
          decode.success(parts)
        }),
      )
      use finish <- decode.optional_field(
        "finishReason",
        None,
        present(decode.string),
      )
      decode.success(#(parts, finish))
    })
  object({
    use candidates <- decode.optional_field(
      "candidates",
      [],
      decode.list(candidate),
    )
    use usage <- decode.optional_field(
      "usageMetadata",
      None,
      present(usage_decoder()),
    )
    use blocked <- decode.optional_field(
      "promptFeedback",
      None,
      object({
        use reason <- decode.optional_field(
          "blockReason",
          None,
          present(decode.string),
        )
        decode.success(reason)
      }),
    )
    let #(parts, finish) = case candidates {
      [first, ..] -> first
      [] -> #([], None)
    }
    decode.success(Chunk(parts, finish, usage, blocked))
  })
}

fn part_decoder() -> decode.Decoder(Part) {
  object({
    use text <- decode.optional_field("text", "", decode.string)
    use thought <- decode.optional_field("thought", False, decode.bool)
    use call <- decode.optional_field(
      "functionCall",
      None,
      present(
        object({
          use name <- decode.field("name", decode.string)
          use args <- decode.optional_field("args", dynamic.properties([]), {
            use _ <- decode.then(decode.dict(decode.string, decode.dynamic))
            decode.dynamic
          })
          decode.success(#(name, json.to_string(types.encode_value(args))))
        }),
      ),
    )
    decode.success(Part(text, thought, call))
  })
}

fn usage_decoder() -> decode.Decoder(types.Usage) {
  object({
    use prompt <- decode.optional_field("promptTokenCount", 0, decode.int)
    use candidates <- decode.optional_field(
      "candidatesTokenCount",
      0,
      decode.int,
    )
    use cached <- decode.optional_field(
      "cachedContentTokenCount",
      None,
      present(decode.int),
    )
    use thoughts <- decode.optional_field(
      "thoughtsTokenCount",
      None,
      present(decode.int),
    )
    decode.success(types.Usage(
      prompt,
      candidates + option.unwrap(thoughts, 0),
      cached,
      None,
      None,
      None,
      thoughts,
    ))
  })
}
