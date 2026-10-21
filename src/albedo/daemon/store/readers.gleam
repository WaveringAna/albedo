//// Read admission runs separately from the ordered writer.

import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import sqlight

const connection_count = 4

pub opaque type Pool {
  Pool(Subject(Message))
}

type Message {
  Read(run: fn(sqlight.Connection) -> Nil)
  Available(Subject(ReaderMessage))
  Close(Subject(Nil))
  OwnerStopped
  ReaderStopped
}

type ReaderMessage {
  Run(run: fn(sqlight.Connection) -> Nil, completed: fn() -> Nil)
  Stop(Subject(Nil))
}

type State {
  State(
    self: Subject(Message),
    readers: List(Subject(ReaderMessage)),
    idle: List(Subject(ReaderMessage)),
    front: List(fn(sqlight.Connection) -> Nil),
    back: List(fn(sqlight.Connection) -> Nil),
    closing: Option(Subject(Nil)),
  )
}

pub fn start(path: String) -> Result(Pool, String) {
  let writer = process.self()
  actor.new_with_initialiser(5000, fn(self) {
    use readers <- result.try(open(path, connection_count, []))
    let selector =
      list.fold(
        readers,
        process.new_selector()
          |> process.select(self)
          |> process.select_specific_monitor(process.monitor(writer), fn(_) {
            OwnerStopped
          }),
        fn(selector, reader) {
          let assert Ok(pid) = process.subject_owner(reader)
          process.select_specific_monitor(selector, process.monitor(pid), fn(_) {
            ReaderStopped
          })
        },
      )
    Ok(
      actor.initialised(State(self, readers, readers, [], [], None))
      |> actor.selecting(selector)
      |> actor.returning(Pool(self)),
    )
  })
  |> actor.on_message(handle)
  |> actor.start
  |> result.map(fn(started) { started.data })
  |> result.map_error(string.inspect)
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    OwnerStopped -> actor.stop_abnormal("storage writer stopped")
    ReaderStopped -> actor.stop_abnormal("storage reader stopped")
    Read(work) ->
      case state.closing, state.idle {
        Some(_), _ -> actor.continue(state)
        None, [reader, ..idle] -> {
          dispatch(state.self, reader, work)
          actor.continue(State(..state, idle: idle))
        }
        None, [] -> actor.continue(State(..state, back: [work, ..state.back]))
      }
    Available(reader) -> {
      let #(front, back) = case state.front {
        [] -> #(list.reverse(state.back), [])
        _ -> #(state.front, state.back)
      }
      case front {
        [work, ..rest] -> {
          dispatch(state.self, reader, work)
          actor.continue(State(..state, front: rest, back: back))
        }
        [] ->
          settle(
            State(
              ..state,
              idle: list.append(state.idle, [reader]),
              front: [],
              back: [],
            ),
          )
      }
    }
    Close(reply) -> settle(State(..state, closing: Some(reply)))
  }
}

fn settle(state: State) -> actor.Next(State, Message) {
  case state.closing, list.length(state.idle) == connection_count {
    Some(reply), True -> {
      close_readers(state.readers)
      process.send(reply, Nil)
      actor.stop()
    }
    _, _ -> actor.continue(state)
  }
}

fn dispatch(
  pool: Subject(Message),
  reader: Subject(ReaderMessage),
  work: fn(sqlight.Connection) -> Nil,
) -> Nil {
  process.send(
    reader,
    Run(work, fn() { process.send(pool, Available(reader)) }),
  )
}

pub fn owner(pool: Pool) -> process.Pid {
  let Pool(subject) = pool
  let assert Ok(pid) = process.subject_owner(subject)
  pid
}

/// Queues a read-only callback and waits for its result.
pub fn run(pool: Pool, run: fn(sqlight.Connection) -> a) -> a {
  let Pool(subject) = pool
  let monitor = process.monitor(owner(pool))
  let reply = process.new_subject()
  process.send(subject, Read(fn(db) { process.send(reply, run(db)) }))
  let answer =
    process.new_selector()
    |> process.select_map(reply, Ok)
    |> process.select_specific_monitor(monitor, fn(_) { Error(Nil) })
    |> process.selector_receive_forever
  process.demonitor_process(monitor)
  let assert Ok(value) = answer as "the store stopped"
  value
}

pub fn close(pool: Pool) -> Nil {
  let Pool(subject) = pool
  actor.call(subject, 5000, Close)
}

fn open(
  path: String,
  remaining: Int,
  started: List(Subject(ReaderMessage)),
) -> Result(List(Subject(ReaderMessage)), String) {
  case remaining {
    0 -> Ok(list.reverse(started))
    _ ->
      case start_reader(path) {
        Ok(reader) -> open(path, remaining - 1, [reader, ..started])
        Error(reason) -> {
          close_readers(started)
          Error(reason)
        }
      }
  }
}

fn start_reader(path: String) -> Result(Subject(ReaderMessage), String) {
  actor.new_with_initialiser(5000, fn(subject) {
    use db <- result.try(
      sqlight.open(path) |> result.map_error(fn(error) { error.message }),
    )
    case sqlight.exec("PRAGMA query_only=ON; PRAGMA cache_size=-128", db) {
      Ok(_) -> Ok(actor.initialised(db) |> actor.returning(subject))
      Error(error) -> {
        let _ = sqlight.close(db)
        Error(error.message)
      }
    }
  })
  |> actor.on_message(fn(db, message) {
    case message {
      Run(run, completed) -> {
        run(db)
        collect_over(131_072)
        completed()
        actor.continue(db)
      }
      Stop(reply) -> {
        let _ = sqlight.close(db)
        process.send(reply, Nil)
        actor.stop()
      }
    }
  })
  |> actor.start
  |> result.map(fn(started) { started.data })
  |> result.map_error(string.inspect)
}

fn close_readers(readers: List(Subject(ReaderMessage))) -> Nil {
  let replies =
    list.map(readers, fn(reader) {
      let reply = process.new_subject()
      process.send(reader, Stop(reply))
      reply
    })
  list.each(replies, fn(reply) { process.receive_forever(reply) })
}

@external(erlang, "albedo_session", "collect_over")
fn collect_over(words: Int) -> Nil
