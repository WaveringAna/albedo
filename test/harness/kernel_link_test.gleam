//// A replayed host call must never run twice, and only a call an earlier
//// daemon started without answering may come back as "outcome unknown". The
//// replay that reaches this ledger needs a daemon restart between a call and
//// its acknowledgement, which E2E cannot place; the ledger is driven here.

import albedo/daemon/store
import albedo/harness/extensions/python/link
import gleam/option
import gleeunit/should

fn recorded() -> #(store.Store, link.Record) {
  let assert Ok(ledger) = store.start(":memory:", "")
  let record =
    link.Record(
      session: "s",
      kernel: "k1",
      token: "t",
      run_dir: "/nowhere",
      cwd: "/tmp",
      modules: "[]",
      out_seq: 0,
      owned: "{}",
    )
  let assert Ok(_) = link.create(ledger, record)
  #(ledger, record)
}

pub fn a_replayed_call_is_answered_not_run_again_test() -> Nil {
  let #(ledger, record) = recorded()
  link.call(ledger, record, "c1") |> should.equal(link.Fresh)
  let assert Ok(_) = link.reply(ledger, record, "c1", 1, "{\"type\":\"reply\"}")
  // The kernel never saw our ack and sends the call again: its reply is
  // already on the way through the outbox.
  link.call(ledger, record, "c1") |> should.equal(link.Answered)
  link.pending(ledger, record) |> should.equal([#(1, "{\"type\":\"reply\"}")])
  // Once the kernel has the reply, the call and its frame are gone.
  let assert Ok(_) = link.ack(ledger, record, 1)
  link.pending(ledger, record) |> should.equal([])
  store.close(ledger)
}

pub fn a_call_an_earlier_daemon_never_answered_is_unknown_test() -> Nil {
  let #(ledger, record) = recorded()
  link.call(ledger, record, "c1") |> should.equal(link.Fresh)
  // The daemon restarted before answering: a replay must not run it again.
  link.call(ledger, record, "c1") |> should.equal(link.Unknown)
  store.close(ledger)
}

pub fn a_restarted_daemon_resends_and_keeps_counting_test() -> Nil {
  let #(ledger, record) = recorded()
  let assert Ok(_) = link.persist(ledger, record, 1, "{\"a\":1}")
  let assert Ok(_) = link.persist(ledger, record, 2, "{\"a\":2}")
  let assert Ok(_) = link.ack(ledger, record, 1)
  let assert Ok(found) = link.find(ledger, "s") |> option.to_result(Nil)
  found.out_seq |> should.equal(2)
  link.pending(ledger, found) |> should.equal([#(2, "{\"a\":2}")])
  let assert Ok(_) = link.forget(ledger, found)
  link.find(ledger, "s") |> should.equal(option.None)
  store.close(ledger)
}
