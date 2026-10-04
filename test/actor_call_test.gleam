//// Timeout and reply/death ordering require process monitors and controlled
//// acknowledgments that the external E2E API cannot arrange.

import albedo/actor_call
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

pub fn a_reply_in_time_is_returned_test() -> Nil {
  let subject = server(answers)
  actor_call.try_call(subject, 2000, Ping)
  |> should.equal(Ok("pong"))
}

pub fn a_stalled_callee_reports_a_timeout_test() -> Nil {
  let subject = server(never_replies)
  actor_call.try_call(subject, 20, Ping)
  |> should.equal(Error(actor_call.TimedOut))
}

pub fn a_dead_callee_reports_the_death_test() -> Nil {
  let subject = server(dies_on_call)
  actor_call.try_call(subject, 2000, fn(_reply) { Die })
  |> should.equal(Error(actor_call.CalleeDown))
}

pub fn a_reply_that_races_the_callee_exit_still_arrives_test() -> Nil {
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
  actor_call.try_call(subject, 2000, Ping)
  |> should.equal(Ok("last words"))
}

pub fn an_unregistered_named_callee_reports_death_test() -> Nil {
  let subject =
    process.new_name("actor_call_test_missing") |> process.named_subject
  actor_call.try_call(subject, 2000, Ping)
  |> should.equal(Error(actor_call.CalleeDown))
}

pub fn finite_calls_remove_monitors_and_down_messages_test() -> Nil {
  let before = monitor_state()
  let replying = server(answers)
  actor_call.try_call(replying, 2000, Ping) |> should.equal(Ok("pong"))
  monitor_state() |> should.equal(before)
  let stalled = server(never_replies)
  actor_call.try_call(stalled, 20, Ping)
  |> should.equal(Error(actor_call.TimedOut))
  monitor_state() |> should.equal(before)
  let dying = server(dies_on_call)
  actor_call.try_call(dying, 2000, fn(_) { Die })
  |> should.equal(Error(actor_call.CalleeDown))
  monitor_state() |> should.equal(before)
}

@external(erlang, "albedo_actor_call_test_support", "monitor_state")
fn monitor_state() -> #(Int, Int)
