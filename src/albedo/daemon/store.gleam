//// One connection owner. All queries and transactions run in this process.

import gleam/erlang/process.{type Subject}
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
    use db <- result.try(
      sqlight.open(path) |> result.map_error(fn(e) { e.message }),
    )
    case sqlight.exec(schema, db) {
      Ok(_) -> Ok(actor.initialised(db) |> actor.returning(Store(subject)))
      Error(e) -> {
        let _ = sqlight.close(db)
        Error(e.message)
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

@external(erlang, "albedo_inspect", "label")
fn label(kind: String, id: String) -> Nil

@external(erlang, "albedo_session", "collect_over")
fn collect_over(words: Int) -> Nil
