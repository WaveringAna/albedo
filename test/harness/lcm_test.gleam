import albedo/daemon/conversation
import albedo/daemon/history
import albedo/harness/compaction
import albedo/harness/extensions
import albedo/harness/extensions/lcm/extension as lcm
import albedo/harness/extensions/lcm/graph
import albedo/harness/extensions/lcm/memory
import albedo/harness/extensions/lcm/tools
import albedo/harness/extensions/rolling/extension as rolling
import albedo/harness/runtime
import albedo/openai_api/types
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should

fn host(capacity: Int) {
  let installed = [
    memory.extension(),
    lcm.configured_extension(lcm.Config(Some(capacity), 90, 25)),
    rolling.configured_extension(rolling.Config(Some(capacity), 90, 25)),
  ]
  let assert Ok(host) =
    runtime.start_with_config(
      ":memory:",
      extensions.Config(installed, ["lcm-memory", "lcm"]),
    )
  let ledger = runtime.ledger(host)
  let assert Ok(_) = conversation.initialise(ledger)
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
      ),
    )
  let assert Ok(session) = runtime.open_session(host, "lcm-test", "/tmp")
  #(host, session)
}

fn history() -> List(types.Input) {
  [
    types.User("first clue " <> string.repeat("a", 380)),
    types.Assistant("first answer " <> string.repeat("b", 380)),
    types.User("second clue " <> string.repeat("c", 380)),
    types.Assistant("second answer " <> string.repeat("d", 380)),
    types.User("latest question"),
    types.Assistant("latest answer"),
  ]
}

