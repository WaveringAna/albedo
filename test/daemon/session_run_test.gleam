//// Worker call timeouts and helper cleanup require acknowledgment races and
//// process monitors that the external E2E API cannot control.

import albedo/daemon/conversation
import albedo/daemon/events
import albedo/daemon/session_run
import albedo/daemon/turn
import albedo/daemon/usage
import albedo/harness/extension
import albedo/openai_api/types
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None}
import gleam/otp/actor
import gleeunit/should

fn server(mode: fn(message) -> actor.Next(Nil, message)) -> Subject(message) {
  let assert Ok(started) =
    actor.new(Nil)
    |> actor.on_message(fn(_, message) { mode(message) })
    |> actor.start
  started.data
}

/// A stand-in for the session actor's protocol.
type Owner {
  Publish(reply: Subject(Bool))
  Progress(reply: Subject(Bool))
  Commit(reply: Subject(Result(#(Int, option.Option(Int)), String)))
  Commits(reply: Subject(Int))
  Unused
}

fn messages() -> session_run.Messages(Owner) {
  session_run.Messages(
    publish: fn(_, _, reply) { Publish(reply) },
    tool_progress_delta: fn(_, _, _, _, _, _, reply) { Progress(reply) },
    tool_progress_running: fn(_, _, _, _, _, _, reply) { Progress(reply) },
    tool_progress_reset: fn(_, _, _) { Unused },
    tool_progress_finish: fn(_, _, _) { Unused },
    commit: fn(_, _, _, _, reply) { Commit(reply) },
    fits: fn(_, _, _) { Unused },
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
  session_run.publish_fn(owner, "run", messages(), stop, waiting: 20)(
    events.Checkpoint,
  )
}

pub fn publish_passes_the_owner_answer_through_test() -> Nil {
  let answering = fn(keep_going) {
    server(fn(message) {
      case message {
        Publish(reply) -> process.send(reply, keep_going)
        _ -> Nil
      }
      actor.continue(Nil)
    })
  }
  list.each([True, False], fn(keep_going) {
    session_run.publish_fn(
      answering(keep_going),
      "run",
      messages(),
      turn.latch(),
      waiting: 2000,
    )(events.Checkpoint)
    |> should.equal(keep_going)
  })
}

pub fn publish_keeps_streaming_through_a_stalled_owner_test() -> Nil {
  server(fn(_) { actor.continue(Nil) })
  |> publish
  |> should.be_true
}

/// A cancelled session actor that stalls must not let a tool gate open: the
/// kernel interrupt cannot stop a tool outside the kernel.
pub fn publish_fails_closed_on_a_stall_once_cancelled_test() -> Nil {
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

pub fn publish_stops_the_stream_when_the_owner_dies_test() -> Nil {
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

pub fn a_dead_owner_ends_the_turn_instead_of_the_worker_test() -> Nil {
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
pub fn a_stalled_commit_ends_the_turn_without_a_retry_test() -> Nil {
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

fn cancel(stop: turn.Latch) -> Nil {
  let pid = process.self()
  let monitor = process.monitor(pid)
  let _ =
    turn.cancel(
      turn.Running(turn.Run("run", pid, monitor, False, stop, turn.Turn(None))),
    )
  process.demonitor_process(monitor)
}

pub fn progress_timeout_stops_delivery_at_the_first_fragment_test() -> Nil {
  let assert Ok(started) =
    actor.new(0)
    |> actor.on_message(fn(count, message) {
      case message {
        Progress(_) -> actor.continue(count + 1)
        Commits(reply) -> {
          process.send(reply, count)
          actor.continue(count)
        }
        _ -> actor.continue(count)
      }
    })
    |> actor.start
  let progress =
    session_run.tool_progress_delta_fn(
      started.data,
      "run",
      messages(),
      turn.latch(),
      waiting: 20,
    )
  // This is the transport's continuation rule: a refusal stops delivery.
  let continued = case progress(0, 1, 0, "python", "first") {
    True -> progress(0, 1, 0, "python", "second")
    False -> False
  }
  continued |> should.be_false
  actor.call(started.data, 1000, Commits) |> should.equal(1)
}

pub fn running_timeout_refuses_continuation_test() -> Nil {
  let owner = server(fn(_) { actor.continue(Nil) })
  session_run.tool_progress_running_fn(
    owner,
    "run",
    messages(),
    turn.latch(),
    waiting: 20,
  )(0, 1, 0, "tool", "python")
  |> should.be_false
}

pub fn cancelled_progress_sends_no_request_test() -> Nil {
  let assert Ok(started) =
    actor.new(0)
    |> actor.on_message(fn(count, message) {
      case message {
        Progress(reply) -> {
          process.send(reply, True)
          actor.continue(count + 1)
        }
        Commits(reply) -> {
          process.send(reply, count)
          actor.continue(count)
        }
        _ -> actor.continue(count)
      }
    })
    |> actor.start
  let owner = started.data
  let stop = turn.latch()
  cancel(stop)
  session_run.tool_progress_delta_fn(
    owner,
    "run",
    messages(),
    stop,
    waiting: 20,
  )(0, 1, 0, "python", "fragment")
  |> should.be_false
  session_run.tool_progress_running_fn(
    owner,
    "run",
    messages(),
    stop,
    waiting: 20,
  )(0, 1, 0, "tool", "python")
  |> should.be_false
  // The reply follows every request already sent by this process.
  actor.call(owner, 1000, Commits) |> should.equal(0)
}

pub fn cancellation_before_progress_acknowledgment_refuses_continuation_test() -> Nil {
  let stop = turn.latch()
  let owner =
    server(fn(message) {
      case message {
        Progress(reply) -> {
          cancel(stop)
          process.send(reply, True)
        }
        _ -> Nil
      }
      actor.continue(Nil)
    })
  session_run.tool_progress_delta_fn(
    owner,
    "run",
    messages(),
    stop,
    waiting: 1000,
  )(0, 1, 0, "python", "fragment")
  |> should.be_false
  let other_stop = turn.latch()
  let other_owner =
    server(fn(message) {
      case message {
        Progress(reply) -> {
          cancel(other_stop)
          process.send(reply, True)
        }
        _ -> Nil
      }
      actor.continue(Nil)
    })
  session_run.tool_progress_running_fn(
    other_owner,
    "run",
    messages(),
    other_stop,
    waiting: 1000,
  )(0, 1, 0, "tool", "python")
  |> should.be_false
}

fn idle_provider(started: Subject(process.Pid)) -> extension.Upstream {
  extension.Upstream(
    endpoint: "test",
    protocol: types.Responses,
    stream: fn(_, _) {
      let never = process.new_subject()
      process.send(started, process.self())
      let _: Nil = process.receive_forever(never)
      Error(types.Cancelled)
    },
    explain: fn(_) { None },
    account: fn() { None },
    cache_marks: fn(_) { [] },
    images: types.any_images,
  )
}

fn idle_provider_cleanup(owner_dies: Bool) -> Nil {
  let owner = server(fn(_) { actor.continue(Nil) })
  let started = process.new_subject()
  let finished = process.new_subject()
  let stop = turn.latch()
  let upstream = session_run.stoppable(idle_provider(started), owner, stop)
  let worker =
    process.spawn_unlinked(fn() {
      process.send(
        finished,
        upstream.stream(
          types.Request("test", None, [], [], None, types.defaults),
          fn(_) { types.Continue },
        ),
      )
    })
  let worker_monitor = process.monitor(worker)
  let assert Ok(helper) = process.receive(started, 1000)
  let helper_monitor = process.monitor(helper)
  case owner_dies {
    True -> {
      let assert Ok(owner_pid) = process.subject_owner(owner)
      process.unlink(owner_pid)
      process.kill(owner_pid)
    }
    False -> cancel(stop)
  }
  process.receive(finished, 1000) |> should.equal(Ok(Error(types.Cancelled)))
  process.new_selector()
  |> process.select_specific_monitor(helper_monitor, fn(_) { Nil })
  |> process.selector_receive(1000)
  |> should.equal(Ok(Nil))
  process.new_selector()
  |> process.select_specific_monitor(worker_monitor, fn(_) { Nil })
  |> process.selector_receive(1000)
  |> should.equal(Ok(Nil))
  process.demonitor_process(helper_monitor)
  process.demonitor_process(worker_monitor)
  case owner_dies {
    True -> Nil
    False -> {
      let assert Ok(owner_pid) = process.subject_owner(owner)
      process.unlink(owner_pid)
      process.kill(owner_pid)
    }
  }
}

pub fn owner_death_cleans_up_an_idle_provider_helper_test() -> Nil {
  idle_provider_cleanup(True)
}

pub fn cancellation_cleans_up_an_idle_provider_helper_test() -> Nil {
  idle_provider_cleanup(False)
}
