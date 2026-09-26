import albedo/daemon/store
import albedo/harness/extensions/snapcompact/extension as snapcompact
import albedo/openai_api/types
import gleam/bit_array
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/string
import gleeunit/should

// The pure strategy pieces: shape resolution, serialization, pagination, and
// the tail cut. The render tests need albedo-render built (native/render).

pub fn shape_test() {
  snapcompact.shape("claude-opus-5-5")
  |> should.equal(snapcompact.Shape(11, 16, 1568, 44))
  snapcompact.shape("openai/gpt-5.5")
  |> should.equal(snapcompact.Shape(8, 22, 1568, 56))
  snapcompact.shape("google/gemini-3.5-flash")
  |> should.equal(snapcompact.Shape(8, 22, 2048, 64))
  snapcompact.shape("some-unknown-model")
  |> should.equal(snapcompact.Shape(11, 16, 1568, 44))
}

pub fn serialize_marks_each_kind_test() {
  let text =
    snapcompact.normalize([
      types.User("fix the stream"),
      types.Assistant("done"),
      types.UserImage("look", png_image()),
      types.ToolOutput("call-1", "ok", []),
    ])
  text |> string.contains("¶user: fix the stream") |> should.be_true
  text |> string.contains("¶ai: done") |> should.be_true
  text |> string.contains("[image ") |> should.be_true
  text |> string.contains("¶out call-1: ok") |> should.be_true
}

/// Replayed tool calls serialize as readable name(args) with decoded values,
/// not as escaped JSON.
pub fn replay_calls_serialize_readably_test() {
  let args =
    json.object([
      #("code", json.string("line1\nline2")),
      #("timeout_ms", json.int(60_000)),
    ])
    |> json.to_string
  let message =
    json.object([
      #("role", json.string("assistant")),
      #("content", json.string("fixing the stream")),
      #(
        "tool_calls",
        json.array(
          [
            json.object([
              #("id", json.string("c1")),
              #(
                "function",
                json.object([
                  #("name", json.string("python")),
                  #("arguments", json.string(args)),
                ]),
              ),
            ]),
          ],
          fn(value) { value },
        ),
      ),
    ])
    |> json.to_string
  let assert Ok(value) = json.parse(message, decode.dynamic)
  let assert Ok(item) =
    decode.run(value, types.replay_decoder(types.ChatCompletions))
  let text = snapcompact.normalize([types.Replay(item)])
  assert text |> string.contains("¶ai: fixing the stream")
  // The arguments decode to sorted key = value pairs; the newline in the
  // code becomes a block cell, not a backslash escape.
  assert text |> string.contains("→ python(code = line1\u{2588}line2")
  assert text |> string.contains(", timeout_ms = 60000)")
  assert string.contains(text, "\\n") == False
}

/// Compound argument values format through iolist encoding instead of
/// falling back to the raw JSON string.
pub fn compound_arguments_format_readably_test() {
  let args =
    json.object([
      #("deep", json.object([#("x", json.bool(True))])),
      #("list", json.preprocessed_array([json.int(1), json.int(2)])),
    ])
    |> json.to_string
  let formatted = format(args)
  formatted
  |> string.contains("deep = {\"x\":true}, list = [1,2]")
  |> should.be_true
}

/// Responses-protocol replays are not decoded: the raw JSON survives whole
/// instead of silently dropping the turn's tool calls.
pub fn responses_replays_fall_back_to_raw_json_test() {
  let message =
    json.object([
      #("type", json.string("function_call")),
      #("name", json.string("python")),
      #("arguments", json.string("{\"k\":1}")),
    ])
    |> json.to_string
  let assert Ok(item) =
    json.parse(message, types.replay_decoder(types.Responses))
  let text = snapcompact.normalize([types.Replay(item)])
  assert string.starts_with(text, "¶turn: ")
  assert string.contains(text, "python")
}

pub fn normalize_folds_newline_runs_to_block_cells_test() {
  let text =
    snapcompact.normalize([
      types.User("\u{1b}[31mred\u{1b}[0m plain\r\n\r\n\r\nafter\ttab"),
    ])
  // One newline run folds to a single full-block cell; wrapping is positional.
  text |> should.equal("¶user: red plain\u{2588}after    tab")
}

pub fn serialize_caps_long_outputs_test() {
  let long = string.repeat("x", 20_000)
  let text = snapcompact.normalize([types.ToolOutput("c", long, [])])
  text
  |> string.contains("[+truncated]")
  |> should.be_true
  case string.length(text) < 2000 {
    True -> Nil
    False -> panic as "a capped tool result stays small"
  }
}

