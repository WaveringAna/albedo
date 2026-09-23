import albedo/daemon/conversation
import albedo/daemon/history
import albedo/harness/compaction
import albedo/harness/extensions
import albedo/harness/extensions/lcm/extension as lcm
import albedo/harness/extensions/lcm/graph
import albedo/harness/extensions/lcm/tools
import albedo/harness/runtime
import albedo/openai_api/types
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should

fn host(capacity: Int) {
  let installed = [lcm.configured_extension(lcm.Config(Some(capacity), 90, 25))]
  let assert Ok(host) =
    runtime.start_with_config(":memory:", extensions.Config(installed, ["lcm"]))
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
  |> should.equal(["lcm_grep", "lcm_describe", "lcm_expand"])

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

pub fn lcm_condenses_source_backed_leaves_and_fork_starts_fresh_test() {
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
  let assert [types.User(summary), ..] = projected
  string.contains(summary, "condensed earlier exploration")
  |> should.be_true
  let assert Ok(expanded) = tools.expand(ledger, "lcm-test", parent.id, 0, 8000)
  string.contains(expanded, "first") |> should.be_true
  string.contains(expanded, "second") |> should.be_true

  let assert Ok(_) =
    history.fork(ledger, "lcm-test", "branch", fourth.source.seq)
  graph.frontier(ledger, "branch") |> should.equal(Ok([]))
  let assert Error(error) = tools.describe(ledger, "branch", parent.id)
  string.contains(error, "not found") |> should.be_true
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
