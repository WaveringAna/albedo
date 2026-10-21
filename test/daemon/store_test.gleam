//// Snapshot isolation and connection-owner death need gates inside store callbacks.
//// HTTP tests cannot stop an individual connection owner or interleave snapshot reads.

import albedo/daemon/store
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/list
import gleam/uri
import gleeunit/should
import sqlight

@external(erlang, "albedo_runtime_test_support", "temporary_database")
fn temporary_database() -> String

@external(erlang, "albedo_runtime_test_support", "cleanup")
fn cleanup(path: String) -> Nil

const schema =
  "CREATE TABLE samples(value INTEGER); INSERT INTO samples VALUES(1);"

fn count(connection: sqlight.Connection) -> Result(Int, String) {
  store.one(
    connection,
    "SELECT COUNT(*) FROM samples",
    [],
    decode.field(0, decode.int, decode.success),
    "count missing",
  )
}

pub fn a_query_on_a_stopped_store_fails_at_once_test() -> Nil {
  let assert Ok(db) = store.start(":memory:", "")
  store.close(db)
  let caller =
    process.spawn_unlinked(fn() {
      store.query(db, fn(_) { Nil })
      Nil
    })
  let monitor = process.monitor(caller)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(1000)
    as "the caller is still waiting on a stopped store"
  Nil
}

pub fn memory_snapshot_is_read_only_and_serialized_test() -> Nil {
  let assert Ok(database) = store.start(":memory:", schema)
  let assert Error(_) =
    store.snapshot(database, fn(connection) {
      store.exec(connection, "INSERT INTO samples VALUES(2)")
    })
  store.snapshot(database, count) |> should.equal(Ok(1))
  store.write(database, "INSERT INTO samples VALUES(2)", [])
  |> should.equal(Ok(Nil))
  store.snapshot(database, count) |> should.equal(Ok(2))
  store.close(database)
}

pub fn file_snapshot_keeps_one_read_transaction_test() -> Nil {
  let path = temporary_database()
  let assert Ok(database) = store.start(path, schema)
  let entered = process.new_subject()
  let release_ready = process.new_subject()
  let finished = process.new_subject()
  let result = process.new_subject()
  process.spawn_unlinked(fn() {
    let value =
      store.snapshot(database, fn(connection) {
        let assert Ok(before) = count(connection)
        process.send(entered, Nil)
        let gate = process.new_subject()
        process.send(release_ready, gate)
        let assert Ok(Nil) = process.receive(gate, 1000)
        let assert Ok(after) = count(connection)
        #(before, after)
      })
    process.send(result, value)
    process.send(finished, Nil)
  })
  let assert Ok(Nil) = process.receive(entered, 1000)
  let writer_done = process.new_subject()
  process.spawn_unlinked(fn() {
    let result = store.write(database, "INSERT INTO samples VALUES(2)", [])
    process.send(writer_done, result)
  })
  let assert Ok(Ok(Nil)) = process.receive(writer_done, 1000)
  let assert Ok(gate) = process.receive(release_ready, 1000)
  process.send(gate, Nil)
  let assert Ok(#(1, 1)) = process.receive(result, 1000)
  let assert Ok(Nil) = process.receive(finished, 1000)
  store.close(database)
  cleanup(path)
}

pub fn stopped_file_store_ends_snapshot_waiter_test() -> Nil {
  let path = temporary_database()
  let assert Ok(database) = store.start(path, "")
  store.close(database)
  let caller =
    process.spawn_unlinked(fn() {
      store.snapshot(database, fn(_) { Nil })
      Nil
    })
  let monitor = process.monitor(caller)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(1000)
    as "the snapshot caller is still waiting"
  cleanup(path)
}

pub fn connection_owner_death_stops_the_whole_store_test() -> Nil {
  list.each([True, False], fn(reader_stops) {
    let path = temporary_database()
    let assert Ok(database) = store.start(path, schema)
    let writer = store.owner(database)
    process.unlink(writer)
    let readers =
      list.map(list.repeat(Nil, 4), fn(_) {
        store.snapshot(database, fn(_) { process.self() })
      })
    let monitors = list.map([writer, ..readers], process.monitor)
    process.spawn_unlinked(fn() {
      case reader_stops {
        True ->
          store.snapshot(database, fn(_) { process.send_exit(process.self()) })
        False ->
          store.query(database, fn(_) { process.send_exit(process.self()) })
      }
    })
    list.each(monitors, fn(monitor) {
      let assert Ok(_) =
        process.new_selector()
        |> process.select_specific_monitor(monitor, fn(down) { down })
        |> process.selector_receive(1000)
        as "connection owner survived store failure"
    })
    cleanup(path)
  })
}

pub fn file_uri_uses_the_same_database_for_readers_test() -> Nil {
  let path = temporary_database() <> " ?#"
  let assert Ok(database) =
    store.start("file:" <> uri.percent_encode(path), schema)
  store.snapshot(database, count) |> should.equal(Ok(1))
  let assert Error(_) =
    store.snapshot(database, fn(db) {
      store.exec(db, "PRAGMA query_only=OFF; INSERT INTO samples VALUES(2)")
    })
  store.snapshot(database, count) |> should.equal(Ok(1))
  let assert Error(_) =
    store.read(
      database,
      "INSERT INTO samples VALUES(2) RETURNING value",
      [],
      decode.dynamic,
    )
  store.read(
    database,
    "SELECT COUNT(*) FROM samples",
    [],
    decode.field(0, decode.int, decode.success),
  )
  |> should.equal(Ok([1]))
  store.close(database)
  cleanup(path)
}
