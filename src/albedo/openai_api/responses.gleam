import albedo/openai_api/types
import gleam/dynamic
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string

pub opaque type State {
  State(
    response_id: Option(String),
    streamed_output: List(#(Int, dynamic.Dynamic)),
    terminal: Bool,
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
  State(None, [], False)
}

pub fn feed(
  state: State,
  data: String,
) -> Result(#(State, List(types.Event), Option(types.Turn)), types.Error) {
  let State(_, _, terminal) = state
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
  let decoder = {
    use response <- decode.field("response", created_response_decoder())
    decode.success(response)
  }
  use id <- result.try(run(value, decoder, "response.created"))
  merge_id(state, id)
}

fn created_response_decoder() -> decode.Decoder(Option(String)) {
  use id <- decode.optional_field("id", None, decode.optional(decode.string))
  decode.success(id)
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
    decode.success(types.ArgumentsDelta(output_index, delta))
  }
  use event <- result.try(run(
    value,
    decoder,
    "response.function_call_arguments.delta",
  ))
  Ok(#(state, [event], None))
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
  use item <- result.try(run(value, decoder, "response.output_item.done"))
  let State(id, output, terminal) = state
  Ok(#(State(id, put_output(output, item), terminal), [], None))
}

fn put_output(
  output: List(#(Int, dynamic.Dynamic)),
  item: #(Int, dynamic.Dynamic),
) -> List(#(Int, dynamic.Dynamic)) {
  let #(index, _) = item
  case output {
    [] -> [item]
    [first, ..rest] -> {
      let #(first_index, _) = first
      case int.compare(index, first_index) {
        order.Lt -> [item, first, ..rest]
        order.Eq -> [item, ..rest]
        order.Gt -> [first, ..put_output(rest, item)]
      }
    }
  }
}

/// Summary parts arrive as separate paragraphs with no separator in their
/// deltas; every part after the first opens with a paragraph break.
fn summary_part_added(
  state: State,
  value: dynamic.Dynamic,
) -> Result(#(State, List(types.Event), Option(types.Turn)), types.Error) {
  let decoder = decode.field("summary_index", decode.int, decode.success)
  use index <- result.try(run(
    value,
    decoder,
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
    field_decoder("response", response_decoder(False)),
    "response.completed",
  ))
  use #(state, started) <- result.try(record_id(state, response.id))
  let State(_, streamed, _) = state
  let authoritative = case response.output {
    [] -> list.map(streamed, fn(item) { item.1 })
    output -> output
  }
  use output <- result.try(replay_output(authoritative))
  use tools <- result.try(function_calls(authoritative))
  let finish = case tools {
    [] -> types.Complete
    _ -> types.ToolCalls
  }
  let State(id, streamed, _) = state
  Ok(#(
    State(id, streamed, True),
    started,
    Some(types.Turn(id, output, tools, response.usage, finish)),
  ))
}

fn incomplete(
  state: State,
  value: dynamic.Dynamic,
) -> Result(#(State, List(types.Event), Option(types.Turn)), types.Error) {
  use response <- result.try(run(
    value,
    field_decoder("response", response_decoder(True)),
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
  let State(id, streamed, _) = state
  Ok(#(
    State(id, streamed, True),
    started,
    Some(types.Turn(id, output, [], response.usage, finish)),
  ))
}

fn failed(value: dynamic.Dynamic) -> Result(a, types.Error) {
  let decoder =
    subfield_decoder(["response", "error", "message"], decode.string)
  provider_failure(value, decoder, "response.failed")
}

fn provider_error(value: dynamic.Dynamic) -> Result(a, types.Error) {
  provider_failure(value, field_decoder("message", decode.string), "error")
}

fn provider_failure(
  value: dynamic.Dynamic,
  decoder: decode.Decoder(String),
  context: String,
) -> Result(a, types.Error) {
  case decode.run(value, decoder) {
    Ok(message) -> Error(types.ProviderError(message))
    Error(error) ->
      Error(types.ProviderError(
        "malformed " <> context <> ": " <> string.inspect(error),
      ))
  }
}

fn response_decoder(incomplete: Bool) -> decode.Decoder(Response) {
  use id <- decode.optional_field("id", None, decode.optional(decode.string))
  use output <- decode.field("output", decode.list(decode.dynamic))
  use usage <- decode.optional_field(
    "usage",
    None,
    decode.optional(usage_decoder()),
  )
  use details <- decode.optional_field(
    "incomplete_details",
    None,
    decode.optional(incomplete_details_decoder()),
  )
  case incomplete, details {
    True, None ->
      decode.failure(Response(id, output, usage, details), "incomplete_details")
    _, _ -> decode.success(Response(id, output, usage, details))
  }
}

fn usage_decoder() -> decode.Decoder(types.Usage) {
  use input <- decode.field("input_tokens", decode.int)
  use output <- decode.field("output_tokens", decode.int)
  use details <- decode.optional_field(
    "input_tokens_details",
    None,
    decode.optional(cached_tokens_decoder()),
  )
  decode.success(types.Usage(input, output, option.flatten(details), None))
}

fn cached_tokens_decoder() -> decode.Decoder(Option(Int)) {
  use cached <- decode.optional_field(
    "cached_tokens",
    None,
    decode.optional(decode.int),
  )
  decode.success(cached)
}

fn incomplete_details_decoder() -> decode.Decoder(String) {
  field_decoder("reason", decode.string)
}

fn field_decoder(
  name: String,
  decoder: decode.Decoder(a),
) -> decode.Decoder(a) {
  use value <- decode.field(name, decoder)
  decode.success(value)
}

fn subfield_decoder(
  path: List(String),
  decoder: decode.Decoder(a),
) -> decode.Decoder(a) {
  use value <- decode.subfield(path, decoder)
  decode.success(value)
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

fn merge_id(
  state: State,
  incoming: Option(String),
) -> Result(#(State, List(types.Event), Option(types.Turn)), types.Error) {
  use #(state, events) <- result.try(record_id(state, incoming))
  Ok(#(state, events, None))
}

fn record_id(
  state: State,
  incoming: Option(String),
) -> Result(#(State, List(types.Event)), types.Error) {
  let State(current, output, terminal) = state
  case current, incoming {
    None, Some(id) ->
      Ok(#(State(Some(id), output, terminal), [types.Started(id)]))
    Some(current), Some(incoming) if current != incoming ->
      Error(types.InvalidEvent("Responses response id changed"))
    _, _ -> Ok(#(state, []))
  }
}

fn replay_output(
  values: List(dynamic.Dynamic),
) -> Result(List(types.ReplayItem), types.Error) {
  values
  |> list.try_map(fn(value) {
    decode.run(value, types.replay_decoder(types.Responses))
    |> result.map_error(fn(error) {
      types.InvalidEvent(
        "invalid response output item: " <> string.inspect(error),
      )
    })
  })
}

fn function_calls(
  values: List(dynamic.Dynamic),
) -> Result(List(types.ToolCall), types.Error) {
  list.try_fold(values, [], fn(calls, value) {
    use kind <- result.try(run(
      value,
      field_decoder("type", decode.string),
      "response output item",
    ))
    case kind {
      "function_call" -> {
        use call <- result.try(run(
          value,
          function_call_decoder(),
          "function_call output item",
        ))
        Ok([call, ..calls])
      }
      _ -> Ok(calls)
    }
  })
  |> result.map(list.reverse)
}

fn function_call_decoder() -> decode.Decoder(types.ToolCall) {
  use id <- decode.field("call_id", decode.string)
  use name <- decode.field("name", decode.string)
  use arguments <- decode.field("arguments", decode.string)
  use status <- decode.optional_field("status", "completed", decode.string)
  case id != "" && name != "" && status == "completed" {
    True -> decode.success(types.ToolCall(id, name, arguments))
    False ->
      decode.failure(
        types.ToolCall(id, name, arguments),
        "completed function call with identity",
      )
  }
}
