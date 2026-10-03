//// Anthropic Messages SSE into albedo events and chat-shaped portable replay.

import albedo/harness/extensions/claude/wire
import albedo/openai_api/decoding
import albedo/openai_api/replay
import albedo/openai_api/stream.{type Reducer}
import albedo/openai_api/types
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

type Block {
  Text(index: Int, chunks: List(String))
  Thinking(index: Int, chunks: List(String), signature: Option(String))
  Tool(index: Int, id: String, name: String, chunks: List(String))
}

type State {
  State(
    model: String,
    tools: List(types.Tool),
    id: Option(String),
    blocks: List(Block),
    usage: Option(types.Usage),
    reason: Option(String),
    detail: Option(String),
  )
}

pub fn reducer(model: String, tools: List(types.Tool)) -> Reducer {
  stream.wrap(State(model, tools, None, [], None, None, None), step, fn(_) {
    Error(types.UnexpectedEnd)
  })
}

fn step(
  state: State,
  data: String,
) -> Result(#(State, List(types.Event), Option(types.Turn)), types.Error) {
  use value <- result.try(
    json.parse(data, decode.dynamic)
    |> result.map_error(fn(error) {
      types.InvalidEvent(
        "invalid Anthropic event JSON: " <> decoding.json_error(error),
      )
    }),
  )
  use kind <- result.try(
    decode.run(value, decode.at(["type"], decode.string))
    |> result.map_error(fn(error) {
      types.InvalidEvent(
        "Anthropic event has no type: " <> decoding.decode_errors(error),
      )
    }),
  )
  apply(state, kind, value)
}

fn apply(
  state: State,
  kind: String,
  value: Dynamic,
) -> Result(#(State, List(types.Event), Option(types.Turn)), types.Error) {
  case kind {
    "error" ->
      Error(types.ProviderError(
        decode.run(value, decode.at(["error", "message"], decode.string))
        |> result.unwrap("Anthropic stream error"),
      ))
    "message_start" -> {
      use id <- result.try(
        decode.run(value, decode.at(["message", "id"], decode.string))
        |> result.map_error(fn(error) {
          types.InvalidEvent(
            "invalid message_start: " <> decoding.decode_errors(error),
          )
        }),
      )
      let usage =
        decode.run(value, decode.at(["message", "usage"], usage_decoder()))
        |> option.from_result
      emit(State(..state, id: Some(id), usage: usage), [types.Started(id)])
    }
    "content_block_start" -> start(state, value)
    "content_block_delta" -> delta(state, value)
    "message_delta" -> {
      let reason =
        decode.run(
          value,
          decode.at(["delta", "stop_reason"], decode.optional(decode.string)),
        )
        |> result.unwrap(None)
      let detail = refusal_detail(value)
      let output =
        decode.run(value, decode.at(["usage", "output_tokens"], decode.int))
        |> option.from_result
      let usage = case state.usage, output {
        Some(old), Some(n) -> Some(types.Usage(..old, output_tokens: n))
        None, Some(n) -> Some(types.Usage(0, n, None, None, None, None, None))
        _, None -> state.usage
      }
      emit(
        State(
          ..state,
          usage: usage,
          reason: option.or(reason, state.reason),
          detail: option.or(detail, state.detail),
        ),
        [],
      )
    }
    "message_stop" -> {
      use turn <- result.try(finish(state))
      Ok(#(state, [], Some(turn)))
    }
    _ -> emit(state, [])
  }
}

fn start(
  state: State,
  value: Dynamic,
) -> Result(#(State, List(types.Event), Option(types.Turn)), types.Error) {
  use index <- result.try(
    decode.run(value, decode.at(["index"], decode.int))
    |> result.map_error(fn(error) {
      types.InvalidEvent(
        "missing block index: " <> decoding.decode_errors(error),
      )
    }),
  )
  use kind <- result.try(
    decode.run(value, decode.at(["content_block", "type"], decode.string))
    |> result.map_error(fn(error) {
      types.InvalidEvent(
        "missing block type: " <> decoding.decode_errors(error),
      )
    }),
  )
  let block = case kind {
    "text" -> Some(Text(index, [field(value, ["content_block", "text"])]))
    "thinking" ->
      Some(Thinking(index, [field(value, ["content_block", "thinking"])], None))
    "tool_use" -> {
      let id = field(value, ["content_block", "id"])
      let name = field(value, ["content_block", "name"])
      Some(Tool(index, id, original_name(name, state.tools), []))
    }
    _ -> None
  }
  case block {
    Some(block) -> emit(State(..state, blocks: [block, ..state.blocks]), [])
    None -> emit(state, [])
  }
}

fn delta(
  state: State,
  value: Dynamic,
) -> Result(#(State, List(types.Event), Option(types.Turn)), types.Error) {
  use index <- result.try(
    decode.run(value, decode.at(["index"], decode.int))
    |> result.map_error(fn(error) {
      types.InvalidEvent(
        "missing delta index: " <> decoding.decode_errors(error),
      )
    }),
  )
  use kind <- result.try(
    decode.run(value, decode.at(["delta", "type"], decode.string))
    |> result.map_error(fn(error) {
      types.InvalidEvent(
        "missing delta type: " <> decoding.decode_errors(error),
      )
    }),
  )
  let text = case kind {
    "input_json_delta" -> field(value, ["delta", "partial_json"])
    "signature_delta" -> field(value, ["delta", "signature"])
    "thinking_delta" -> field(value, ["delta", "thinking"])
    _ -> field(value, ["delta", "text"])
  }
  let #(blocks, events) = update(state.blocks, index, kind, text)
  emit(State(..state, blocks: blocks), events)
}

fn update(
  blocks: List(Block),
  index: Int,
  kind: String,
  text: String,
) -> #(List(Block), List(types.Event)) {
  case blocks {
    [Text(i, chunks), ..rest] if i == index && kind == "text_delta" -> #(
      [Text(i, [text, ..chunks]), ..rest],
      [types.TextDelta(i, 0, text)],
    )
    [Thinking(i, chunks, signature), ..rest]
      if i == index && kind == "thinking_delta"
    -> #([Thinking(i, [text, ..chunks], signature), ..rest], [
      types.ThinkingDelta(text),
    ])
    [Thinking(i, chunks, _), ..rest]
      if i == index && kind == "signature_delta"
    -> #([Thinking(i, chunks, Some(text)), ..rest], [])
    [Tool(i, id, name, chunks), ..rest]
      if i == index && kind == "input_json_delta"
    -> #([Tool(i, id, name, [text, ..chunks]), ..rest], [
      types.ArgumentsDelta(i, name, text),
    ])
    [head, ..rest] -> {
      let #(rest, events) = update(rest, index, kind, text)
      #([head, ..rest], events)
    }
    [] -> #([], [])
  }
}

