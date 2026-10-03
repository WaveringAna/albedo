import albedo/openai_api/replay
import albedo/openai_api/types
import gleam/dict.{type Dict}
import gleam/dynamic
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub opaque type State {
  State(
    response_id: Option(String),
    streamed_output: Dict(Int, dynamic.Dynamic),
    terminal: Bool,
    /// Each streaming call's tool name, by output index, from when it was
    /// added; its argument deltas carry only the index.
    call_names: Dict(Int, String),
  )
}

type Envelope {
  Envelope(kind: String, value: dynamic.Dynamic)
}

type Response {
  Response(
    id: Option(String),
    output: List(dynamic.Dynamic),
    usage: Option(types.Usage),
    incomplete_reason: Option(String),
  )
}

pub fn new() -> State {
  State(None, dict.new(), False, dict.new())
}

pub fn feed(
  state: State,
  data: String,
) -> Result(#(State, List(types.Event), Option(types.Turn)), types.Error) {
  let State(terminal:, ..) = state
  case terminal {
    True -> Error(types.InvalidEvent("response event after terminal event"))
    False -> {
      use envelope <- result.try(
        json.parse(data, envelope_decoder())
        |> result.map_error(fn(error) {
          types.InvalidEvent(
            "invalid Responses event: " <> string.inspect(error),
          )
        }),
      )
      dispatch(state, envelope)
    }
  }
}

fn envelope_decoder() -> decode.Decoder(Envelope) {
  use value <- decode.then(decode.dynamic)
  use kind <- decode.field("type", decode.string)
  decode.success(Envelope(kind, value))
}

