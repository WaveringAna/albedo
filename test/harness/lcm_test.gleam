//// Forks inside condensed nodes must retain only complete child summaries.
//// Fixed graph ranges force fork boundaries that provider compaction cannot pin.

import albedo/daemon/conversation
import albedo/daemon/family
import albedo/daemon/history
import albedo/harness/compaction
import albedo/harness/extension
import albedo/harness/extensions
import albedo/harness/extensions/lcm/extension as lcm
import albedo/harness/extensions/lcm/graph
import albedo/harness/extensions/lcm/memory
import albedo/harness/extensions/rolling/extension as rolling
import albedo/harness/runtime
import albedo/openai_api/types
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should

fn host(capacity: Int) -> #(runtime.Runtime, runtime.Session) {
  host_with(capacity, [])
}

fn host_with(
  capacity: Int,
  others: List(extension.Extension),
) -> #(runtime.Runtime, runtime.Session) {
  let installed = [
    memory.extension(),
    lcm.configured_extension(lcm.Config(Some(capacity), Some(90), 1)),
    rolling.configured_extension(rolling.Config(Some(capacity), 90, 25)),
    ..others
  ]
  let assert Ok(host) =
    runtime.start_with_config(
      ":memory:",
      extensions.Config(installed, [
        "lcm-memory",
        "lcm",
        ..list.map(others, fn(other) { other.name })
      ]),
    )
  let ledger = runtime.ledger(host)
  let assert Ok(_) = conversation.initialise(ledger)
  let assert Ok(_) = family.initialise(ledger)
  let assert Ok(_) =
    conversation.create(
      ledger,
      conversation.Info(
        "lcm-test",
        "new session",
        "/tmp",
        "provider",
        "model",
        types.Responses,
        conversation.Idle,
        None,
        None,
      ),
    )
  let assert Ok(session) = runtime.open_session(host, "lcm-test", "/tmp")
  #(host, session)
}

fn save(host: runtime.Runtime, inputs: List(types.Input)) -> Nil {
  let assert Ok(_) =
    conversation.commit_from(
      runtime.ledger(host),
      "lcm-test",
      inputs,
      conversation.Idle,
      Some("provider"),
    )
  Nil
}

pub fn lcm_fork_inside_summary_reuses_only_complete_child_nodes_test() -> Nil {
  let #(host, _) = host(2000)
  let ledger = runtime.ledger(host)
  let original = [
    types.User("first"),
    types.Assistant("one"),
    types.User("second"),
    types.Assistant("two"),
    types.User("third"),
    types.Assistant("three"),
  ]
  save(host, original)
  let assert Ok([first, second, third, fourth, fifth, sixth]) =
    conversation.load_sources(ledger, "lcm-test")
  let assert Ok(_) =
    graph.save_leaves(ledger, "lcm-test", [
      graph.Leaf(first.source.seq, second.source.seq, "first unit"),
      graph.Leaf(third.source.seq, fourth.source.seq, "second unit"),
      graph.Leaf(fifth.source.seq, sixth.source.seq, "third unit"),
    ])
  let assert Ok([one, two, three]) = graph.frontier(ledger, "lcm-test")
  let assert Ok(_) =
    graph.save_parent(ledger, "lcm-test", [one, two, three], "all three units")

  let assert Ok(_) =
    history.fork(ledger, "lcm-test", "partial", fourth.source.seq)
  let assert Ok([branch_one, branch_two]) = graph.frontier(ledger, "partial")
  branch_one.summary |> should.equal("first unit")
  branch_two.summary |> should.equal("second unit")
  let assert Ok([_, _, _, branch_fourth]) =
    conversation.load_sources(ledger, "partial")
  graph.last_seq(ledger, "partial")
  |> should.equal(Ok(branch_fourth.source.seq))

  let assert Ok(_) =
    history.fork(ledger, "lcm-test", "mid-leaf", third.source.seq)
  let assert Ok([only_complete]) = graph.frontier(ledger, "mid-leaf")
  only_complete.summary |> should.equal("first unit")
  let assert Ok([_, middle_second, _]) =
    conversation.load_sources(ledger, "mid-leaf")
  graph.last_seq(ledger, "mid-leaf")
  |> should.equal(Ok(middle_second.source.seq))
  runtime.stop(host)
}

