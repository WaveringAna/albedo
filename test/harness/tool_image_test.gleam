//// Images a cell returns reach the model beside its tool result.

import albedo/harness/extensions/python/kernel as python
import albedo/harness/loop
import albedo/harness/runtime
import albedo/openai_api/types
import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/json
import gleam/list
import gleam/string
import gleeunit/should

/// A PNG signature and IHDR header for a 2x3 image: enough for albedo to read.
const png = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAAD"

fn call(id: String, code: String) -> types.ToolCall {
  let arguments =
    json.object([
      #("code", json.string(code)),
      #("timeout_ms", json.int(5000)),
    ])
    |> json.to_string
  types.ToolCall(id, "python", arguments)
}

fn field(output: String, name: String) -> String {
  let assert Ok(value) =
    json.parse(output, decode.field(name, decode.string, decode.success))
  value
}

pub fn a_shown_image_returns_with_the_result_and_survives_recovery_test() {
  let assert Ok(host) = runtime.start(":memory:")
  let assert Ok(session) = runtime.open_session(host, "a", "/tmp")
  let shown =
    call(
      "shown",
      "import base64\nshow_image(base64.b64decode('" <> png <> "'))",
    )
  let assert Ok(types.ToolOutput("shown", text, [image])) =
    runtime.invoke(host, session, shown)
  field(text, "value") |> should.equal("'attached image/png, 24 bytes'")
  types.image_parts(image) |> should.equal(#("image/png", png, 2, 3, 24))
  // A result lost in flight is rebuilt from the journal with its image.
  runtime.recover(host, session, shown)
  |> should.equal(types.ToolOutput("shown", text, [image]))
  runtime.stop(host)
}

pub fn an_unreadable_image_is_reported_in_the_text_not_sent_test() {
  let assert Ok(host) = runtime.start(":memory:")
  let assert Ok(session) = runtime.open_session(host, "a", "/tmp")
  let code = "show_image(b'\\x89PNG\\r\\n\\x1a\\nnot a header')"
  let assert Ok(types.ToolOutput(_, text, [])) =
    runtime.invoke(host, session, call("bad", code))
  let assert Ok([error]) =
    json.parse(
      text,
      decode.field("image_errors", decode.list(decode.string), decode.success),
    )
  error |> string.starts_with("image 1: ") |> should.be_true
  runtime.stop(host)
}

pub fn images_attach_only_to_the_running_cell_within_limits_test() {
  let assert Ok(host) = runtime.start(":memory:")
  let assert Ok(session) = runtime.open_session(host, "a", "/tmp")
  let setup =
    "import asyncio, base64\n"
    <> "image = base64.b64decode('"
    <> png
    <> "')\n"
    <> "gate = asyncio.Event()\n"
    <> "async def later():\n"
    <> "    await gate.wait()\n"
    <> "    show_image(image)\n"
    <> "task = asyncio.ensure_future(later())"
  let assert Ok(types.ToolOutput(_, _, [])) =
    runtime.invoke(host, session, call("setup", setup))
  // The task still carries the finished cell's context, not this one's.
  let assert Ok(types.ToolOutput(_, late, [])) =
    runtime.invoke(host, session, call("late", "gate.set()\nawait task"))
  field(late, "output")
  |> string.contains("images attach to a running cell")
  |> should.be_true
  let assert Ok(types.ToolOutput(_, many, [_, _, _, _])) =
    runtime.invoke(
      host,
      session,
      call("many", "for _ in range(5):\n    show_image(image)"),
    )
  field(many, "output")
  |> string.contains("a cell returns at most 4 images")
  |> should.be_true
  runtime.stop(host)
}

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
    let #(_, _, width, height, _) = types.image_parts(image)
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

pub fn summaries_describe_images_without_their_payload_test() {
  let assert Ok(image) = types.image("image/png", png, 2, 3, 24)
  loop.render_summary_input(types.UserImage("look", image))
  |> should.equal(
    "[user with image image/png 2x3, 24 bytes; binary omitted]\nlook",
  )
  loop.render_summary_input(types.ToolOutput("call", "{}", [image]))
  |> should.equal(
    "[tool output call]\n{}\n[image image/png 2x3, 24 bytes; binary omitted]",
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

@external(erlang, "albedo_conversation", "unpack")
fn unpack_input(bytes: BitArray) -> Result(types.Input, Nil)

@external(erlang, "albedo_native", "unpack_cell")
fn unpack_cell(
  bytes: BitArray,
) -> Result(Result(python.Outcome, python.Error), Nil)
