/// Late and cancelled run ownership cannot be reliably scheduled in E2E.
import albedo/daemon/turn
import gleam/erlang/process
import gleam/option.{None, Some}
import gleeunit/should

fn run(id: String, work: turn.Work) -> turn.Run {
  let pid = process.spawn(fn() { Nil })
  turn.Run(id, pid, process.monitor(pid), False, turn.latch(), work)
}

fn running(id: String) -> turn.Activity {
  turn.Running(run(id, turn.Turn(None)))
}

pub fn late_messages_from_an_old_run_are_not_owned_test() {
  let activity = running("current")
  turn.owner(activity, "old") |> should.equal(None)
  turn.live(activity, "old") |> should.be_false
  turn.live(activity, "current") |> should.be_true
  turn.owner(turn.Resting, "current") |> should.equal(None)
}

// A cancelled run may still save completed tool results but may not publish
// or take queued input.
pub fn cancelled_run_still_owns_writes_but_is_not_live_test() {
  let activity = turn.cancel(running("a"))
  turn.live(activity, "a") |> should.be_false
  let assert Some(owned) = turn.owner(activity, "a")
  owned.cancelled |> should.be_true
  turn.cancel(turn.Resting) |> should.equal(turn.Resting)
}