/// `count` leaves of two rows each, whose summaries are `size` characters,
/// ahead of a verbatim tail; returns the history saved.
fn leaves(host: runtime.Runtime, count: Int, size: Int) -> List(types.Input) {
  let ledger = runtime.ledger(host)
  let raw =
    list.repeat(Nil, count)
    |> list.index_map(fn(_, i) { i })
    |> list.flat_map(fn(i) {
      [
        types.User("u" <> int.to_string(i)),
        types.Assistant("a" <> int.to_string(i)),
      ]
    })
  save(host, raw)
  let assert Ok(sources) = conversation.load_sources(ledger, "lcm-test")
  let assert Ok(_) =
    graph.save_leaves(
      ledger,
      "lcm-test",
      list.index_map(list.sized_chunk(sources, 2), fn(pair, i) {
        let assert [first, second] = pair
        graph.Leaf(
          first.source.seq,
          second.source.seq,
          "leaf " <> int.to_string(i) <> " " <> string.repeat("s", size),
        )
      }),
    )
  let tail = [types.User("tail"), types.Assistant("tail answer")]
  save(host, tail)
  list.append(raw, tail)
}

pub fn a_frontier_that_fits_is_never_merged_test() -> Nil {
  let #(host, session) = host(100_000)
  let history = leaves(host, 6, 10)
  let assert Ok(_) =
    compact(
      host,
      session,
      fn(_) { panic as "a frontier under the landing target is left alone" },
      history,
    )
  let assert Ok(frontier) = graph.frontier(runtime.ledger(host), "lcm-test")
  list.map(frontier, fn(node) { node.depth })
  |> should.equal([0, 0, 0, 0, 0, 0])
  runtime.stop(host)
}

pub fn pressure_merges_the_oldest_nodes_and_keeps_the_newest_test() -> Nil {
  let #(host, session) = host(4000)
  let ledger = runtime.ledger(host)
  let history = leaves(host, 6, 1600)
  let assert Ok(before) = graph.frontier(ledger, "lcm-test")
  let assert Ok(newest) = list.last(before)

  let assert Ok(_) =
    compact(host, session, fn(_) { Ok("the older periods") }, history)
  let assert Ok([oldest, ..] as after) = graph.frontier(ledger, "lcm-test")
  should.be_true(oldest.depth >= 1)
  oldest.summary |> should.equal("the older periods")
  let assert [first, ..] = before
  oldest.first_seq |> should.equal(first.first_seq)
  should.be_true(list.length(after) < list.length(before))
  list.last(after) |> should.equal(Ok(newest))
  runtime.stop(host)
}

pub fn merged_parents_of_any_size_merge_one_depth_up_test() -> Nil {
  let #(host, session) = host(2000)
  let ledger = runtime.ledger(host)
  let history = leaves(host, 4, 10)
  let assert Ok([one, two, three, four]) = graph.frontier(ledger, "lcm-test")
  let assert Ok(_) =
    graph.save_parent(ledger, "lcm-test", [one, two], string.repeat("p", 400))
  let assert Ok(_) =
    graph.save_parent(ledger, "lcm-test", [three], string.repeat("q", 2800))
  let assert Ok(_) =
    compact(host, session, fn(_) { Ok("both parents") }, history)
  let assert Ok([root, last]) = graph.frontier(ledger, "lcm-test")
  root.depth |> should.equal(2)
  root.summary |> should.equal("both parents")
  last |> should.equal(four)
  runtime.stop(host)
}

pub fn a_window_beyond_one_request_is_summarized_in_parts_test() -> Nil {
  let #(host, session) = host(1_000_000)
  let ledger = runtime.ledger(host)
  let history =
    list.repeat(Nil, 16)
    |> list.index_map(fn(_, i) { i + 1 })
    |> list.flat_map(fn(i) {
      [
        types.User(int.to_string(i) <> " " <> string.repeat("x", 64_000)),
        types.Assistant("answer"),
      ]
    })
    |> list.append([types.User("tail")])
  save(host, history)
  let assert Ok(_) =
    compact(
      host,
      session,
      fn(request) {
        case
          string.contains(request.instructions, "This request holds part"),
          string.contains(request.instructions, "consecutive parts")
        {
          True, False -> Ok("one part")
          False, True -> Ok("the whole window")
          _, _ -> panic as "a window over the input limit is never sent whole"
        }
      },
      history,
    )
  let assert Ok([leaf]) = graph.frontier(ledger, "lcm-test")
  leaf.summary |> should.equal("the whole window")
  runtime.stop(host)
}

fn compact(
  host: runtime.Runtime,
  session: runtime.Session,
  summarize: fn(compaction.SummaryRequest) -> Result(String, String),
  history: List(types.Input),
) -> Result(List(types.Input), String) {
  runtime.compact_history_scoped(
    host,
    session,
    "model",
    "model",
    None,
    "",
    summarize,
    history,
  )
}