pub fn paginate_chunks_the_continuous_cell_stream_test() {
  // 256px wide at an 11px advance fits 23 cells; one row per frame.
  let shape = snapcompact.Shape(11, 16, 256, 1)
  let cells = string.repeat("x", 23) <> "█" <> string.repeat("y", 26)
  let chunks = snapcompact.paginate(shape, cells)
  chunks
  |> should.equal([
    string.repeat("x", 23),
    "█" <> string.repeat("y", 22),
    string.repeat("y", 4),
  ])
}

pub fn paginate_keeps_the_newest_frames_test() {
  let shape = snapcompact.Shape(11, 16, 256, 1)
  // 23 cells per frame: 10 frames from 230 cells, capped to 8.
  let cells = string.repeat("a", 230)
  let chunks = snapcompact.paginate(shape, cells)
  chunks |> list.length |> should.equal(8)
  chunks |> list.first |> should.equal(Ok(string.repeat("a", 23)))
}

pub fn cut_keeps_tail_budget_at_a_user_boundary_test() {
  let history =
    list.append(
      [
        types.User("first"),
        types.Assistant("a1"),
        types.ToolOutput("t1", "o1", []),
      ],
      [
        types.User("second"),
        types.Assistant("a2"),
        types.User("third"),
      ],
    )
  let #(evicted, tail) = snapcompact.cut(1, history)
  // A one-token budget keeps only the final user message as the tail.
  evicted
  |> should.equal([
    types.User("first"),
    types.Assistant("a1"),
    types.ToolOutput("t1", "o1", []),
    types.User("second"),
    types.Assistant("a2"),
  ])
  tail |> should.equal([types.User("third")])
}

pub fn cut_never_orphans_a_tool_output_test() {
  let history = [
    types.User("first"),
    types.User("second"),
    types.Assistant("calling"),
    types.ToolOutput("t9", "result", []),
    types.User("third"),
  ]
  // The budget lands mid-pair: the result moves back with its call.
  let #(evicted, tail) = snapcompact.cut(1, history)
  evicted
  |> list.last
  |> should.equal(Ok(types.ToolOutput("t9", "result", [])))
  tail |> list.first |> should.equal(Ok(types.User("third")))
  evicted
  |> list.contains(types.Assistant("calling"))
  |> should.be_true
}

pub fn render_frame_test() {
  let assert Ok(#(width, height, data)) =
    snapcompact.render_frame_test("hello world", 11, 16, 1568)
  width |> should.equal(1568)
  height |> should.equal(16)
  let assert Ok(png) = bit_array.base64_decode(data)
  png
  |> bit_array.slice(0, 8)
  |> should.equal(Ok(<<137, 80, 78, 71, 13, 10, 26, 10>>))
}

pub fn frames_render_and_cache_test() {
  let assert Ok(ledger) = store.start(":memory:", "")
  let assert Ok(_) = snapcompact.initialise(ledger)
  let shape = snapcompact.Shape(11, 16, 1568, 44)
  let chunks = ["hello frames", "hello frames", "second chunk"]
  let assert Ok(images) = snapcompact.frames(ledger, shape, chunks)
  images |> list.length |> should.equal(3)
  // The repeated chunk shares one frame; the images differ only by content.
  let assert [first, second, third] = images
  types.image_meta(first) |> should.equal(types.image_meta(second))
  // bytes is the decoded png size, and the base64 size derives from it.
  let assert #("image/png", width, height, bytes) = types.image_meta(first)
  should.be_true(width > 0)
  height |> should.equal(16)
  let assert types.StoredData(hash, size, read) = types.image_data(first)
  let assert Ok(b64) = read()
  let assert Ok(png) = bit_array.base64_decode(b64)
  bit_array.byte_size(png) |> should.equal(bytes)
  size |> should.equal({ bytes + 2 } / 3 * 4)
  hash |> string.byte_size |> should.equal(64)
  let _ = third
  Nil
}

fn format(args: String) -> String {
  let message =
    json.object([
      #("role", json.string("assistant")),
      #("content", json.string("")),
      #(
        "tool_calls",
        json.array(
          [
            json.object([
              #("id", json.string("c1")),
              #(
                "function",
                json.object([
                  #("name", json.string("python")),
                  #("arguments", json.string(args)),
                ]),
              ),
            ]),
          ],
          fn(value) { value },
        ),
      ),
    ])
    |> json.to_string
  let assert Ok(value) = json.parse(message, decode.dynamic)
  let assert Ok(item) =
    decode.run(value, types.replay_decoder(types.ChatCompletions))
  snapcompact.normalize([types.Replay(item)])
}

fn png_image() -> types.Image {
  // A tiny stored image: only its metadata is serialized.
  let assert Ok(image) =
    types.stored_image(
      "image/png",
      string.repeat("ab", 32),
      100,
      fn() { Error(Nil) },
      8,
      8,
      64,
    )
  image
}
