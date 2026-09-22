import albedo/harness/extensions/work/ledger as work
import gleam/erlang/process
import gleam/option.{None, Some}
import gleeunit/should

pub fn revisions_and_hierarchy_test() {
  let assert Ok(store) = work.start(":memory:")
  let assert Ok(parent) = work.create(store, "fix cancellation", "", None)
  let assert Ok(child) =
    work.create(store, "add regression", "", Some(parent.id))
  let assert Ok(updated) =
    work.update(
      store,
      work.Item(..child, status: work.Active, notes: "working"),
    )
  updated.revision |> should.equal(2)
  work.update(store, child) |> should.equal(Error(work.Conflict))
  work.update(store, work.Item(..updated, run: Some("run"))) |> should.be_error
  work.update(store, work.Item(..updated, parent: None)) |> should.be_error
  work.create(store, "", "", None) |> should.be_error
  work.create(store, "missing parent", "", Some(999)) |> should.be_error
  let assert Ok(items) = work.list(store, parent.id, 1)
  items |> should.equal([updated])
  work.close(store)
}

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
