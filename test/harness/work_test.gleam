//// Concurrent revision updates must have exactly one winner.

import albedo/harness/extensions/work/ledger as work
import gleam/erlang/process
import gleam/option.{None}

pub fn only_one_concurrent_edit_wins_test() {
  let assert Ok(store) = work.start(":memory:")
  let assert Ok(item) = work.create(store, "original", "", None)
  let reply = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      process.send(reply, work.update(store, work.Item(..item, title: "human")))
    })
  let _ =
    process.spawn_unlinked(fn() {
      process.send(reply, work.update(store, work.Item(..item, title: "agent")))
    })
  let assert Ok(a) = process.receive(reply, 5000)
  let assert Ok(b) = process.receive(reply, 5000)
  case a, b {
    Ok(_), Error(work.Conflict) | Error(work.Conflict), Ok(_) -> Nil
    _, _ -> panic as "exactly one edit must win"
  }
  work.close(store)
}
