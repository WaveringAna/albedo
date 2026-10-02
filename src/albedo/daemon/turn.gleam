//// A session's run bookkeeping as plain values: what a submission may do,
//// whether a late worker message still belongs to the active run, and which
//// stage a finished run leaves behind. The session actor performs every
//// effect but the cancel latch; these functions only decide, so the rules
//// are testable without a kernel, a provider, or an actor.

import albedo/daemon/conversation
import albedo/daemon/mail
import albedo/openai_api/types
import gleam/dynamic.{type Dynamic}
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
  /// A letter from the durable inbox, marked delivered when its input commits.
  /// Letters between agents steer a running turn; webhooks wait for idle.
  Mail(id: String, kind: mail.Kind)
  /// Something an extension tells the agent, such as a user's work ledger
  /// change. `origin` labels it in the transcript.
  Note(origin: String)
  Continue
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
    submission_id: Option(String),
  )
}

pub type Work {
  Compaction
  /// An extension's background call: commits nothing and publishes
  /// nothing; its outcome goes back to `reply`.
  Background(reply: process.Subject(Result(Option(types.Usage), String)))
  /// `stage` is None until the turn's first commit.
  Turn(stage: Option(conversation.Stage))
}

pub type Run {
  Run(
    id: String,
    pid: process.Pid,
    monitor: process.Monitor,
    cancelled: Bool,
    /// The worker's copy of `cancelled`, raised with it.
    stop: Latch,
    work: Work,
  )
}

/// A flag the session raises once and a worker reads without asking. A call
/// to a stalled session actor gets no answer at all, so a worker that must
/// not start a tool after a cancel cannot learn of it from a reply.
pub type Latch

@external(erlang, "atomics", "new")
fn new_atomics(size: Int, options: List(Nil)) -> Latch

@external(erlang, "atomics", "put")
fn put(latch: Latch, index: Int, value: Int) -> Dynamic

@external(erlang, "atomics", "get")
fn get(latch: Latch, index: Int) -> Int

pub fn latch() -> Latch {
  new_atomics(1, [])
}

fn raise(latch: Latch) -> Nil {
  let _ = put(latch, 1, 1)
  Nil
}

pub fn raised(latch: Latch) -> Bool {
  get(latch, 1) == 1
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
const queue_limit = 32

pub fn source_name(source: Source) -> String {
  case source {
    Chat -> "chat"
    JobWake -> "job"
    Mail(_, mail.Webhook) -> "webhook"
    Mail(..) -> "mail"
    Note(origin) -> origin
    Continue -> "continue"
  }
}

type SourceRule {
  StartsTurn
  SteersOnly
  RefusedWhenBusy
}

fn source_rule(source: Source) -> SourceRule {
  case source {
    JobWake | Mail(_, mail.Webhook) -> RefusedWhenBusy
    Note(_) -> SteersOnly
    _ -> StartsTurn
  }
}

pub fn admit(
  activity: Activity,
  submission: Submission,
  queued: Int,
) -> Admission {
  case bounded(submission), source_rule(submission.source), activity {
    False, _, _ -> Reject(Oversized)
    True, SteersOnly, _ -> room(queued)
    True, RefusedWhenBusy, Running(_) -> Reject(Busy)
    True, StartsTurn, Running(_) -> room(queued)
    True, _, _ -> Start
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
  list.any(queued, fn(submission) {
    case submission.source {
      Chat | Continue | Mail(..) -> True
      JobWake | Note(_) -> False
    }
  })
}

/// The letters these submissions deliver, for the commit that writes them.
pub fn letters(submissions: List(Submission)) -> List(String) {
  list.filter_map(submissions, fn(submission) {
    case submission.source {
      Mail(id, _) -> Ok(id)
      _ -> Error(Nil)
    }
  })
}

/// Whether letter `id` already waits in this queue.
pub fn holds_letter(queued: List(Submission), id: String) -> Bool {
  list.contains(letters(queued), id)
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

/// Also raises the worker's latch, so the two copies cannot disagree.
pub fn cancel(activity: Activity) -> Activity {
  case running(activity) {
    Some(run) -> {
      raise(run.stop)
      Running(Run(..run, cancelled: True))
    }
    None -> activity
  }
}

/// Record the stage a run's worker committed.
pub fn committed(
  activity: Activity,
  id: String,
  stage: conversation.Stage,
) -> Activity {
  case owner(activity, id) {
    Some(Run(work: Turn(_), ..) as run) ->
      Running(Run(..run, work: Turn(Some(stage))))
    _ -> activity
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
    Running(Run(work: Background(_), ..)) -> "background"
    Running(Run(work: Turn(None), ..)) -> "preparing"
    Running(Run(work: Turn(Some(stage)), ..)) -> conversation.stage_name(stage)
  }
}
