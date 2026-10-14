/// Late and cancelled run ownership cannot be reliably scheduled in E2E.
import albedo/daemon/conversation
import albedo/daemon/session_activity
import albedo/daemon/turn
import gleam/erlang/process
import gleam/option.{None, Some}
import gleeunit/should

fn run(id: String, work: turn.Work) -> turn.Run {
  let pid = process.spawn(fn() { Nil })
  turn.Run(id, pid, process.monitor(pid), False, turn.latch(), work)
}

fn running(id: String) -> turn.Activity {
  turn.Running(run(id, turn.Turn(None, False)))
}

pub fn late_messages_from_an_old_run_are_not_owned_test() -> Nil {
  let activity = running("current")
  turn.owner(activity, "old") |> should.equal(None)
  turn.live(activity, "old") |> should.be_false
  turn.live(activity, "current") |> should.be_true
  turn.owner(turn.Resting, "current") |> should.equal(None)
}

// A cancelled run may still save completed tool results but may not publish
// or take queued input.
pub fn cancelled_run_still_owns_writes_but_is_not_live_test() -> Nil {
  let activity = turn.cancel(running("a"))
  turn.live(activity, "a") |> should.be_false
  let assert Some(owned) = turn.owner(activity, "a")
  owned.cancelled |> should.be_true
  turn.cancel(turn.Resting) |> should.equal(turn.Resting)
}

// A turn shows compacting while its worker compacts ahead of a request, and
// returns to its stage when the request's context is recorded.
pub fn a_turn_shows_compacting_until_its_request_is_prepared_test() -> Nil {
  let phase = fn(activity) {
    session_activity.status(activity, False, None).phase
  }
  let activity = turn.committed(running("a"), "a", conversation.Tool)
  phase(activity) |> should.equal("running")
  let compacting = turn.compacting(activity, "a", True)
  phase(compacting) |> should.equal("compacting")
  turn.compacting(compacting, "old", False) |> should.equal(compacting)
  phase(turn.compacting(compacting, "a", False)) |> should.equal("running")
  phase(turn.committed(compacting, "a", conversation.Model))
  |> should.equal("generating")
}
