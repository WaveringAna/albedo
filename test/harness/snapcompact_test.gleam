//// Pure archive bounds and portable compaction cursors guard edge cases
//// that require unrealistic provider history sizes or projections in E2E.
//// Frames fitting a provider's edge needs a provider that declares one, and
//// the E2E fake provider declares none.

import albedo/harness/compaction
import albedo/harness/extensions/snapcompact/extension as snapcompact
import albedo/openai_api/types
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit/should

pub fn bound_keeps_the_first_and_newest_frames_test() -> Nil {
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

pub fn a_full_frame_renders_inside_the_provider_edge_test() -> Nil {
  let limits = types.ImageLimits(max_edge: 1000, max_images: None)
  use model <- list.each(["gemini-3-pro", "gpt-5", "claude-opus-5-5"])
  let shape = snapcompact.fit(snapcompact.shape(model), limits)
  let assert [page, ..] =
    snapcompact.paginate(shape, string.repeat("x\u{2588}", 100_000))
  let assert Ok(#(width, height, _)) =
    snapcompact.render_frame_test(page, shape.advance, shape.pitch, shape.width)
  { width <= 1000 && height <= 1000 } |> should.be_true
}

pub fn paginate_never_splits_a_multibyte_cell_test() -> Nil {
  let shape = snapcompact.Shape(11, 16, 256, 1)
  // The 23rd cell, which fills the first frame, is the 3-byte newline cell.
  let first = string.repeat("a", 22) <> "\u{2588}"
  let second = string.repeat("b", 23)
  snapcompact.paginate(shape, first <> second)
  |> should.equal([first, second])
}

pub fn split_tail_keeps_whole_units_within_budget_test() -> Nil {
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

pub fn split_tail_never_orphans_a_tool_output_test() -> Nil {
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

pub fn cut_resumes_across_projection_changes_test() -> Nil {
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

fn replay(protocol: types.Protocol, body: String) -> types.Input {
  let assert Ok(item) = json.parse(body, types.replay_decoder(protocol))
  types.Replay(item)
}

pub fn responses_items_render_as_text_and_calls_without_reasoning_test() -> Nil {
  let archive =
    snapcompact.normalize([
      replay(
        types.Responses,
        "{\"type\":\"reasoning\",\"id\":\"rs_1\",\"encrypted_content\":\"OPAQUEBLOB\"}",
      ),
      replay(
        types.Responses,
        "{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"checking\"}]}",
      ),
      replay(
        types.Responses,
        "{\"type\":\"function_call\",\"call_id\":\"c1\",\"name\":\"python\",\"arguments\":\"{\\\"code\\\":\\\"print(1)\\\"}\"}",
      ),
    ])
  string.contains(archive, "OPAQUEBLOB") |> should.be_false
  string.contains(archive, "¶turn:") |> should.be_false
  string.contains(archive, "¶ai: checking") |> should.be_true
  string.contains(archive, "→ python(code = print(1))") |> should.be_true
}

pub fn evicted_capability_notes_do_not_reach_the_archive_test() -> Nil {
  let archive =
    snapcompact.normalize([
      types.User(
        "<system-note origin=\"capabilities changed\">old catalog</system-note>",
      ),
      types.User(
        "<system-note origin=\"python kernel\">kept note</system-note>",
      ),
      types.User("real question"),
    ])
  string.contains(archive, "old catalog") |> should.be_false
  string.contains(archive, "kept note") |> should.be_true
  string.contains(archive, "real question") |> should.be_true
}