fn finish(state: State) -> Result(types.Turn, types.Error) {
  let blocks = list.reverse(state.blocks)
  let calls =
    list.filter_map(blocks, fn(block) {
      case block {
        Tool(_, id, name, chunks) ->
          Ok(types.ToolCall(id, name, arguments(chunks)))
        _ -> Error(Nil)
      }
    })
  use _ <- result.try(
    list.try_each(calls, fn(call) {
      json.parse(call.arguments, decode.dict(decode.string, decode.dynamic))
      |> result.map(fn(_) { Nil })
      |> result.map_error(fn(error) {
        types.InvalidEvent(
          "invalid Claude tool input: " <> decoding.json_error(error),
        )
      })
    }),
  )
  let native = list.filter_map(blocks, native_block)
  let joined = fn(pick) { blocks |> list.filter_map(pick) |> string.concat }
  let text =
    joined(fn(block) {
      case block {
        Text(_, chunks) -> Ok(flat(chunks))
        _ -> Error(Nil)
      }
    })
  let thinking =
    joined(fn(block) {
      case block {
        Thinking(_, chunks, _) -> Ok(flat(chunks))
        _ -> Error(Nil)
      }
    })
  // The transcript reads thinking back from reasoning_content; replay to
  // Claude uses the signed blocks instead.
  let details = case native {
    [] -> None
    native ->
      Some(
        json.preprocessed_array([
          json.object([
            #("type", json.string(wire.blocks_detail)),
            #("model", json.string(state.model)),
            #("blocks", json.preprocessed_array(native)),
          ]),
        ]),
      )
  }
  use item <- result.try(
    json.parse(
      json.to_string(replay.message(json.string(text), thinking, details, calls)),
      types.replay_decoder(types.ChatCompletions),
    )
    |> result.map_error(fn(error) {
      types.InvalidEvent(
        "invalid Claude replay: " <> decoding.json_error(error),
      )
    }),
  )
  let finish = case state.reason {
    Some("tool_use") -> types.ToolCalls
    Some("max_tokens") -> types.LengthLimit
    Some("refusal") -> types.OtherFinish(option.unwrap(state.detail, "refusal"))
    Some("end_turn") | Some("stop_sequence") | None ->
      case calls {
        [] -> types.Complete
        _ -> types.ToolCalls
      }
    Some(other) -> types.OtherFinish(other)
  }
  let call_indices =
    list.filter_map(blocks, fn(block) {
      case block {
        Tool(index, id, _, _) -> Ok(#(id, index))
        _ -> Error(Nil)
      }
    })
  Ok(types.Turn(
    state.id,
    [item],
    calls,
    state.usage,
    finish,
    None,
    call_indices,
  ))
}

fn native_block(block: Block) -> Result(Json, Nil) {
  case block {
    Text(_, chunks) ->
      Ok(
        json.object([
          #("type", json.string("text")),
          #("text", json.string(flat(chunks))),
        ]),
      )
    Thinking(_, chunks, Some(signature)) ->
      Ok(
        json.object([
          #("type", json.string("thinking")),
          #("thinking", json.string(flat(chunks))),
          #("signature", json.string(signature)),
        ]),
      )
    Thinking(_, _, None) -> Error(Nil)
    Tool(_, id, name, chunks) ->
      Ok(wire.tool_use_block(id, name, arguments(chunks)))
  }
}

fn usage_decoder() -> decode.Decoder(types.Usage) {
  use input <- decode.optional_field("input_tokens", 0, decode.int)
  use output <- decode.optional_field("output_tokens", 0, decode.int)
  use cache <- decode.optional_field(
    "cache_read_input_tokens",
    None,
    decode.optional(decode.int),
  )
  use creation <- decode.optional_field(
    "cache_creation_input_tokens",
    None,
    decode.optional(decode.int),
  )
  // The same writes split by how long the entry lives.
  use writes <- decode.optional_field(
    "cache_creation",
    None,
    decode.optional(cache_creation_decoder()),
  )
  // Anthropic reports input_tokens without cached reads or writes; the
  // harness counts the whole input context so cached is a subset of input.
  decode.success(types.Usage(
    input + option.unwrap(cache, 0) + option.unwrap(creation, 0),
    output,
    cache,
    creation,
    option.then(writes, fn(split) { split.write_5m }),
    option.then(writes, fn(split) { split.write_1h }),
    None,
  ))
}

type CacheWrites {
  CacheWrites(write_5m: Option(Int), write_1h: Option(Int))
}

fn cache_creation_decoder() -> decode.Decoder(CacheWrites) {
  use write_5m <- decode.optional_field(
    "ephemeral_5m_input_tokens",
    None,
    decode.optional(decode.int),
  )
  use write_1h <- decode.optional_field(
    "ephemeral_1h_input_tokens",
    None,
    decode.optional(decode.int),
  )
  decode.success(CacheWrites(write_5m, write_1h))
}

fn original_name(name: String, tools: List(types.Tool)) -> String {
  tools
  |> list.find(fn(tool) {
    string.lowercase(wire.claude_name(tool.name)) == string.lowercase(name)
  })
  |> result.map(fn(tool) { tool.name })
  |> result.unwrap(name)
}

fn arguments(chunks: List(String)) -> String {
  case flat(chunks) {
    "" -> "{}"
    value -> value
  }
}

fn flat(chunks: List(String)) -> String {
  chunks |> list.reverse |> string.concat
}

fn refusal_detail(value: Dynamic) -> Option(String) {
  case field(value, ["delta", "stop_details", "type"]) {
    "refusal" -> {
      let category = field(value, ["delta", "stop_details", "category"])
      let explanation =
        string.trim(field(value, ["delta", "stop_details", "explanation"]))
      let label = case category {
        "" -> "refusal"
        category -> "refusal (" <> category <> ")"
      }
      Some(case explanation {
        "" -> label
        explanation -> label <> ": " <> explanation
      })
    }
    _ -> None
  }
}

fn field(value: Dynamic, path: List(String)) -> String {
  decode.run(value, decode.at(path, decode.string)) |> result.unwrap("")
}

fn emit(
  state: State,
  events: List(types.Event),
) -> Result(#(State, List(types.Event), Option(types.Turn)), types.Error) {
  Ok(#(state, events, None))
}
