//// The worker's tolerant call: a stalled or dead callee is an answer, not a crash.

import albedo/daemon/session_run
import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import gleeunit/should

type Ping {
  Ping(reply: Subject(String))
  Die
}

fn server(mode: fn(Ping) -> actor.Next(Nil, Ping)) -> Subject(Ping) {
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

pub fn the_stream_fails_open_on_a_stall_and_closed_on_a_dead_owner_test() {
  session_run.keep_streaming(Ok(True)) |> should.be_true
  session_run.keep_streaming(Ok(False)) |> should.be_false
  session_run.keep_streaming(Error(session_run.TimedOut)) |> should.be_true
  session_run.keep_streaming(Error(session_run.CalleeDown)) |> should.be_false
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
