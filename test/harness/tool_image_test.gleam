//// Kernel image wire decoding and old journal records must survive format
//// changes; synthetic corrupted and legacy records cannot arise in E2E.

import albedo/harness/extensions/python/kernel as python
import albedo/openai_api/types
import gleam/dynamic
import gleam/erlang/atom
import gleam/json
import gleam/list
import gleeunit/should

/// A PNG signature and IHDR header for a 2x3 image: enough for albedo to read.
const png = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAAD"

pub fn the_kernel_decoder_reads_images_at_the_boundary_test() {
  let frame = fn(images) {
    json.object([
      #("id", json.string("cell")),
      #("status", json.string("ok")),
      #("output", json.string("")),
      #("value", json.string("")),
      #("truncated", json.bool(False)),
      ..images
    ])
    |> json.to_string
  }
  // A kernel from before images sends no field at all.
  let assert Ok(plain) = json.parse(frame([]), python.outcome_decoder())
  #(plain.images, plain.image_errors) |> should.equal(#([], []))
  let wide = "iVBORw0KGgoAAAANSUhEUgAAAAUAAAAD"
  let images =
    json.array([png, "bm90IGFuIGltYWdl", wide, "not base64!"], json.string)
  let assert Ok(mixed) =
    json.parse(frame([#("images", images)]), python.outcome_decoder())
  // Both lists keep the order the cell showed its images in.
  mixed.images
  |> list.map(fn(image) {
    let #(_, width, height, _) = types.image_meta(image)
    #(width, height)
  })
  |> should.equal([#(2, 3), #(5, 3)])
  mixed.image_errors
  |> should.equal([
    "image 2: not a PNG, JPEG, or WebP albedo can read",
    "image 4: not a PNG, JPEG, or WebP albedo can read",
  ])
  // A wrong shape is a broken kernel, not an unreadable image.
  let assert Error(_) =
    json.parse(
      frame([#("images", json.array([1], json.int))]),
      python.outcome_decoder(),
    )
}

/// The record shapes albedo stored before tool results carried images.
type LegacyInput {
  ToolOutput(String, String)
}

type LegacyOutcome {
  Outcome(String, python.Status, String, String, Bool)
}

pub fn records_saved_before_images_still_load_test() {
  let assert Ok(input) =
    unpack_input(term_to_binary(#(1, ToolOutput("call", "text"))))
  input |> should.equal(types.ToolOutput("call", "text", []))
  let saved = Outcome("cell", python.Succeeded, "out", "'v'", False)
  let assert Ok(Ok(outcome)) = unpack_cell(term_to_binary(#(1, Ok(saved))))
  outcome
  |> should.equal(
    python.Outcome("cell", python.Succeeded, "out", "'v'", False, [], []),
  )
}

pub fn a_journaled_image_is_checked_again_on_load_test() {
  let assert Ok(Ok(_)) = unpack_cell(journaled_png(2))
  // The payload is 2 pixels wide; a record claiming 9 was altered.
  unpack_cell(journaled_png(9)) |> should.equal(Error(Nil))
}

/// A journaled cell outcome carrying one PNG, built term by term.
fn journaled_png(width: Int) -> BitArray {
  let atom = fn(name) { atom.to_dynamic(atom.create(name)) }
  let image =
    dynamic.array([
      atom("image"),
      dynamic.string("image/png"),
      dynamic.string(png),
      dynamic.int(width),
      dynamic.int(3),
      dynamic.int(24),
    ])
  let outcome =
    dynamic.array([
      atom("outcome"),
      dynamic.string("cell"),
      atom("succeeded"),
      dynamic.string(""),
      dynamic.string(""),
      dynamic.bool(False),
      dynamic.list([image]),
      dynamic.list([]),
    ])
  term_to_binary(#(1, Ok(outcome)))
}

@external(erlang, "erlang", "term_to_binary")
fn term_to_binary(value: a) -> BitArray

fn unpack_input(bytes: BitArray) -> Result(types.Input, Nil) {
  unpack_with(bytes, fn(_) { Error(Nil) })
}

@external(erlang, "albedo_conversation", "unpack")
fn unpack_with(
  bytes: BitArray,
  read: fn(String) -> Result(String, Nil),
) -> Result(types.Input, Nil)

@external(erlang, "albedo_native", "unpack_cell")
fn unpack_cell(
  bytes: BitArray,
) -> Result(Result(python.Outcome, python.Error), Nil)
