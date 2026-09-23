import albedo/daemon/conversation
import albedo/daemon/turn
import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should

fn chat(text: String) -> turn.Submission {
  turn.Submission(text, text, "client", turn.Chat, None)
}

fn wake(text: String) -> turn.Submission {
  turn.Submission(text, text, "bash", turn.JobWake, None)
}

fn run(id: String, work: turn.Work) -> turn.Run {
  let pid = process.spawn(fn() { Nil })
  turn.Run(id, pid, process.monitor(pid), False, work)
}

fn running(id: String) -> turn.Activity {
  turn.Running(run(id, turn.Turn(None)))
}

pub fn idle_session_starts_a_valid_submission_test() {
  turn.admit(turn.Resting, chat("hello"), 0) |> should.equal(turn.Start)
  turn.admit(turn.Interrupted, wake("job done"), 0) |> should.equal(turn.Start)
}

pub fn empty_or_oversized_submissions_are_rejected_test() {
  turn.admit(turn.Resting, chat("   "), 0)
  |> should.equal(turn.Reject(turn.Oversized))
  turn.admit(turn.Resting, chat(string.repeat("x", 1_048_577)), 0)
  |> should.equal(turn.Reject(turn.Oversized))
  // An activation may send more than it displays.
  turn.admit(
    turn.Resting,
    turn.Submission(
      "/skill",
      string.repeat("x", 2_000_000),
      "c",
      turn.Chat,
      None,
    ),
    0,
  )
  |> should.equal(turn.Start)
}

pub fn busy_session_queues_chat_up_to_its_limit_test() {
  turn.admit(running("a"), chat("steer"), 0) |> should.equal(turn.Queue)
  turn.admit(running("a"), chat("steer"), turn.queue_limit - 1)
  |> should.equal(turn.Queue)
  turn.admit(running("a"), chat("steer"), turn.queue_limit)
  |> should.equal(turn.Reject(turn.Busy))
}

// A wake that finds a run must come back as Busy so the kernel retries it;
// queueing it would deliver a stale notice, dropping it would lose the wake.
pub fn busy_session_refuses_job_wakes_as_busy_test() {
  turn.admit(running("a"), wake("job done"), 0)
  |> should.equal(turn.Reject(turn.Busy))
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

pub fn phase_follows_the_run_test() {
  turn.phase(turn.Resting) |> should.equal("resting")
  turn.phase(turn.Interrupted) |> should.equal("interrupted")
  turn.phase(running("a")) |> should.equal("preparing")
  turn.phase(turn.committed(running("a"), "a", conversation.Tool))
  |> should.equal("tool")
  // A stale commit does not move the current run.
  turn.phase(turn.committed(running("a"), "old", conversation.Tool))
  |> should.equal("preparing")
  turn.phase(turn.Running(run("c", turn.Compaction)))
  |> should.equal("compacting")
  turn.phase(turn.committed(
    turn.Running(run("c", turn.Compaction)),
    "c",
    conversation.Model,
  ))
  |> should.equal("compacting")
}

pub fn only_a_clean_finish_leaves_the_session_idle_test() {
  let done = run("a", turn.Turn(None))
  turn.final_stage(done, Ok(Nil)) |> should.equal(conversation.Idle)
  turn.final_stage(done, Error("provider failed"))
  |> should.equal(conversation.Interrupted)
  turn.final_stage(turn.Run(..done, cancelled: True), Ok(Nil))
  |> should.equal(conversation.Interrupted)
}
