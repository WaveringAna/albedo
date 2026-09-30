//// Concurrent revision updates must have exactly one winner.

import albedo/harness/extensions/work/ledger as work
import gleam/erlang/process
import gleam/option.{None, Some}

pub fn only_one_concurrent_edit_wins_test() {
  let assert Ok(store) = work.start(":memory:")
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
  work.close(store)
}

pub fn ledger_items_are_scoped_to_cwd_test() {
  let assert Ok(store) = work.start(":memory:")
  let assert Ok(first) = work.create(store, "/one", "first", "", None)
  let assert Ok(second) = work.create(store, "/two", "second", "", None)
  let assert Error(work.NotFound) = work.get(store, "/two", first.id)
  let assert Error(work.NotFound) = work.update(store, "/two", first)
  let assert Error(work.NotFound) =
    work.delete(store, "/two", first.id, first.revision)
  let assert Ok([only_first]) = work.list(store, "/one", 0, 10)
  let assert True = only_first.id == first.id
  let assert Ok([only_second]) = work.list(store, "/two", 0, 10)
  let assert True = only_second.id == second.id
  let assert Error(work.NotFound) =
    work.create(store, "/two", "child", "", Some(first.id))
  let assert Error(work.Invalid(_)) = work.list(store, "", 0, 10)
  work.close(store)
}
