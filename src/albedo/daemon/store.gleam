//// One connection owner. All queries and transactions run in this process.

import albedo/clock
import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/io
import gleam/list
import gleam/otp/actor
import gleam/result
import gleam/string
import sqlight

/// A query holding the store this long is logged with its caller: every
/// other caller waits behind it.
const slow_ms = 2000

pub opaque type Store {
  Store(Subject(Message))
}

type Message {
  Run(caller: process.Pid, run: fn(sqlight.Connection) -> Nil)
  Close(Subject(Nil))
}

pub fn start(path: String, schema: String) -> Result(Store, actor.StartError) {
  actor.new_with_initialiser(5000, fn(subject) {
    label("albedo_store", path)
    use db <- result.try(sqlight.open(path) |> result.map_error(message))
    case exec(db, schema) {
      Ok(_) -> Ok(actor.initialised(db) |> actor.returning(Store(subject)))
      Error(error) -> {
        let _ = sqlight.close(db)
        Error(error)
      }
    }
  })
  |> actor.on_message(fn(db, message) {
    case message {
      Run(caller, run) -> {
        let began = clock.monotonic_ms()
        run(db)
        let held = clock.monotonic_ms() - began
        case held >= slow_ms {
          True ->
            io.println_error(
              "store: one query held the store "
              <> int.to_string(held)
              <> " ms for "
              <> string.inspect(caller_label(caller)),
            )
          False -> Nil
        }
        // A transcript load leaves every decoded row on this heap; the store
        // then idles and would hold that garbage indefinitely.
        collect_over(131_072)
        actor.continue(db)
      }
      Close(reply) -> {
        let _ = sqlight.close(db)
        process.send(reply, Nil)
        actor.stop()
      }
    }
  })
  |> actor.start
  |> result.map(fn(started) { started.data })
}

pub fn owner(store: Store) -> process.Pid {
  let Store(subject) = store
  let assert Ok(pid) = process.subject_owner(subject)
  pid
}

pub fn close(store: Store) -> Nil {
  let Store(subject) = store
  actor.call(subject, 5000, Close)
}

/// The result of `run` in the store. A queued `run` executes even after its
/// caller stopped waiting, so a deadline would report a failure for work that
/// still happens: the caller waits as long as the store is alive.
pub fn query(store: Store, run: fn(sqlight.Connection) -> a) -> a {
  let Store(subject) = store
  let assert Ok(owner) = process.subject_owner(subject)
  let monitor = process.monitor(owner)
  let reply = process.new_subject()
  process.send(
    subject,
    Run(process.self(), fn(db) { process.send(reply, run(db)) }),
  )
  let answer =
    process.new_selector()
    |> process.select_map(reply, Ok)
    |> process.select_specific_monitor(monitor, fn(_) { Error(Nil) })
    |> process.selector_receive_forever
  process.demonitor_process(monitor)
  let assert Ok(value) = answer as "the store stopped"
  value
}

/// Runs one statement in the store for its effect.
pub fn write(
  store: Store,
  sql: String,
  arguments: List(sqlight.Value),
) -> Result(Nil, String) {
  query(store, run(_, sql, arguments))
}

/// Reads rows in the store.
pub fn read(
  store: Store,
  sql: String,
  arguments: List(sqlight.Value),
  decoder: decode.Decoder(a),
) -> Result(List(a), String) {
  query(store, rows(_, sql, arguments, decoder))
}

/// Runs one or more statements that return nothing, such as a schema.
pub fn exec(db: sqlight.Connection, sql: String) -> Result(Nil, String) {
  sqlight.exec(sql, db) |> result.map_error(message)
}

/// Runs one statement for its effect, discarding any rows it returns.
pub fn run(
  db: sqlight.Connection,
  sql: String,
  arguments: List(sqlight.Value),
) -> Result(Nil, String) {
  rows(db, sql, arguments, decode.dynamic) |> result.replace(Nil)
}

/// Deletes the rows `tables` keep for `session`: the cleanup an extension
/// that owns session-keyed tables registers with a `CleanPlugin`.
pub fn forget_session(
  db: sqlight.Connection,
  tables: List(String),
  session: String,
) -> Result(Nil, String) {
  list.try_each(tables, fn(table) {
    run(db, "DELETE FROM " <> table <> " WHERE session=?", [
      sqlight.text(session),
    ])
  })
}

pub fn rows(
  db: sqlight.Connection,
  sql: String,
  arguments: List(sqlight.Value),
  decoder: decode.Decoder(a),
) -> Result(List(a), String) {
  sqlight.query(sql, db, arguments, decoder) |> result.map_error(message)
}

/// The first row, or `missing` when there is none.
pub fn one(
  db: sqlight.Connection,
  sql: String,
  arguments: List(sqlight.Value),
  decoder: decode.Decoder(a),
  missing: String,
) -> Result(a, String) {
  use found <- result.try(rows(db, sql, arguments, decoder))
  list.first(found) |> result.replace_error(missing)
}

/// Runs `body` in one immediate transaction: committed when it succeeds,
/// rolled back when it fails.
pub fn transaction(
  db: sqlight.Connection,
  body: fn() -> Result(a, String),
) -> Result(a, String) {
  use _ <- result.try(exec(db, "BEGIN IMMEDIATE"))
  case body() {
    Ok(value) ->
      case exec(db, "COMMIT") {
        Ok(_) -> Ok(value)
        Error(error) -> {
          let _ = sqlight.exec("ROLLBACK", db)
          Error(error)
        }
      }
    Error(error) -> {
      let _ = sqlight.exec("ROLLBACK", db)
      Error(error)
    }
  }
}

/// Adds each `#(name, type)` column the table lacks: the only migration
/// these tables need.
pub fn add_columns(
  db: sqlight.Connection,
  table: String,
  columns: List(#(String, String)),
) -> Result(Nil, String) {
  use present <- result.try(rows(
    db,
    "PRAGMA table_info(" <> table <> ")",
    [],
    decode.field(1, decode.string, decode.success),
  ))
  columns
  |> list.filter(fn(column) { !list.contains(present, column.0) })
  |> list.try_each(fn(column) {
    exec(
      db,
      "ALTER TABLE " <> table <> " ADD COLUMN " <> column.0 <> " " <> column.1,
    )
  })
}

fn message(error: sqlight.Error) -> String {
  error.message
}

@external(erlang, "albedo_inspect", "label")
fn label(kind: String, id: String) -> Nil

@external(erlang, "albedo_session", "collect_over")
fn collect_over(words: Int) -> Nil

@external(erlang, "proc_lib", "get_label")
fn caller_label(pid: process.Pid) -> dynamic.Dynamic
