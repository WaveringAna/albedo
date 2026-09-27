//// A fork inside a condensed LCM node must reuse only complete children.

import albedo/daemon/conversation
import albedo/daemon/history
import albedo/harness/extensions
import albedo/harness/extensions/lcm/extension as lcm
import albedo/harness/extensions/lcm/graph
import albedo/harness/extensions/lcm/memory
import albedo/harness/extensions/rolling/extension as rolling
import albedo/harness/runtime
import albedo/openai_api/types
import gleam/option.{None, Some}
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
        None,
      ),
    )
  let assert Ok(session) = runtime.open_session(host, "lcm-test", "/tmp")
  #(host, session)
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
