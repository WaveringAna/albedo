//// The worker's tolerant calls: a stalled or dead session actor is an answer,
//// not a crash. E2E cannot stall the session actor on cue.

import albedo/daemon/session_run
import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import gleeunit/should

type Ping {
  Ping(reply: Subject(String))
  Die
}

fn server(mode: fn(message) -> actor.Next(Nil, message)) -> Subject(message) {
  let assert Ok(started) =
    actor.new(Nil)
    |> actor.on_message(fn(_, message) { mode(message) })
    |> actor.start
  started.data
}

fn answers(message: Ping) -> actor.Next(Nil, Ping) {
  case message {
    Ping(reply) -> {
      process.send(reply, "pong")
      actor.continue(Nil)
    }
    _ -> actor.continue(Nil)
  }
}

fn never_replies(_message: Ping) -> actor.Next(Nil, Ping) {
  actor.continue(Nil)
}

fn dies_on_call(message: Ping) -> actor.Next(Nil, Ping) {
  case message {
    Die -> actor.stop()
    _ -> actor.continue(Nil)
  }
}

pub fn a_reply_in_time_is_some_test() {
  let subject = server(answers)
  session_run.try_call(subject, 2000, Ping)
  |> should.equal(Ok("pong"))
}

pub fn a_stalled_callee_reports_a_timeout_test() {
  let subject = server(never_replies)
  session_run.try_call(subject, 20, Ping)
  |> should.equal(Error(session_run.TimedOut))
}

pub fn a_dead_callee_reports_the_death_test() {
  let subject = server(dies_on_call)
  session_run.try_call(subject, 2000, fn(_reply) { Die })
  |> should.equal(Error(session_run.CalleeDown))
}

pub fn a_reply_that_races_the_callee_exit_still_arrives_test() {
  let subject =
    server(fn(message) {
      case message {
        Ping(reply) -> {
          process.send(reply, "last words")
          actor.stop()
        }
        _ -> actor.continue(Nil)
      }
    })
  session_run.try_call(subject, 2000, Ping)
  |> should.equal(Ok("last words"))
}

/// A stand-in for the session actor's protocol.
type Owner {
  Publish(reply: Subject(Bool))
  Unused
}

fn messages() -> session_run.Messages(Owner) {
  session_run.Messages(
    publish: fn(_, _, reply) { Publish(reply) },
    commit: fn(_, _, _, _, _) { Unused },
    context: fn(_, _, _) { Unused },
    usage: fn(_, _, _) { Unused },
    drain: fn(_, _) { Unused },
    pin: fn(_, _, _) { Unused },
    finished: fn(_, _) { Unused },
    collect: Unused,
  )
}

fn publish(owner: Subject(Owner)) -> Bool {
  session_run.publish_fn(owner, "run", messages(), waiting: 20)("event")
}

pub fn publish_passes_the_owner_answer_through_test() {
  let answering = fn(keep_going) {
    server(fn(message) {
      case message {
        Publish(reply) -> process.send(reply, keep_going)
        Unused -> Nil
      }
      actor.continue(Nil)
    })
  }
  answering(True) |> publish |> should.be_true
  answering(False) |> publish |> should.be_false
}

pub fn publish_keeps_streaming_through_a_stalled_owner_test() {
  server(fn(_) { actor.continue(Nil) })
  |> publish
  |> should.be_true
}

pub fn publish_stops_the_stream_when_the_owner_dies_test() {
  server(fn(_) { actor.stop() })
  |> publish
  |> should.be_false
}
