//// Clock-dependent schedule advancement must not emit duplicate due turns.

import albedo/daemon/store
import albedo/harness/extensions/schedule/ledger
import gleam/option.{None, Some}
import gleeunit/should
import sqlight

pub fn schedules_are_session_scoped_and_advance_once_test() -> Nil {
  let assert Ok(db) =
    store.start(
      ":memory:",
      "CREATE TABLE sessions(id TEXT PRIMARY KEY); INSERT INTO sessions VALUES('a'),('b');",
    )
  let assert Ok(_) = ledger.initialise(db)
  let assert Ok(first) =
    ledger.save(db, "a", None, "recurring", "inspect", 60, Some(60))
  let assert Ok(one) = ledger.save(db, "b", None, "once", "check", 60, None)
  let assert Ok([listed]) = ledger.list(db, "a")
  listed |> should.equal(first)
  ledger.delete(db, "b", first.id) |> should.equal(Ok(False))
  let assert Ok([]) = ledger.due(db, first.next_at - 1)
  let assert Ok([_, _]) = ledger.due(db, first.next_at)
  ledger.advance(db, first, first.next_at + 180) |> should.equal(Ok(Nil))
  let assert Ok(advanced) = ledger.get(db, "a", first.id)
  advanced.next_at |> should.equal(first.next_at + 240)
  ledger.advance(db, one, one.next_at) |> should.equal(Ok(Nil))
  ledger.get(db, "b", one.id) |> should.be_error
  store.query(db, fn(connection) {
    sqlight.exec(
      "PRAGMA foreign_keys=ON; DELETE FROM sessions WHERE id='a';",
      connection,
    )
  })
  |> should.be_ok
  ledger.list(db, "a") |> should.equal(Ok([]))
  store.close(db)
}
