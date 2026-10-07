//// Concurrent revision updates must have exactly one winner.
//// Two writes at one revision force the race that E2E cannot reliably order.
//// Empty workspace scopes are rejected by HTTP admission before reaching SQL.

import albedo/daemon/store
import albedo/harness/extensions/work/ledger as work
import gleam/erlang/process
import gleam/option.{None}

pub fn only_one_concurrent_edit_wins_test() -> Nil {
  let assert Ok(store) = store.start(":memory:", "")
  let assert Ok(_) = work.initialise(store)
  let assert Ok(item) = work.create(store, "/cwd", "original", "", None)
  let reply = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      process.send(
        reply,
        work.update(store, "/cwd", work.Item(..item, title: "human")),
      )
    })
  let _ =
    process.spawn_unlinked(fn() {
      process.send(
        reply,
        work.update(store, "/cwd", work.Item(..item, title: "agent")),
      )
    })
  let assert Ok(a) = process.receive(reply, 5000)
  let assert Ok(b) = process.receive(reply, 5000)
  case a, b {
    Ok(_), Error(work.Conflict) | Error(work.Conflict), Ok(_) -> Nil
    _, _ -> panic as "exactly one edit must win"
  }
  store.close(store)
}

pub fn empty_workspace_is_not_a_ledger_scope_test() -> Nil {
  let assert Ok(store) = store.start(":memory:", "")
  let assert Ok(_) = work.initialise(store)
  let assert Error(work.Invalid(_)) = work.list(store, "", 0, 10)
  store.close(store)
}
