//// Optional request-history projection, not a transcript rewrite.

import albedo/daemon/store
import albedo/harness/extensions/python/kernel
import albedo/openai_api/types
import gleam/json
import gleam/list
import gleam/option.{type Option}
import gleam/string

pub type SummaryRequest {
  SummaryRequest(
    model: String,
    previous: Option(String),
    evicted: List(types.Input),
    max_output_tokens: Int,
  )
}

/// A context window a catalog or configuration actually reported, with the
/// provenance a strategy must show rather than an assumed model limit.
pub type Capacity {
  Capacity(tokens: Int, source: String)
}

pub type Context {
  Context(
    store: store.Store,
    session: String,
    kernel: kernel.Kernel,
    model: String,
    source: String,
    pinned_tokens: Int,
    capacity: Option(Capacity),
    force: Bool,
    summarize: fn(SummaryRequest) -> Result(String, String),
  )
}

/// Receives chronological history before each model request. Implementations
/// own their summaries/state and must preserve valid tool call/result pairs.
/// Failure stops the turn; the full durable transcript is never replaced.
pub type Strategy {
  Strategy(
    name: String,
    prepare: fn(Context, List(types.Input)) -> Result(List(types.Input), String),
  )
}

/// A deliberately approximate request-size estimate. It is used only when a
/// provider has not supplied a tokenizer for the current request.
pub fn estimate_text(text: String) -> Int {
  { string.byte_size(text) + 3 } / 4
}

pub fn input_bytes(input: types.Input) -> Int {
  case input {
    types.User(text) | types.Assistant(text) -> string.byte_size(text)
    types.UserImage(text, image) -> {
      let #(_, data, _, _, _) = types.image_parts(image)
      string.byte_size(text) + string.byte_size(data)
    }
    types.ToolOutput(id, output, images) ->
      string.byte_size(id)
      + string.byte_size(output)
      + list.fold(images, 0, fn(total, image) {
        let #(_, data, _, _, _) = types.image_parts(image)
        total + string.byte_size(data)
      })
    types.Replay(item) ->
      types.replay_json(item) |> json.to_string |> string.byte_size
  }
}

pub fn inputs_bytes(inputs: List(types.Input)) -> Int {
  inputs |> list.fold(0, fn(total, input) { total + input_bytes(input) })
}

pub fn estimate_input(input: types.Input) -> Int {
  // Covers request framing, roles, and content-part keys without pretending
  // to be an exact provider tokenizer. Image payload bytes affect transport
  // size, not vision tokens, so image cost is estimated from dimensions.
  case input {
    types.UserImage(text, image) ->
      estimate_text(text) + estimate_image(image) + 20
    types.ToolOutput(id, output, [_, ..] as images) ->
      estimate_text(id <> output)
      + list.fold(images, 0, fn(total, image) {
        total + estimate_image(image) + 20
      })
      + 12
    _ -> { input_bytes(input) + 3 } / 4 + 12
  }
}

fn estimate_image(image: types.Image) -> Int {
  let #(_, _, width, height, _) = types.image_parts(image)
  // Provider-neutral approximation based on 512px vision tiles. Providers
  // may tokenize images differently; this is only the rolling trigger signal.
  85 + 170 * ceiling_div(width, 512) * ceiling_div(height, 512)
}

fn ceiling_div(value: Int, divisor: Int) -> Int {
  { value + divisor - 1 } / divisor
}

pub fn estimate_inputs(inputs: List(types.Input)) -> Int {
  inputs |> list.fold(0, fn(total, input) { total + estimate_input(input) })
}

pub fn estimate_tools(tools: List(types.Tool)) -> Int {
  tools
  |> list.fold(0, fn(total, tool) {
    total
    + estimate_text(tool.name)
    + estimate_text(tool.description)
    + estimate_text(json.to_string(tool.parameters))
    + 20
  })
}

pub fn estimate_pinned(
  instructions: String,
  context: List(types.Input),
  tools: List(types.Tool),
) -> Int {
  16
  + estimate_text(instructions)
  + estimate_inputs(context)
  + estimate_tools(tools)
}
