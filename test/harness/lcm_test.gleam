//// Forks inside condensed nodes must retain only complete child summaries.
//// Fixed graph ranges force fork boundaries that provider compaction cannot pin.

import albedo/daemon/conversation
import albedo/daemon/family
import albedo/daemon/history
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
import gleeunit/should

fn host(capacity: Int) -> #(runtime.Runtime, runtime.Session) {
  let installed = [
    memory.extension(),
    lcm.configured_extension(lcm.Config(Some(capacity), 90, 25, 4)),
    rolling.configured_extension(rolling.Config(Some(capacity), 90, 25)),
  ]
  let assert Ok(host) =
    runtime.start_with_config(
      ":memory:",
      extensions.Config(installed, ["lcm-memory", "lcm"]),
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

pub fn four_depth_zero_segments_remain_visible_then_a_fifth_promotes_the_entire_run_test() -> Nil {
  let #(host, session) = host(2000)
  let ledger = runtime.ledger(host)

  let four = [
    graph.Node(1, 0, 1, 2, "one"),
    graph.Node(2, 0, 3, 4, "two"),
    graph.Node(3, 0, 5, 6, "three"),
    graph.Node(4, 0, 7, 8, "four"),
  ]
  graph.find_mergeable_batch(four, 4, False, False)
  |> should.equal(Some(four))
  graph.find_mergeable_batch(four, 4, True, False)
  |> should.equal(None)

  let five = list.append(four, [graph.Node(5, 0, 9, 10, "five")])
  graph.find_mergeable_batch(five, 4, True, False)
  |> should.equal(Some(five))

  let initial_inputs = [
    types.User("one"),
    types.Assistant("a1"),
    types.User("two"),
    types.Assistant("a2"),
    types.User("three"),
    types.Assistant("a3"),
    types.User("four"),
    types.Assistant("a4"),
  ]
  save(host, initial_inputs)
  let assert Ok([s1, s2, s3, s4, s5, s6, s7, s8]) =
    conversation.load_sources(ledger, "lcm-test")
  let assert Ok(_) =
    graph.save_leaves(ledger, "lcm-test", [
      graph.Leaf(s1.source.seq, s2.source.seq, "seg 1"),
      graph.Leaf(s3.source.seq, s4.source.seq, "seg 2"),
      graph.Leaf(s5.source.seq, s6.source.seq, "seg 3"),
      graph.Leaf(s7.source.seq, s8.source.seq, "seg 4"),
    ])
  let assert Ok(four_frontier) = graph.frontier(ledger, "lcm-test")
  list.length(four_frontier) |> should.equal(4)

  let more_inputs = [
    types.User("five"),
    types.Assistant("a5"),
    types.User("tail"),
    types.Assistant("tail-a"),
  ]
  save(host, more_inputs)
  let all_inputs = list.append(initial_inputs, more_inputs)

  let assert Ok(_) =
    runtime.compact_history_scoped(
      host,
      session,
      "model",
      "model",
      None,
      "",
      fn(_) { Ok("merged recollection of all 5 periods") },
      all_inputs,
    )
  let assert Ok(frontier) = graph.frontier(ledger, "lcm-test")
  list.length(frontier) |> should.equal(1)
  let assert [parent] = frontier
  parent.depth |> should.equal(1)
  parent.summary |> should.equal("merged recollection of all 5 periods")
  let assert Ok(children) = graph.child_nodes(ledger, parent.id)
  list.length(children) |> should.equal(5)
  runtime.stop(host)
}

pub fn context_pressure_cascades_complete_same_depth_batches_into_higher_dag_levels_test() -> Nil {
  let #(host, session) = host(2000)
  let ledger = runtime.ledger(host)

  let raw =
    list.repeat(Nil, 16)
    |> list.index_map(fn(_, i) { i + 1 })
    |> list.flat_map(fn(i) {
      [
        types.User("u" <> int.to_string(i)),
        types.Assistant("a" <> int.to_string(i)),
      ]
    })
  save(host, raw)
  let assert Ok(sources) = conversation.load_sources(ledger, "lcm-test")
  let pairs = list.sized_chunk(sources, 2)
  let leaves =
    list.index_map(pairs, fn(pair, idx) {
      let assert [first, second] = pair
      graph.Leaf(
        first.source.seq,
        second.source.seq,
        "leaf " <> int.to_string(idx),
      )
    })
  let assert Ok(_) = graph.save_leaves(ledger, "lcm-test", leaves)
  let assert Ok(frontier) = graph.frontier(ledger, "lcm-test")
  let chunks = list.sized_chunk(frontier, 4)
  let assert [g0, g1, g2, _] = chunks
  let assert Ok(_) = graph.save_parent(ledger, "lcm-test", g0, "d1-0")
  let assert Ok(_) = graph.save_parent(ledger, "lcm-test", g1, "d1-1")
  let assert Ok(_) = graph.save_parent(ledger, "lcm-test", g2, "d1-2")

  let assert Ok(frontier_before) = graph.frontier(ledger, "lcm-test")
  list.length(frontier_before) |> should.equal(7)
  list.map(frontier_before, fn(n) { n.depth })
  |> should.equal([1, 1, 1, 0, 0, 0, 0])

  let tail = [types.User("tail"), types.Assistant("tail-a")]
  save(host, tail)
  let all = list.append(raw, tail)
  let assert Ok(_) =
    runtime.compact_history_scoped(
      host,
      session,
      "model",
      "model",
      None,
      "",
      fn(_) { Ok("merged cascade recollection") },
      all,
    )
  let assert Ok(frontier_after) = graph.frontier(ledger, "lcm-test")
  list.length(frontier_after) |> should.equal(1)
  let assert [root] = frontier_after
  root.depth |> should.equal(2)
  let assert Ok(children) = graph.child_nodes(ledger, root.id)
  list.length(children) |> should.equal(4)
  list.map(children, fn(c) { c.depth })
  |> should.equal([1, 1, 1, 1])
  runtime.stop(host)
}
