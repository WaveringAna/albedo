//// Payload decode counts are a performance invariant invisible to HTTP E2E.
//// A long archived prefix must not be decoded by an ordinary preparation.

import albedo/daemon/conversation
import albedo/daemon/store
import albedo/harness/extensions
import albedo/harness/extensions/lcm/extension as lcm
import albedo/harness/extensions/lcm/graph
import albedo/harness/extensions/lcm/memory
import albedo/harness/runtime
import albedo/openai_api/types
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should

@external(erlang, "albedo_lcm_preparation_test_support", "count_decodes")
fn count_decodes(owner: process.Pid, run: fn() -> a) -> #(a, Int)

pub fn below_trigger_and_stored_prior_do_not_decode_archived_payloads_test() -> Nil {
  let installed = [
    memory.extension(),
    lcm.configured_extension(lcm.Config(Some(2000), 90, 1)),
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
        "preparation",
        "test",
        "/tmp",
        "provider",
        "model",
        types.Responses,
        conversation.Idle,
        None,
        None,
      ),
    )
  let archived =
    list.repeat(Nil, 400)
    |> list.flat_map(fn(_) {
      [types.User("archived user"), types.Assistant("archived answer")]
    })
  let inputs =
    list.append(archived, [types.User("latest"), types.Assistant("tail")])
  let assert Ok(_) =
    conversation.commit_from(
      ledger,
      "preparation",
      inputs,
      conversation.Idle,
      Some("provider"),
    )
  let assert Ok(rows) = conversation.load_sources(ledger, "preparation")
  let assert [first, ..] = rows
  let assert Ok(last) = list.last(list.take(rows, 800))
  let assert Ok(_) =
    graph.save_leaves(ledger, "preparation", [
      graph.Leaf(first.source.seq, last.source.seq, "archived prefix"),
    ])
  let #(control, positive_decodes) =
    count_decodes(store.owner(ledger), fn() {
      conversation.load_sources(ledger, "preparation")
    })
  let assert Ok(_) = control
  should.be_true(positive_decodes >= 802)
  let assert Ok(session) = runtime.open_session(host, "preparation", "/tmp")
  let #(prepared, decodes) =
    count_decodes(store.owner(ledger), fn() {
      runtime.prepare_history_with(
        host,
        session,
        "model",
        "",
        fn(_) { panic as "below-trigger preparation must not summarize" },
        inputs,
      )
    })
  let assert Ok([
    types.User(summary),
    types.User("latest"),
    types.Assistant("tail"),
  ]) = prepared
  should.be_true(string.contains(summary, "archived prefix"))
  decodes |> should.equal(0)
  let #(prior, decodes) =
    count_decodes(store.owner(ledger), fn() {
      lcm.stored_prior(ledger, "preparation", inputs)
    })
  let assert Ok(_) = prior
  decodes |> should.equal(0)
  let assert Ok(_) =
    conversation.commit_from(
      ledger,
      "preparation",
      [types.User("next")],
      conversation.Idle,
      Some("provider"),
    )
  let next = list.append(inputs, [types.User("next")])
  let #(failed, decodes) =
    count_decodes(store.owner(ledger), fn() {
      runtime.compact_history_scoped(
        host,
        session,
        "model",
        "model",
        None,
        "",
        fn(_) { Error("summary unavailable") },
        next,
      )
    })
  failed |> should.equal(Error("compaction lcm: summary unavailable"))
  decodes |> should.equal(2)
  graph.last_seq(ledger, "preparation") |> should.equal(Ok(last.source.seq))
  let #(compacted, decodes) =
    count_decodes(store.owner(ledger), fn() {
      runtime.compact_history_scoped(
        host,
        session,
        "model",
        "model",
        None,
        "",
        fn(_) { Ok("short") },
        next,
      )
    })
  let assert Ok(_) = compacted
  decodes |> should.equal(2)
  graph.last_seq(ledger, "preparation") |> should.equal(Ok(last.source.seq + 2))
  runtime.stop(host)
}