fn save(host: runtime.Runtime, inputs: List(types.Input)) {
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

pub fn lcm_manual_compaction_keeps_sources_retrievable_and_tail_whole_test() {
  let #(host, session) = host(2000)
  let original = history()
  save(host, original)
  runtime.tools(session)
  |> list.map(fn(tool) { tool.name })
  |> should.equal(["lcm_list", "lcm_grep", "lcm_describe", "lcm_expand"])

  let assert Ok(projected) =
    runtime.compact_history_scoped(
      host,
      session,
      "model",
      "provider:model",
      "",
      "",
      fn(_: compaction.SummaryRequest) {
        Ok("first and second clues were explored")
      },
      original,
    )
  let assert [types.User(summary), ..] = projected
  string.contains(summary, "LCM summary node #") |> should.be_true
  string.contains(summary, "first and second clues") |> should.be_true
  list.drop(projected, list.length(projected) - 2)
  |> should.equal(list.drop(original, 4))

  let ledger = runtime.ledger(host)
  let assert Ok([node]) = graph.frontier(ledger, "lcm-test")
  let assert Ok(sources) = conversation.load_sources(ledger, "lcm-test")
  let assert [first, _, _, fourth, ..] = sources
  node.first_seq |> should.equal(first.source.seq)
  node.last_seq |> should.equal(fourth.source.seq)
  let assert Ok(found) = tools.grep(ledger, "lcm-test", "first clue", 10)
  string.contains(found, "first clue") |> should.be_true
  let assert Ok(described) = tools.describe(ledger, "lcm-test", node.id)
  string.contains(described, "first_seq") |> should.be_true
  let assert Ok(expanded) = tools.expand(ledger, "lcm-test", node.id, 0, 8000)
  string.contains(expanded, "first clue") |> should.be_true
  string.contains(expanded, "second answer") |> should.be_true
  string.contains(expanded, "latest question") |> should.be_false

  runtime.prepare_history_scoped(
    host,
    session,
    "model",
    "provider:model",
    "",
    "",
    fn(_) { Error("must reuse the saved node") },
    original,
  )
  |> should.equal(Ok(projected))
  runtime.stop(host)
}

pub fn switching_from_lcm_to_rolling_keeps_folded_history_retrievable_test() {
  let #(host, session) = host(2000)
  let original = history()
  save(host, original)
  let assert Ok(_) =
    runtime.compact_history_scoped(
      host,
      session,
      "model",
      "provider:model",
      "",
      "",
      fn(_) { Ok("first and second clues were explored") },
      original,
    )
  let ledger = runtime.ledger(host)
  let assert Ok([node]) = graph.frontier(ledger, "lcm-test")
  let assert Ok(rolling_session) =
    runtime.reload_extension(host, "lcm-test", "/tmp", "rolling", True)
  let assert Ok(summaries) = runtime.extension_summaries(host, "lcm-test")
  let enabled =
    summaries
    |> list.filter(fn(item) { item.enabled })
    |> list.map(fn(item) { item.name })
  enabled |> should.equal(["lcm-memory", "rolling"])
  runtime.tools(rolling_session)
  |> list.map(fn(tool) { tool.name })
  |> should.equal(["lcm_list", "lcm_grep", "lcm_describe", "lcm_expand"])

  let assert Ok(folded) =
    runtime.prepare_history_scoped(
      host,
      rolling_session,
      "model",
      "provider:model",
      "",
      "",
      fn(_) { Error("unexpected summary call") },
      original,
    )
  let assert [types.User(summary), ..] = folded
  string.contains(summary, "LCM summary node #") |> should.be_true
  string.contains(summary, "first clue") |> should.be_false
  list.drop(folded, 1) |> should.equal(list.drop(original, 4))

  let assert Ok(compacted) =
    runtime.compact_history_scoped(
      host,
      rolling_session,
      "model",
      "provider:model",
      "",
      "",
      fn(request) {
        let assert [types.User(evicted), ..] = request.evicted
        string.contains(evicted, "LCM summary node #") |> should.be_true
        string.contains(evicted, "first clue") |> should.be_false
        Ok("rolled memory")
      },
      original,
    )
  let assert [types.User(rolled), ..] = compacted
  string.contains(rolled, "rolled memory") |> should.be_true
  let assert Ok(folds) = tools.list_folds(ledger, "lcm-test", 20, 0)
  string.contains(folds, "\"id\":" <> int.to_string(node.id))
  |> should.be_true
  let assert Ok(expanded) = tools.expand(ledger, "lcm-test", node.id, 0, 8000)
  string.contains(expanded, "first clue") |> should.be_true
  runtime.stop(host)
}

pub fn failed_lcm_summary_leaves_graph_and_transcript_unchanged_test() {
  let #(host, session) = host(2000)
  let original = history()
  save(host, original)
  let assert Error(error) =
    runtime.compact_history_scoped(
      host,
      session,
      "model",
      "provider:model",
      "",
      "",
      fn(_) { Error("provider unavailable") },
      original,
    )
  string.contains(error, "provider unavailable") |> should.be_true
  graph.last_seq(runtime.ledger(host), "lcm-test") |> should.equal(Ok(0))
  graph.frontier(runtime.ledger(host), "lcm-test") |> should.equal(Ok([]))
  conversation.load(runtime.ledger(host), "lcm-test")
  |> should.equal(Ok(original))
  runtime.stop(host)
}

pub fn lcm_condenses_and_fork_reuses_completed_summary_tree_test() {
  let #(host, session) = host(700)
  let original = [
    types.User("first"),
    types.Assistant("one"),
    types.User("second"),
    types.Assistant("two"),
    types.User("latest"),
    types.Assistant("three"),
  ]
  save(host, original)
  let ledger = runtime.ledger(host)
  let assert Ok([first, second, third, fourth, _, _]) =
    conversation.load_sources(ledger, "lcm-test")
  let assert Ok(_) =
    graph.save_leaves(ledger, "lcm-test", [
      graph.Leaf(first.source.seq, second.source.seq, string.repeat("a", 1600)),
      graph.Leaf(third.source.seq, fourth.source.seq, string.repeat("b", 1600)),
    ])
  let assert Ok([left, right]) = graph.frontier(ledger, "lcm-test")
  let assert Ok(projected) =
    runtime.prepare_history_scoped(
      host,
      session,
      "model",
      "provider:model",
      "",
      "",
      fn(_) { Ok("condensed earlier exploration") },
      original,
    )
  let assert Ok([parent]) = graph.frontier(ledger, "lcm-test")
  parent.depth |> should.equal(1)
  graph.children(ledger, parent.id) |> should.equal(Ok([left.id, right.id]))
  let assert Error(_) =
    graph.save_parent(ledger, "lcm-test", [left, right], "duplicate parent")
  let assert Ok(nodes_after_failed_write) = graph.all_nodes(ledger, "lcm-test")
  list.length(nodes_after_failed_write) |> should.equal(3)
  let assert Ok(folds) = tools.list_folds(ledger, "lcm-test", 20, 0)
  string.contains(folds, "\"total\":3") |> should.be_true
  string.contains(folds, "\"id\":" <> int.to_string(left.id))
  |> should.be_true
  string.contains(folds, "\"id\":" <> int.to_string(right.id))
  |> should.be_true
  string.contains(folds, "\"id\":" <> int.to_string(parent.id))
  |> should.be_true
  let assert Ok(first_page) = tools.list_folds(ledger, "lcm-test", 2, 0)
  string.contains(first_page, "\"next_offset\":2") |> should.be_true
  let assert Ok(second_page) = tools.list_folds(ledger, "lcm-test", 2, 2)
  string.contains(second_page, "\"id\":" <> int.to_string(parent.id))
  |> should.be_true
  string.contains(second_page, "\"next_offset\":null")
  |> should.be_true
  let assert [types.User(summary), ..] = projected
  string.contains(summary, "condensed earlier exploration")
  |> should.be_true
  let assert Ok(expanded) = tools.expand(ledger, "lcm-test", parent.id, 0, 8000)
  string.contains(expanded, "first") |> should.be_true
  string.contains(expanded, "second") |> should.be_true

  let assert Ok(_) =
    history.fork(ledger, "lcm-test", "branch", fourth.source.seq)
  let assert Ok([branch_parent]) = graph.frontier(ledger, "branch")
  branch_parent.summary |> should.equal(parent.summary)
  branch_parent.depth |> should.equal(parent.depth)
  let assert Ok(branch_sources) = conversation.load_sources(ledger, "branch")
  let assert [branch_first, _, _, branch_fourth] = branch_sources
  branch_parent.first_seq |> should.equal(branch_first.source.seq)
  branch_parent.last_seq |> should.equal(branch_fourth.source.seq)
  graph.last_seq(ledger, "branch")
  |> should.equal(Ok(branch_fourth.source.seq))
  let assert Ok(branch_expanded) =
    tools.expand(ledger, "branch", branch_parent.id, 0, 8000)
  string.contains(branch_expanded, "first") |> should.be_true
  string.contains(branch_expanded, "second") |> should.be_true
  let assert Ok(branch_session) = runtime.open_session(host, "branch", "/tmp")
  let assert Ok(branch_view) =
    runtime.prepare_history_scoped(
      host,
      branch_session,
      "model",
      "provider:model",
      "",
      "",
      fn(_) { Error("fork should reuse the saved summary") },
      list.take(original, 4),
    )
  let assert [types.User(branch_summary), ..] = branch_view
  string.contains(branch_summary, "condensed earlier exploration")
  |> should.be_true
  let assert Ok(rolling_branch) =
    runtime.reload_extension(host, "branch", "/tmp", "rolling", True)
  let assert Ok(folded_branch) =
    runtime.prepare_history_scoped(
      host,
      rolling_branch,
      "model",
      "provider:model",
      "",
      "",
      fn(_) { Error("folded prefix needs no summary call") },
      list.take(original, 4),
    )
  let assert [types.User(only_fold)] = folded_branch
  string.contains(only_fold, "condensed earlier exploration")
  |> should.be_true
  let continuation =
    list.append(list.take(original, 4), [types.Assistant("post-fold result")])
  let assert Ok(_) =
    conversation.commit_from(
      ledger,
      "branch",
      continuation,
      conversation.Idle,
      Some("provider"),
    )
  let assert Ok(continued) =
    runtime.prepare_history_scoped(
      host,
      rolling_branch,
      "model",
      "provider:model",
      "",
      "",
      fn(_) { Error("continued branch needs no summary call") },
      continuation,
    )
  let assert Ok(types.Assistant("post-fold result")) = list.last(continued)
  let assert Error(error) = tools.describe(ledger, "branch", parent.id)
  string.contains(error, "not found") |> should.be_true
  runtime.stop(host)
}

pub fn lcm_fork_inside_summary_reuses_only_complete_child_nodes_test() {
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

pub fn lcm_search_pages_sources_and_limits_scope_test() {
  let #(host, _) = host(2000)
  let ledger = runtime.ledger(host)
  let inputs =
    list.repeat(Nil, 25)
    |> list.index_map(fn(_, index) {
      types.User("needle-" <> int.to_string(index))
    })
  save(host, inputs)
  let assert Ok(sources) = conversation.load_sources(ledger, "lcm-test")
  let assert [first, second, ..] = sources
  let assert Ok(_) =
    graph.save_leaves(ledger, "lcm-test", [
      graph.Leaf(first.source.seq, second.source.seq, "first two needles"),
    ])
  let assert Ok([node]) = graph.frontier(ledger, "lcm-test")

  let assert Ok(first_page) =
    tools.grep_page(ledger, "lcm-test", "needle-", 10, 0, None)
  string.contains(first_page, "needle-0") |> should.be_true
  string.contains(first_page, "needle-20") |> should.be_false
  string.contains(first_page, "\"next_offset\":10") |> should.be_true
  string.contains(first_page, "\"node_id\":" <> int.to_string(node.id))
  |> should.be_true

  let assert Ok(last_page) =
    tools.grep_page(ledger, "lcm-test", "needle-", 10, 20, None)
  string.contains(last_page, "needle-20") |> should.be_true
  string.contains(last_page, "\"next_offset\":null") |> should.be_true

  let assert Ok(scoped) =
    tools.grep_page(ledger, "lcm-test", "needle-", 10, 0, Some(node.id))
  string.contains(scoped, "\"source_count\":2") |> should.be_true
  string.contains(scoped, "needle-20") |> should.be_false
  runtime.stop(host)
}

pub fn lcm_oversized_summary_falls_back_to_source_pointer_test() {
  let #(host, session) = host(2000)
  let original = history()
  save(host, original)
  let assert Ok(projected) =
    runtime.compact_history_scoped(
      host,
      session,
      "model",
      "provider:model",
      "",
      "",
      fn(_) { Ok(string.repeat("too long ", 1000)) },
      original,
    )
  let assert [types.User(summary), ..] = projected
  string.contains(summary, "Summary exceeded its source") |> should.be_true
  let assert Ok([node]) = graph.frontier(runtime.ledger(host), "lcm-test")
  let assert Ok(expanded) =
    tools.expand(runtime.ledger(host), "lcm-test", node.id, 0, 8000)
  string.contains(expanded, "first clue") |> should.be_true
  runtime.stop(host)
}
