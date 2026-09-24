import albedo/daemon/store
import albedo/harness/command.{Data, ModelCall, UserCall}
import albedo/harness/extensions/schedule/extension as schedule
import albedo/harness/extensions/schedule/ledger
import gleam/dict
import gleam/int
import gleam/option.{None, Some}
import gleeunit/should
import sqlight

pub fn schedules_are_session_scoped_and_advance_once_test() {
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

pub fn both_callers_can_manage_heartbeats_test() {
  let assert Ok(db) =
    store.start(
      ":memory:",
      "CREATE TABLE sessions(id TEXT PRIMARY KEY); INSERT INTO sessions VALUES('a');",
    )
  let assert Ok(_) = ledger.initialise(db)
  let cmd = schedule.command(db, "a")
  let context =
    command.Context(fn(_) { panic as "schedule must not submit a turn" })
  let assert Ok(Data(_)) =
    command.call(
      [cmd],
      context,
      ModelCall,
      "kernel",
      "/schedule",
      dict.new(),
      "heartbeat every:300 review the work",
    )
  let assert Ok([heartbeat]) = ledger.list(db, "a")
  heartbeat.kind |> should.equal("heartbeat")
  let assert Ok(Data(_)) =
    command.call(
      [cmd],
      context,
      UserCall,
      "cli",
      "/schedule",
      dict.new(),
      "edit " <> int.to_string(heartbeat.id) <> " every:600 check again",
    )
  let assert Ok(updated) = ledger.get(db, "a", heartbeat.id)
  updated.kind |> should.equal("heartbeat")
  updated.every |> should.equal(Some(600))
  let assert Error(_) =
    command.call(
      [cmd],
      context,
      ModelCall,
      "kernel",
      "/schedule",
      dict.new(),
      "heartbeat in:60 no",
    )
  let assert Error(_) =
    command.call(
      [cmd],
      context,
      ModelCall,
      "kernel",
      "/schedule",
      dict.new(),
      "add every:1 too fast",
    )
  let assert Ok(Data(_)) =
    command.call(
      [cmd],
      context,
      ModelCall,
      "kernel",
      "/schedule",
      dict.new(),
      "delete " <> int.to_string(heartbeat.id),
    )
  ledger.list(db, "a") |> should.equal(Ok([]))
  store.close(db)
}
