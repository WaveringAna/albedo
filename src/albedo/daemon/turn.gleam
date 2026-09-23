//// A session's run bookkeeping as plain values: what a submission may do,
//// whether a late worker message still belongs to the active run, and which
//// stage a finished run leaves behind. The session actor performs every
//// effect; these functions only decide, so the rules are testable without a
//// kernel, a provider, or an actor.

import albedo/daemon/conversation
import albedo/openai_api/types
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// Who submitted a turn. Chat messages wait in the queue while a run is
/// active; a job wake that finds the session busy is refused so the kernel
/// retries it; a note always waits, and never starts a turn on its own.
pub type Source {
  Chat
  JobWake
  /// Something an extension tells the agent, such as a user's work ledger
  /// change. `origin` labels it in the transcript.
  Note(origin: String)
}

pub type Submission {
  Submission(
    /// What the transcript view shows; an activation may display less than it sends.
    display: String,
    /// What the model receives.
    text: String,
    client_id: String,
    source: Source,
    image: Option(types.Image),
  )
}

pub type Work {
  Compaction
  /// `stage` is None until the turn's first commit.
  Turn(stage: Option(conversation.Stage))
}

pub type Run {
  Run(
    id: String,
    pid: process.Pid,
    monitor: process.Monitor,
    cancelled: Bool,
    work: Work,
  )
}

pub type Activity {
  Resting
  /// Idle after a restart that found an unfinished turn it did not resume.
  Interrupted
  Running(Run)
}

pub type Admission {
  Start
  Queue
  Reject(Rejection)
}

pub type Rejection {
  Busy
  Oversized
}

/// The most chat messages and notes that wait in one session's queue.
pub const queue_limit = 32

pub fn source_name(source: Source) -> String {
  case source {
    Chat -> "chat"
    JobWake -> "bash"
    Note(origin) -> origin
  }
}

pub fn admit(
  activity: Activity,
  submission: Submission,
  queued: Int,
) -> Admission {
  case activity, bounded(submission), submission.source {
    _, False, _ -> Reject(Oversized)
    _, True, Note(_) -> room(queued)
    Running(_), True, Chat -> room(queued)
    Running(_), True, JobWake -> Reject(Busy)
    Resting, True, _ | Interrupted, True, _ -> Start
  }
}

fn room(queued: Int) -> Admission {
  case queued < queue_limit {
    True -> Queue
    False -> Reject(Busy)
  }
}

/// A nonempty prompt within its size limits. An activation whose display
/// differs from its text may send a larger body.
fn bounded(submission: Submission) -> Bool {
  let maximum = case submission.display == submission.text {
    True -> 1_048_576
    False -> 2_200_000
  }
  string.trim(submission.text) != ""
  && string.byte_size(submission.text) <= maximum
  && string.byte_size(submission.display) <= 1_048_576
}

/// Whether a finished run should start another for this queue: notes alone
/// wait for the user's next message.
pub fn starts_turn(queued: List(Submission)) -> Bool {
  list.any(queued, fn(submission) { submission.source == Chat })
}

pub fn running(activity: Activity) -> Option(Run) {
  case activity {
    Running(run) -> Some(run)
    Resting | Interrupted -> None
  }
}

/// The active run, when `id` names it. Durable writes from a cancelled run
/// still land: its completed tool results happened.
pub fn owner(activity: Activity, id: String) -> Option(Run) {
  case activity {
    Running(run) if run.id == id -> Some(run)
    _ -> None
  }
}

/// Whether `id` may still publish or take queued input: its run is active and
/// nobody asked it to stop.
pub fn live(activity: Activity, id: String) -> Bool {
  case owner(activity, id) {
    Some(run) -> !run.cancelled
    None -> False
  }
}

pub fn cancel(activity: Activity) -> Activity {
  case activity {
    Running(run) -> Running(Run(..run, cancelled: True))
    other -> other
  }
}

/// Record the stage a run's worker committed.
pub fn committed(
  activity: Activity,
  id: String,
  stage: conversation.Stage,
) -> Activity {
  case activity {
    Running(Run(work: Turn(_), ..) as run) if run.id == id ->
      Running(Run(..run, work: Turn(Some(stage))))
    other -> other
  }
}

/// The stage a finished run leaves in the ledger.
pub fn final_stage(run: Run, outcome: Result(a, e)) -> conversation.Stage {
  case outcome, run.cancelled {
    Ok(_), False -> conversation.Idle
    _, _ -> conversation.Interrupted
  }
}

/// The phase name clients see in the status route.
pub fn phase(activity: Activity) -> String {
  case activity {
    Resting -> "resting"
    Interrupted -> "interrupted"
    Running(Run(work: Compaction, ..)) -> "compacting"
    Running(Run(work: Turn(None), ..)) -> "preparing"
    Running(Run(work: Turn(Some(stage)), ..)) -> conversation.stage_name(stage)
  }
}
