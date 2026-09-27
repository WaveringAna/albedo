import albedo/daemon/store
import albedo/harness/compaction
import albedo/harness/extension
import albedo/harness/extensions
import albedo/harness/extensions/snapcompact/extension as snapcompact
import albedo/harness/runtime
import albedo/openai_api/types
import gleam/bit_array
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
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

pub fn bound_keeps_the_first_and_newest_frames_test() {
  let shape = snapcompact.Shape(11, 16, 256, 1)
  // 23 cells per frame: ten frames, bounded to four.
  let pages =
    list.map(["a", "b", "c", "d", "e", "f", "g", "h", "i", "j"], string.repeat(
      _,
      23,
    ))
  let #(kept, dropped) = snapcompact.bound(shape, 4, string.concat(pages))
  snapcompact.paginate(shape, kept)
  |> should.equal([
    string.repeat("a", 23),
    string.repeat("h", 23),
    string.repeat("i", 23),
    string.repeat("j", 23),
  ])
  dropped |> should.equal(6 * 23)
  snapcompact.bound(shape, 10, string.concat(pages))
  |> should.equal(#(string.concat(pages), 0))
}

pub fn split_tail_keeps_whole_units_within_budget_test() {
  let history = [
    types.User("first"),
    types.Assistant("a1"),
    types.ToolOutput("t1", "o1", []),
    types.User("second"),
    types.Assistant("a2"),
    types.User("third"),
  ]
  // A one-token budget still keeps the newest unit.
  compaction.split_tail(history, 1)
  |> should.equal(#(list.take(history, 5), [types.User("third")]))
  // A single unit is never split.
  compaction.split_tail([types.User("only"), types.Assistant("a")], 1)
  |> should.equal(#([], [types.User("only"), types.Assistant("a")]))
}

pub fn split_tail_never_orphans_a_tool_output_test() {
  let history = [
    types.User("first"),
    types.User("second"),
    types.Assistant("calling"),
    types.ToolOutput("t9", "result", []),
    types.User("third"),
  ]
  let #(evicted, tail) = compaction.split_tail(history, 1)
  evicted |> list.last |> should.equal(Ok(types.ToolOutput("t9", "result", [])))
  tail |> should.equal([types.User("third")])
}

pub fn cut_resumes_across_projection_changes_test() {
  let prefix = [types.User("one"), types.Assistant("a"), types.User("two")]
  let cut = compaction.cut_of(prefix)
  cut.users |> should.equal(2)
  // Another provider merges or drops assistant output; users stay put.
  let other = [types.User("one"), types.User("two"), types.Assistant("b")]
  let assert Ok(#(evicted, rest)) =
    compaction.resume(list.append(other, [types.User("three")]), cut)
  evicted |> should.equal(other)
  rest |> should.equal([types.User("three")])
  // A rewritten user message no longer matches.
  compaction.resume(
    [types.User("uno"), types.User("two"), types.User("three")],
    cut,
  )
  |> should.equal(Error(Nil))
  // No user message left after the cut: nothing to resume into.
  compaction.resume(prefix, cut) |> should.equal(Error(Nil))
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

// The strategy through the runtime: a saved archive, how it resumes, and the
// text fallback. These render frames too.

fn host(modalities: List(String)) {
  let catalog =
    extension.Extension(
      "catalog",
      "test catalog",
      [],
      [
        extension.ModelsPlugin(
          extension.ModelCatalog(
            fn(model, _) {
              Some(
                extension.ModelInfo(
                  model,
                  "test",
                  None,
                  None,
                  None,
                  modalities,
                  None,
                  [],
                  "test catalog",
                  [],
                ),
              )
            },
            fn(_, _) { [] },
          ),
        ),
      ],
      fn(_) { Ok(Nil) },
    )
  // A 10k window: a 1k tail and a four-frame archive budget.
  let config = snapcompact.Config(Some(10_000), 90, 10, 60, None, True)
  let assert Ok(host) =
    runtime.start_with_config(
      ":memory:",
      extensions.Config([snapcompact.configured_extension(config), catalog], [
        "snapcompact", "catalog",
      ]),
    )
  let assert Ok(session) = runtime.open_session(host, "snap-test", "/tmp")
  #(host, session)
}

/// `n` turns of about a thousand estimated tokens each.
fn turns(from: Int, n: Int) -> List(types.Input) {
  list.repeat(Nil, n)
  |> list.index_map(fn(_, index) { from + index })
  |> list.flat_map(fn(i) {
    [
      types.User("u" <> int.to_string(i) <> " " <> string.repeat("a", 2000)),
      types.Assistant(
        "a" <> int.to_string(i) <> " " <> string.repeat("b", 2000),
      ),
    ]
  })
}

fn compact(host, session, history) {
  runtime.compact_history_scoped(
    host,
    session,
    "model",
    "source",
    "",
    "",
    fn(_) { Error("must not summarize") },
    history,
  )
}

fn prepare(host, session, history) {
  runtime.prepare_history_with(
    host,
    session,
    "model",
    "",
    fn(_) { Error("must not summarize") },
    history,
  )
}

fn archive_length(inputs: List(types.Input)) -> Int {
  inputs
  |> list.take_while(fn(input) {
    case input {
      types.UserImage(_, _) -> True
      _ -> False
    }
  })
  |> list.length
}

/// The regression: a forced compaction used to shape only its own request,
/// so the next request under the trigger resent the whole history.
pub fn forced_compaction_holds_for_later_requests_test() {
  let #(host, session) = host(["text", "image"])
  let history = turns(1, 6)
  let assert Ok(compacted) = compact(host, session, history)
  let assert [types.UserImage(caption, _), ..] = compacted
  string.starts_with(caption, "The images below archive") |> should.be_true
  let frames = archive_length(compacted)
  list.drop(compacted, frames) |> should.equal(list.drop(history, 10))
  prepare(host, session, history) |> should.equal(Ok(compacted))
  // New turns extend the verbatim tail behind the same archive.
  let grown = list.append(history, turns(7, 1))
  prepare(host, session, grown)
  |> should.equal(Ok(list.append(compacted, turns(7, 1))))
  runtime.stop(host)
}

/// Another provider projects assistant output differently; the cut is
/// counted in user messages, so the archive still applies.
pub fn archive_survives_a_projection_change_test() {
  let #(host, session) = host(["text", "image"])
  let history = turns(1, 6)
  let assert Ok(compacted) = compact(host, session, history)
  let frames = archive_length(compacted)
  let projected =
    list.map(history, fn(input) {
      case input {
        types.Assistant(_) -> types.Assistant("merged")
        other -> other
      }
    })
  let assert Ok(view) = prepare(host, session, projected)
  list.take(view, frames) |> should.equal(list.take(compacted, frames))
  list.drop(view, frames) |> should.equal(list.drop(projected, 10))
  runtime.stop(host)
}

pub fn rewritten_history_resets_the_archive_test() {
  let #(host, session) = host(["text", "image"])
  let history = turns(1, 6)
  let assert Ok(_) = compact(host, session, history)
  let rewritten = [types.User("a different start"), ..list.drop(history, 1)]
  prepare(host, session, rewritten) |> should.equal(Ok(rewritten))
  snapcompact.load_archive(runtime.ledger(host), "snap-test")
  |> should.equal(Ok(None))
  runtime.stop(host)
}

/// Recompacting ages new history into the saved archive text. Past the frame
/// budget the frames between the first and the newest drop, and the caption
/// says so; the first frame itself is unchanged, so the frame cache holds.
pub fn recompaction_extends_the_archive_test() {
  let #(host, session) = host(["text", "image"])
  let history = turns(1, 6)
  let assert Ok([types.UserImage(_, first_frame), ..]) =
    compact(host, session, history)
  let assert Ok(Some(before)) =
    snapcompact.load_archive(runtime.ledger(host), "snap-test")
  before.dropped |> should.equal(0)
  let grown = list.append(history, turns(7, 3))
  let assert Ok(second) = compact(host, session, grown)
  let assert Ok(Some(after)) =
    snapcompact.load_archive(runtime.ledger(host), "snap-test")
  after.cut.users |> should.equal(8)
  let assert [types.UserImage(caption, frame), ..] = second
  frame |> should.equal(first_frame)
  string.contains(caption, "were dropped") |> should.be_true
  should.be_true(after.dropped > 0)
  archive_length(second) |> should.equal(4)
  list.drop(second, 4) |> should.equal(list.drop(grown, 16))
  runtime.stop(host)
}

/// A model without image input gets rolling's text summary instead of frames.
pub fn text_model_falls_back_to_a_text_summary_test() {
  let #(host, session) = host(["text"])
  let history = turns(1, 6)
  let summaries = process.new_subject()
  let assert Ok([types.User(summary), ..]) =
    runtime.compact_history_scoped(
      host,
      session,
      "model",
      "source",
      "",
      "",
      fn(request) {
        process.send(summaries, request)
        Ok("text facts")
      },
      history,
    )
  string.contains(summary, "text facts") |> should.be_true
  let assert Ok(_) = process.receive(summaries, 0)
  snapcompact.load_archive(runtime.ledger(host), "snap-test")
  |> should.equal(Ok(None))
  runtime.stop(host)
}

pub fn frame_budget_fits_the_window_and_the_provider_test() {
  let config = snapcompact.default_config()
  let shape = snapcompact.shape("claude-opus-5-5")
  let reader = fn(provider) { Some(compaction.Reader(provider, [])) }
  // 20% of 200k at ~1.4k tokens a frame, under the provider's cap.
  snapcompact.frame_budget(config, shape, reader("claude"), Some(200_000))
  |> should.equal(27)
  // Claude uploads frames through the files API: only the image budget and
  // the archive's own cap apply.
  snapcompact.frame_budget(config, shape, reader("claude"), Some(1_000_000))
  |> should.equal(80)
  // Inline providers also carry the 3 MB frame-data budget.
  snapcompact.frame_budget(config, shape, reader("anthropic"), Some(1_000_000))
  |> should.equal(60)
  snapcompact.frame_budget(config, shape, reader("umans"), None)
  |> should.equal(10)
  snapcompact.frame_budget(config, shape, None, None)
  |> should.equal(5)
  snapcompact.frame_budget(
    snapcompact.Config(..config, max_frames: Some(5)),
    shape,
    reader("alibaba"),
    Some(1_000_000),
  )
  |> should.equal(5)
}
