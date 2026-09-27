//// Pure archive bounds and portable compaction cursors guard edge cases
//// that require unrealistic provider history sizes or projections in E2E.

import albedo/harness/compaction
import albedo/harness/extensions/snapcompact/extension as snapcompact
import albedo/openai_api/types
import gleam/list
import gleam/string
import gleeunit/should

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