fn mentions(request: compaction.SummaryRequest, text: String) -> Bool {
  list.any(request.evicted, fn(input) {
    case input {
      types.User(value) | types.Assistant(value) -> string.contains(value, text)
      _ -> False
    }
  })
}

pub fn a_twice_empty_summary_keeps_the_source_verbatim_test() -> Nil {
  let #(host, session) = host(2000)
  let ledger = runtime.ledger(host)
  let history = [
    types.User(
      "<system-note>a background job finished; acknowledge briefly and stay idle.</system-note>",
    ),
    types.Assistant("Nothing needed from it; staying idle."),
    types.User("tail"),
    types.Assistant("tail answer"),
  ]
  save(host, history)

  let assert Ok(_) =
    compact(host, session, fn(_) { Error(compaction.empty_summary) }, history)
  let assert Ok([leaf]) = graph.frontier(ledger, "lcm-test")
  leaf.summary
  |> string.starts_with(
    "[the summarizer returned nothing; the source kept verbatim]",
  )
  |> should.be_true
  leaf.summary |> string.contains("[user] <system-note>") |> should.be_true
  leaf.summary
  |> string.contains("[assistant] Nothing needed from it; staying idle.")
  |> should.be_true
  runtime.stop(host)
}

pub fn one_compaction_folds_its_whole_window_into_one_leaf_test() -> Nil {
  let #(host, session) = host(100_000)
  let ledger = runtime.ledger(host)
  let turn = fn(name) {
    [
      types.User(name),
      types.Assistant(name <> " " <> string.repeat("x", 16_000)),
    ]
  }
  let history =
    list.flatten([
      turn("first"),
      turn("second"),
      turn("third"),
      [types.User("tail")],
    ])
  save(host, history)

  let assert Ok(_) =
    compact(
      host,
      session,
      fn(request) {
        case
          mentions(request, "first"),
          mentions(request, "second"),
          mentions(request, "third")
        {
          True, True, True -> Ok("all three turns")
          _, _, _ -> panic as "the window is summarized in one request"
        }
      },
      history,
    )
  let assert Ok([s1, _, _, _, _, s6, _]) =
    conversation.load_sources(ledger, "lcm-test")
  let assert Ok([leaf]) = graph.frontier(ledger, "lcm-test")
  #(leaf.first_seq, leaf.last_seq)
  |> should.equal(#(s1.source.seq, s6.source.seq))
  leaf.summary |> should.equal("all three turns")
  runtime.stop(host)
}

/// Folds another strategy stored over the first two user turns, the way
/// snapcompact's archive covers everything before its cut.
fn archive() -> extension.Extension {
  extension.Extension(
    "archive",
    "stand-in for another strategy's stored folds",
    [],
    [
      extension.FoldPlugin(
        compaction.Folds("archive", "archive", fn(_, _, history) {
          let assert Ok(#(_, rest)) =
            compaction.resume(history, compaction.cut_of(list.take(history, 4)))
          Ok(compaction.Prior([types.User("[archive pages]")], rest))
        }),
      ),
    ],
    fn(_) { Ok(Nil) },
  )
}

pub fn switching_to_lcm_points_at_the_archive_and_folds_the_live_rows_into_one_leaf_test() -> Nil {
  let #(host, session) = host_with(2000, [archive()])
  let ledger = runtime.ledger(host)
  let history = [
    types.User("old one"),
    types.Assistant("old answer one"),
    types.User("old two"),
    types.Assistant("old answer two"),
    types.User("live one"),
    types.Assistant("live answer one"),
    types.User("live two"),
    types.Assistant("live answer two"),
    types.User("tail"),
  ]
  save(host, history)

  let assert Ok(_) =
    compact(
      host,
      session,
      fn(request) {
        case mentions(request, "old"), mentions(request, "live two") {
          False, True -> Ok("the live window, summarized once")
          _, _ -> panic as "only the live rows are summarized, in one request"
        }
      },
      history,
    )
  let assert Ok([s1, _, _, s4, s5, _, _, s8, _]) =
    conversation.load_sources(ledger, "lcm-test")
  let assert Ok([pointer, live]) = graph.frontier(ledger, "lcm-test")
  #(pointer.first_seq, pointer.last_seq)
  |> should.equal(#(s1.source.seq, s4.source.seq))
  pointer.summary
  |> string.starts_with("Earlier history, archived")
  |> should.be_true
  #(live.first_seq, live.last_seq)
  |> should.equal(#(s5.source.seq, s8.source.seq))
  live.summary |> should.equal("the live window, summarized once")
  runtime.stop(host)
}
