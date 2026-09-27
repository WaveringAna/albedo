//// Concurrent revision updates must have exactly one winner.

import albedo/harness/extensions/work/ledger as work
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/option.{None, Some}
import sqlight

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

@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int

@external(erlang, "albedo_session", "discard")
fn discard(path: String) -> Nil

pub fn old_schema_migrates_before_cwd_index_test() {
  let path =
    "/tmp/albedo-work-legacy-" <> int.to_string(unique_integer()) <> ".db"
  let assert Ok(db) = sqlight.open(path)
  let assert Ok(_) =
    sqlight.exec(
      "CREATE TABLE work (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, notes TEXT NOT NULL DEFAULT '', status TEXT NOT NULL DEFAULT 'open', parent INTEGER, session TEXT, run TEXT, revision INTEGER NOT NULL DEFAULT 1, created_at TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL DEFAULT '')",
      db,
    )
  let assert Ok(_) =
    sqlight.exec("INSERT INTO work(title) VALUES('legacy')", db)
  let assert Ok(_) = sqlight.close(db)
  let assert Ok(store) = work.start(path)
  let assert Ok(_) = work.initialise(store)
  work.close(store)
  let assert Ok(check) = sqlight.open(path)
  let assert Ok([title]) =
    sqlight.query(
      "SELECT title FROM work",
      check,
      [],
      decode.field(0, decode.string, decode.success),
    )
  let assert True = title == "legacy"
  let assert Ok([cwd]) =
    sqlight.query(
      "SELECT cwd FROM work",
      check,
      [],
      decode.field(0, decode.string, decode.success),
    )
  let assert True = cwd == "__albedo_legacy__"
  let assert Ok([index]) =
    sqlight.query(
      "SELECT name FROM sqlite_master WHERE type='index' AND name='work_cwd_id'",
      check,
      [],
      decode.field(0, decode.string, decode.success),
    )
  let assert True = index == "work_cwd_id"
  let assert Ok(_) = sqlight.close(check)
  discard(path)
}
