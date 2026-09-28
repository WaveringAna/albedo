//// One connection owner. All queries and transactions run in this process.

import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/actor
import gleam/result
import sqlight

pub opaque type Store {
  Store(Subject(Message))
}

type Message {
  Run(fn(sqlight.Connection) -> Nil)
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
      Run(run) -> {
        run(db)
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

pub fn query(store: Store, run: fn(sqlight.Connection) -> a) -> a {
  let Store(subject) = store
  actor.call(subject, 10_000, fn(reply) {
    Run(fn(db) { process.send(reply, run(db)) })
  })
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
    Ok(value) -> exec(db, "COMMIT") |> result.replace(value)
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