fn dispatch(
  state: State,
  envelope: Envelope,
) -> Result(#(State, List(types.Event), Option(types.Turn)), types.Error) {
  let Envelope(kind, value) = envelope
  case kind {
    "response.created" -> created(state, value)
    "response.output_text.delta" -> text_delta(state, value)
    "response.reasoning_summary_part.added" -> summary_part_added(state, value)
    "response.reasoning_summary_text.delta" ->
      reasoning_delta(state, value, "response.reasoning_summary_text.delta")
    "response.reasoning_text.delta" ->
      reasoning_delta(state, value, "response.reasoning_text.delta")
    "response.output_item.added" -> output_item_added(state, value)
    "response.function_call_arguments.delta" -> arguments_delta(state, value)
    "response.output_item.done" -> output_item_done(state, value)
    "response.completed" -> completed(state, value)
    "response.incomplete" -> incomplete(state, value)
    "response.failed" -> failed(value)
    "error" -> provider_error(value)
    "response.audio.delta"
    | "response.audio_transcript.delta"
    | "response.custom_tool_call_input.delta" ->
      Error(types.Unsupported("unsupported Responses semantic event: " <> kind))
    _ -> Ok(#(state, [], None))
  }
}

fn created(
  state: State,
  value: dynamic.Dynamic,
) -> Result(#(State, List(types.Event), Option(types.Turn)), types.Error) {
  let decoder =
    decode.at(
      ["response"],
      decode.optional_field(
        "id",
        None,
        decode.optional(decode.string),
        decode.success,
      ),
    )
  use id <- result.try(run(value, decoder, "response.created"))
  use #(state, events) <- result.try(record_id(state, id))
  Ok(#(state, events, None))
}

fn text_delta(
  state: State,
  value: dynamic.Dynamic,
) -> Result(#(State, List(types.Event), Option(types.Turn)), types.Error) {
  let decoder = {
    use output_index <- decode.field("output_index", decode.int)
    use content_index <- decode.field("content_index", decode.int)
    use delta <- decode.field("delta", decode.string)
    decode.success(types.TextDelta(output_index, content_index, delta))
  }
  use event <- result.try(run(value, decoder, "response.output_text.delta"))
  Ok(#(state, [event], None))
}

fn arguments_delta(
  state: State,
  value: dynamic.Dynamic,
) -> Result(#(State, List(types.Event), Option(types.Turn)), types.Error) {
  let decoder = {
    use output_index <- decode.field("output_index", decode.int)
    use delta <- decode.field("delta", decode.string)
    decode.success(#(output_index, delta))
  }
  use #(index, delta) <- result.try(run(
    value,
    decoder,
    "response.function_call_arguments.delta",
  ))
  let name = dict.get(state.call_names, index) |> result.unwrap("")
  Ok(#(state, [types.ArgumentsDelta(index, name, delta)], None))
}

/// A function call's item opens with its name, before any of its arguments.
fn output_item_added(
  state: State,
  value: dynamic.Dynamic,
) -> Result(#(State, List(types.Event), Option(types.Turn)), types.Error) {
  let decoder = {
    use index <- decode.field("output_index", decode.int)
    use #(kind, name) <- decode.field("item", {
      use kind <- decode.field("type", decode.string)
      use name <- decode.optional_field("name", "", decode.string)
      decode.success(#(kind, name))
    })
    decode.success(#(index, kind, name))
  }
  use #(index, kind, name) <- result.try(run(
    value,
    decoder,
    "response.output_item.added",
  ))
  case kind, name {
    "function_call", name if name != "" -> {
      let call_names = dict.insert(state.call_names, index, name)
      Ok(#(State(..state, call_names:), [], None))
    }
    _, _ -> Ok(#(state, [], None))
  }
}

fn output_item_done(
  state: State,
  value: dynamic.Dynamic,
) -> Result(#(State, List(types.Event), Option(types.Turn)), types.Error) {
  let decoder = {
    use index <- decode.field("output_index", decode.int)
    use item <- decode.field("item", decode.dynamic)
    decode.success(#(index, item))
  }
  use #(index, item) <- result.try(run(
    value,
    decoder,
    "response.output_item.done",
  ))
  let streamed_output = dict.insert(state.streamed_output, index, item)
  Ok(#(State(..state, streamed_output: streamed_output), [], None))
}

/// Summary parts arrive as separate paragraphs with no separator in their
/// deltas; every part after the first opens with a paragraph break.
fn summary_part_added(
  state: State,
  value: dynamic.Dynamic,
) -> Result(#(State, List(types.Event), Option(types.Turn)), types.Error) {
  use index <- result.try(run(
    value,
    decode.at(["summary_index"], decode.int),
    "response.reasoning_summary_part.added",
  ))
  case index > 0 {
    True -> Ok(#(state, [types.ThinkingDelta("\n\n")], None))
    False -> Ok(#(state, [], None))
  }
}

fn reasoning_delta(
  state: State,
  value: dynamic.Dynamic,
  context: String,
) -> Result(#(State, List(types.Event), Option(types.Turn)), types.Error) {
  let decoder = {
    use delta <- decode.field("delta", decode.string)
    decode.success(types.ThinkingDelta(delta))
  }
  use event <- result.try(run(value, decoder, context))
  Ok(#(state, [event], None))
}

fn completed(
  state: State,
  value: dynamic.Dynamic,
) -> Result(#(State, List(types.Event), Option(types.Turn)), types.Error) {
  use response <- result.try(run(
    value,
    decode.at(["response"], response_decoder(False)),
    "response.completed",
  ))
  use #(state, started) <- result.try(record_id(state, response.id))
  let authoritative = case response.output {
    [] ->
      state.streamed_output
      |> dict.to_list
      |> list.sort(fn(a, b) { int.compare(a.0, b.0) })
    output -> list.index_map(output, fn(value, index) { #(index, value) })
  }
  use output <- result.try(
    replay_output(list.map(authoritative, fn(entry) { entry.1 })),
  )
  use #(tools, call_indices) <- result.try(function_calls(authoritative))
  let finish = case tools {
    [] -> types.Complete
    _ -> types.ToolCalls
  }
  Ok(#(
    State(..state, terminal: True),
    started,
    Some(types.Turn(
      state.response_id,
      output,
      tools,
      response.usage,
      finish,
      None,
      call_indices,
    )),
  ))
}

fn incomplete(
  state: State,
  value: dynamic.Dynamic,
) -> Result(#(State, List(types.Event), Option(types.Turn)), types.Error) {
  use response <- result.try(run(
    value,
    decode.at(["response"], response_decoder(True)),
    "response.incomplete",
  ))
  use #(state, started) <- result.try(record_id(state, response.id))
  use output <- result.try(replay_output(response.output))
  let finish = case response.incomplete_reason {
    Some("max_output_tokens") -> types.LengthLimit
    Some("content_filter") -> types.ContentFiltered
    Some(reason) -> types.OtherFinish(reason)
    None -> types.OtherFinish("incomplete")
  }
  Ok(#(
    State(..state, terminal: True),
    started,
    Some(
      types.Turn(
        state.response_id,
        output,
        [],
        response.usage,
        finish,
        None,
        [],
      ),
    ),
  ))
}

fn failed(value: dynamic.Dynamic) -> Result(a, types.Error) {
  provider_failure(
    value,
    decode.at(["response", "error", "message"], decode.string),
    "response.failed",
  )
}

fn provider_error(value: dynamic.Dynamic) -> Result(a, types.Error) {
  provider_failure(value, decode.at(["message"], decode.string), "error")
}

fn provider_failure(
  value: dynamic.Dynamic,
  decoder: decode.Decoder(String),
  context: String,
) -> Result(a, types.Error) {
  let message = case decode.run(value, decoder) {
    Ok(message) -> message
    Error(error) -> "malformed " <> context <> ": " <> string.inspect(error)
  }
  Error(types.ProviderError(message))
}

fn response_decoder(incomplete: Bool) -> decode.Decoder(Response) {
  use id <- decode.optional_field("id", None, decode.optional(decode.string))
  use output <- decode.field("output", decode.list(decode.dynamic))
  use usage <- decode.optional_field(
    "usage",
    None,
    decode.optional(types.usage_decoder(
      "input_tokens",
      "output_tokens",
      "input_tokens_details",
      "output_tokens_details",
    )),
  )
  use details <- decode.optional_field(
    "incomplete_details",
    None,
    decode.optional(decode.at(["reason"], decode.string)),
  )
  case incomplete, details {
    True, None ->
      decode.failure(Response(id, output, usage, details), "incomplete_details")
    _, _ -> decode.success(Response(id, output, usage, details))
  }
}

fn run(
  value: dynamic.Dynamic,
  decoder: decode.Decoder(a),
  context: String,
) -> Result(a, types.Error) {
  decode.run(value, decoder)
  |> result.map_error(fn(error) {
    types.InvalidEvent(context <> ": " <> string.inspect(error))
  })
}

fn record_id(
  state: State,
  incoming: Option(String),
) -> Result(#(State, List(types.Event)), types.Error) {
  use #(id, events) <- result.try(types.merge_response_id(
    state.response_id,
    incoming,
    "Responses response id changed",
  ))
  Ok(#(State(..state, response_id: id), events))
}

fn replay_output(
  values: List(dynamic.Dynamic),
) -> Result(List(types.ReplayItem), types.Error) {
  list.try_map(values, run(
    _,
    types.replay_decoder(types.Responses),
    "invalid response output item",
  ))
}

fn function_calls(
  values: List(#(Int, dynamic.Dynamic)),
) -> Result(#(List(types.ToolCall), List(#(String, Int))), types.Error) {
  list.try_fold(values, #([], []), fn(acc, indexed_value) {
    let #(calls, call_indices) = acc
    let #(index, value) = indexed_value
    use kind <- result.try(run(
      value,
      decode.at(["type"], decode.string),
      "response output item",
    ))
    case kind {
      "function_call" -> {
        use call <- result.try(run(
          value,
          replay.function_call_decoder(),
          "function_call output item",
        ))
        Ok(#([call, ..calls], [#(call.id, index), ..call_indices]))
      }
      _ -> Ok(acc)
    }
  })
  |> result.map(fn(acc) { #(list.reverse(acc.0), list.reverse(acc.1)) })
}
