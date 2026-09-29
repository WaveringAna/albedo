//// The worker's tolerant calls: a stalled or dead session actor is an answer,
//// not a crash. E2E cannot stall the session actor on cue.

import albedo/daemon/conversation
import albedo/daemon/session_run
import albedo/daemon/turn
import albedo/daemon/usage
import gleam/erlang/process.{type Subject}
import gleam/option.{None}
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
  Commit(reply: Subject(Result(#(Int, option.Option(Int)), String)))
  Commits(reply: Subject(Int))
  Unused
}

fn messages() -> session_run.Messages(Owner) {
  session_run.Messages(
    publish: fn(_, _, reply) { Publish(reply) },
    commit: fn(_, _, _, _, reply) { Commit(reply) },
    context: fn(_, _, _, _) { Unused },
    usage: fn(_, _, _) { Unused },
    drain: fn(_, _) { Unused },
    pin: fn(_, _, _) { Unused },
    sent: fn(_, _, _) { Unused },
    finished: fn(_, _) { Unused },
    collect: Unused,
  )
}

fn publish(owner: Subject(Owner)) -> Bool {
  publish_after(owner, turn.latch())
}

fn publish_after(owner: Subject(Owner), stop: turn.Latch) -> Bool {
  session_run.publish_fn(owner, "run", messages(), stop, waiting: 20)("event")
}

pub fn publish_passes_the_owner_answer_through_test() {
  let answering = fn(keep_going) {
    server(fn(message) {
      case message {
        Publish(reply) -> process.send(reply, keep_going)
        _ -> Nil
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

/// A cancelled session actor that stalls must not let a tool gate open: the
/// kernel interrupt cannot stop a tool outside the kernel.
pub fn publish_fails_closed_on_a_stall_once_cancelled_test() {
  let pid = process.spawn(fn() { Nil })
  let assert turn.Running(run) =
    turn.Running(turn.Run(
      "run",
      pid,
      process.monitor(pid),
      False,
      turn.latch(),
      turn.Turn(None),
    ))
    |> turn.cancel
  server(fn(_) { actor.continue(Nil) })
  |> publish_after(run.stop)
  |> should.be_false
}

pub fn publish_stops_the_stream_when_the_owner_dies_test() {
  server(fn(_) { actor.stop() })
  |> publish
  |> should.be_false
}

fn commit(owner: Subject(Owner)) -> Result(#(Int, option.Option(Int)), String) {
  session_run.commit_fn(owner, "run", messages(), waiting: 20)(
    [],
    conversation.Tool,
    None,
  )
}

pub fn a_dead_owner_ends_the_turn_instead_of_the_worker_test() {
  let dies = fn() { server(fn(_) { actor.stop() }) }
  commit(dies())
  |> should.equal(Error("commit unconfirmed: the session stopped"))
  session_run.usage_fn(dies(), "run", messages(), waiting: 20)(usage.Metadata(
    "model",
    0,
    None,
    None,
  ))
  |> should.equal(Error("usage unconfirmed: the session stopped"))
  session_run.drain_fn(dies(), "run", messages(), waiting: 20)()
  |> should.equal(Error("steering unconfirmed: the session stopped"))
}

/// A stalled commit may still land, so it must be sent exactly once.
pub fn a_stalled_commit_ends_the_turn_without_a_retry_test() {
  let assert Ok(started) =
    actor.new(0)
    |> actor.on_message(fn(commits, message) {
      case message {
        Commit(_) -> actor.continue(commits + 1)
        Commits(reply) -> {
          process.send(reply, commits)
          actor.continue(commits)
        }
        _ -> actor.continue(commits)
      }
    })
    |> actor.start
  commit(started.data)
  |> should.equal(Error(
    "commit unconfirmed after a session stall; it may still be saved",
  ))
  actor.call(started.data, 1000, Commits) |> should.equal(1)
}
