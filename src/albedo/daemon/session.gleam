//// One coordinator per session. Workers own model/tool loops; clients never own workers.

import albedo/actor_call
import albedo/clock

import albedo/daemon/active_output
import albedo/daemon/bus
import albedo/daemon/context_snapshot
import albedo/daemon/conversation
import albedo/daemon/event_buffer
import albedo/daemon/events as view
import albedo/daemon/family
import albedo/daemon/images
import albedo/daemon/mail
import albedo/daemon/message_content
import albedo/daemon/operations
import albedo/daemon/requests
import albedo/daemon/session_activity
import albedo/daemon/session_configuration
import albedo/daemon/session_configure
import albedo/daemon/session_extensions
import albedo/daemon/session_history
import albedo/daemon/session_namespace
import albedo/daemon/session_provider
import albedo/daemon/session_run
import albedo/daemon/session_state
import albedo/daemon/session_submission
import albedo/daemon/session_workspace
import albedo/daemon/store
import albedo/daemon/tool_progress as tool_progress_state
import albedo/daemon/transcript
import albedo/daemon/turn.{type Submission, Submission}
import albedo/daemon/usage
import albedo/harness/cache_fade
import albedo/harness/command
import albedo/harness/extension
import albedo/harness/extensions/python/kernel as python
import albedo/harness/extensions/run/extension as run
import albedo/harness/location
import albedo/harness/loop
import albedo/harness/runtime
import albedo/harness/ssh
import albedo/openai_api/types
import gleam/erlang/process.{type Subject}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string

/// What a turn resumed after a daemon restart tells the model, and the
/// transcript's marker for the restart.
const restart_text = "albedo restarted while this turn was running. Tool calls that were in flight are marked interrupted with an unknown outcome; check their effects before retrying anything, then continue the task."

const restart_note = Submission(
  restart_text,
  restart_text,
  "daemon",
  turn.Note("daemon restart"),
  [],
  None,
  None,
)

const continue_prompt = "<system-notice>
continue your unfinished task, by resuming the most recent intent.
if interrupted mid-step, just pick it back up from where it stopped.
never pause to summarize progress, re-confirm the plan, or ask whether to proceed.
just continue.
</system-notice>"

pub type Session =
  Subject(Message)

/// A replay position belongs to exactly one session actor lifetime.
pub type Cursor {
  Cursor(generation: String, sequence: Int)
}

pub type Page {
  Page(cursor: Cursor, events: List(json.Json), snapshot: Option(Capture))
}

pub type Capture {
  Capture(
    info: conversation.Info,
    cursor: Cursor,
    status: session_activity.Status,
    pending_inputs: List(operations.Pending),
    input_order: Int,
    current_progress: List(tool_progress_state.Snapshot),
    history_high_water: Int,
    usage: Option(usage.Metadata),
    kernel: session_namespace.KernelObservation,
    activity: session_activity.Projection,
    created_at: Option(Int),
    activity_at: Option(Int),
    revision: Int,
    family: family.Facts,
    continuation_high_water: Int,
    automatic_name: String,
    configuration: session_configuration.Configuration,
    composition: runtime.CompositionObservation,
    workspace_change: Option(session_workspace.Pending),
    preview: conversation.Preview,
    active_output: List(active_output.Snapshot),
  )
}

pub type Summary {
  Summary(
    cursor: Cursor,
    status: session_activity.Status,
    current_progress: List(tool_progress_state.Snapshot),
    activity: session_activity.Projection,
    usage: Option(usage.Metadata),
  )
}

pub type InputCancellation {
  Cancelled
  InterruptRequested
  SharedRunning
  NotPending
}

pub type Interruption {
  Interruption(
    run_id: Option(String),
    requested: Bool,
    cancelled_input_ids: List(String),
  )
}

/// What a sweep needs to decide whether this session's kernel can be released.
pub type Report {
  Report(
    running: Bool,
    kernel: Option(Int),
    history_loaded: Bool,
    idle_ms: Int,
    jobs: Int,
  )
}

pub type ModelSelection {
  ModelSelection(
    provider: String,
    model: String,
    protocol: types.Protocol,
    effort: Option(String),
  )
}

pub type SubmissionError {
  WorkspaceMissing(String)
  /// A run is active and this submission cannot wait for it.
  Busy
  Rejected(String)
}

pub fn submission_error(error: SubmissionError) -> String {
  case error {
    WorkspaceMissing(path) -> "workspace not found: " <> path
    Busy -> "session is busy or message queue is full"
    Rejected(message) -> message
  }
}

pub type Message {
  Resume
  ReadCapture(Subject(Result(Unobserved, String)))
  ReadSummary(Subject(Summary))
  /// See `extension.Session.awaiting_jobs`.
  ReadAwaitingJobs(Subject(Bool))
  ChangeConfiguration(
    session_configuration.Version,
    session_configuration.Patch,
    Subject(Result(Unobserved, String)),
  )
  InterruptCaptured(Option(String), Int, Subject(Result(Interruption, String)))
  Abort(String)
  Submit(Submission, Subject(Result(Bool, SubmissionError)))
  CancelInput(String, Subject(Result(InputCancellation, String)))
  ReadCommands(
    Subject(Result(#(List(command.Command), command.Context), String)),
  )
  ReadSelection(Subject(ModelSelection))
  ChangeWorkspace(
    session_workspace.Request,
    Subject(Result(session_workspace.Recorded, session_workspace.ChangeFailure)),
  )
  ApplyWorkspace(Subject(Result(Bool, String)))
  Interrupt(Subject(Bool))
  /// A model switch; the last flag also makes it the default for new sessions.
  ChangeModel(
    String,
    Option(String),
    Option(String),
    Bool,
    Subject(Result(ModelSelection, String)),
  )
  ReadEffort(Subject(Result(json.Json, String)))
  ChangeEffort(String, Subject(Result(json.Json, String)))
  StopJob(String, Subject(Result(Nil, String)))
  /// Report on the kernel's staleness, or (True) force its swap now.
  UpgradeKernel(Subject(Result(runtime.KernelUpgrade, String)))
  UpgradeCompletion(
    Result(runtime.KernelUpgrade, String),
    Subject(Result(runtime.KernelUpgrade, String)),
  )
  Read(
    Option(Cursor),
    Subject(Result(#(Cursor, List(json.Json), Option(Unobserved)), String)),
  )
  Watch(process.Pid, fn() -> Nil)
  Consumed(process.Pid, Cursor, Bool)
  Publish(String, view.Event, Subject(Bool))
  AgentProgress(String)
  ToolProgressDelta(String, Int, Int, Int, String, String, Subject(Bool))
  ToolProgressRunning(String, Int, Int, Int, String, String, Subject(Bool))
  ToolProgressReset(String, Int, Subject(Nil))
  ToolProgressFinish(String, String, Subject(Nil))
  ProgressFlush(Int)
  Commit(
    String,
    List(types.Input),
    conversation.Stage,
    Option(Int),
    Subject(Result(#(Int, Option(Int)), String)),
  )
  CommitFits(String, List(transcript.ImageFit), Subject(Result(Nil, String)))
  RecordContext(String, context_snapshot.Snapshot, Bool, Subject(Nil))
  RecordUsage(String, usage.Metadata, Subject(Result(Nil, String)))
  ReportPin(String, Option(Int), Subject(Nil))
  /// The worker's turn call succeeded; the session's extensions hear it.
  /// Fire-and-forget, like the pin report.
  ReportSent(String, extension.SentCall, Subject(Nil))
  /// An extension asks for a background call; see `extension.Session`.
  CallInBackground(
    types.Request,
    requests.Prefix,
    Subject(Result(Option(types.Usage), String)),
  )
  /// A background call's worker finished.
  BackgroundFinished(String, Int, Result(Option(types.Usage), String))
  Compact(Option(String), Subject(Result(turn.CompactionReport, String)))
  ReloadData(Subject(Result(session_extensions.Reloaded, String)))
  /// An extension asks for a refresh and gives its reason; see
  /// `extension.Session`.
  RefreshRequested(String)
  DrainSteering(String, Subject(Result(List(types.Input), String)))
  ReadContext(Subject(context_snapshot.Snapshot))
  Finished(String, Result(Nil, String))
  Down(process.Down)
  Idle(Subject(Report))
  Release(Subject(Bool))
  EvictHistory(Subject(Bool))
  /// Queued behind a handler that dropped a large part of the state. An idle
  /// actor never collects on its own, so without this the dropped history and
  /// the binaries it references stay resident until the next message.
  Collect
  Close(Subject(Nil))
  /// Stop the actor if nothing runs, waits, watches, or holds a live job.
  /// True when it stopped.
  Unload(Subject(Bool))
  CloseForDeletion(Subject(Result(Nil, String)))
  ClaimDeletion(
    family.DeletionRequest,
    String,
    Int,
    Subject(Result(family.DeletionClaim, String)),
  )
  /// The runtime answered this session's kernel request.
  KernelOpened(Result(runtime.Session, python.Error))
  /// Start a turn for what waits in the queue, now that the kernel is here.
  StartQueued
  AdmitOperation(
    operations.Request,
    Submission,
    Subject(Result(operations.Receipt, String)),
  )
}

type State =
  session_state.State(Message)

/// Starting a session costs no Python process; the first run opens the kernel.
pub fn start(
  host: runtime.Runtime,
  info: conversation.Info,
  home: String,
) -> Result(Session, actor.StartError) {
  actor.new_with_initialiser(10_000, fn(self) {
    label("albedo_session", info.id)
    use _ <- result.try(
      store.query(runtime.ledger(host), fn(db) {
        use _ <- result.try(family.available_in(db, info.id))
        live_register(info.id, self)
        Ok(Nil)
      }),
    )
    use latest_usage <- result.try(conversation.load_usage(
      runtime.ledger(host),
      info.id,
    ))
    use captured <- result.try(conversation.capture(
      runtime.ledger(host),
      info.id,
    ))
    use pinned <- result.try(conversation.prompt_pin(
      runtime.ledger(host),
      info.id,
    ))
    case conversation.resumable(info.stage) {
      True -> process.send(self, Resume)
      False -> Nil
    }
    let activity = case info.stage {
      conversation.Idle -> turn.Resting
      _ -> turn.Interrupted
    }
    use pending <- result.try(operations.pending(runtime.ledger(host), info.id))
    let steering =
      list.map(pending, fn(row) { session_submission.decode(row.payload) })
    case steering {
      [] -> Nil
      _ -> process.send(self, StartQueued)
    }
    let generation = new_generation()
    let state =
      session_state.State(
        active_output: active_output.new(home, info.id, generation),
        info: info,
        host: host,
        kernel: None,
        home: home,
        self: self,
        history: None,
        latest_usage: latest_usage,
        activity: activity,
        steering: steering,
        active_submissions: [],
        sequence: 0,
        events: event_buffer.new(),
        watchers: [],
        notice: None,
        context: session_state.unprepared(),
        pin: case pinned {
          Some(#(prompt, head)) -> loop.Pinned(prompt, Some(head))
          None -> loop.Unpinned
        },
        prepared_head: None,
        last_touch: clock.monotonic_ms(),
        booting: None,
        blocked_until: 0,
        generation: generation,
        tool_progress: tool_progress_state.new(),
        progress_timer_token: 0,
        progress_timer: None,
        live_activity: session_activity.request(
          session_activity.new(usage.now()),
          captured.current_request,
        ),
        announced_status: None,
      )
    // Background jobs and cells wake through their kernel host routes; the
    // registered closure lands a completion notice as an ordinary submit, so
    // the wake reuses the whole turn pipeline and busy answers itself. Its own
    // input id keeps the one-line display beside the model's longer notice.
    wakes_register(info.id, fn(origin, display, text) {
      wake(
        self,
        Submission(
          display,
          text,
          origin,
          turn.JobWake,
          [],
          Some(mail.new_id()),
          None,
        ),
      )
    })
    commands_register(info.id, fn(op) { command_op(self, host, info.id, op) })
    bus.register_progress(info.id, process.self(), fn(text) {
      process.send(self, AgentProgress(text))
    })
    mailbox_register(info.id, fn(letter) {
      submit_mail(self, letter) |> result.map_error(submission_error)
    })
    Ok(
      actor.initialised(state)
      |> actor.returning(self)
      |> actor.selecting(
        process.new_selector()
        |> process.select(self)
        |> process.select_monitors(Down),
      ),
    )
  })
  |> actor.on_message(handle)
  |> actor.start
  |> result.map(fn(p) {
    process.unlink(p.pid)
    p.data
  })
}

/// A stored letter, admitted like any submission. Its receipt commits with the
/// transcript input it becomes; a letter already queued or committed is
/// accepted again without a second copy.
pub fn submit_mail(
  session: Session,
  letter: mail.Letter,
) -> Result(Bool, SubmissionError) {
  call_submit(
    session,
    Submission(
      mail.display(letter),
      mail.text(letter),
      letter.id,
      turn.Mail(letter.id, letter.kind),
      [],
      None,
      None,
    ),
  )
}

pub fn submit(
  session: Session,
  text: String,
  client_id: String,
  images: List(types.Image),
) -> Result(Bool, SubmissionError) {
  call_submit(
    session,
    Submission(text, text, client_id, turn.Chat, images, None, None),
  )
}

pub fn cancel_input(
  session: Session,
  input_id: String,
) -> Result(InputCancellation, String) {
  actor.call(session, 5000, CancelInput(input_id, _))
}

/// This session's materialized command catalog and the context that runs them.
/// Answered through the kernel's session, so the list matches its bindings.
pub fn commands(
  session: Session,
) -> Result(#(List(command.Command), command.Context), String) {
  actor.call(session, 15_000, ReadCommands)
}

pub fn interrupt(session: Session) -> Bool {
  actor.call(session, 5000, Interrupt)
}

/// The observed run and input prefix are the full scope of this request.
pub fn interrupt_captured(
  session: Session,
  run_id: Option(String),
  through_input_order: Int,
) -> Result(Interruption, String) {
  actor.call(session, 5000, InterruptCaptured(run_id, through_input_order, _))
}

pub fn capture(session: Session) -> Result(Capture, String) {
  actor_call.try_call(session, 5000, ReadCapture)
  |> result.replace_error("session capture unavailable")
  |> result.flatten
  |> result.try(fn(observe) { observe() })
}

/// Reload desired composition and wait for the runtime's actual result.
pub fn reload(session: Session) -> Result(session_extensions.Reloaded, String) {
  actor_call.try_call(session, 185_000, ReloadData)
  |> result.replace_error(
    "reload response unavailable; inspect session composition",
  )
  |> result.flatten
}

/// Capture collection facts without inspecting a kernel or composing plugins.
pub fn summary(session: Session) -> Result(Summary, String) {
  actor_call.try_call(session, 5000, ReadSummary)
  |> result.replace_error("session summary unavailable")
}

pub fn change_configuration(
  session: Session,
  expected: session_configuration.Version,
  patch: session_configuration.Patch,
) -> Result(Capture, String) {
  actor.call(session, 30_000, ChangeConfiguration(expected, patch, _))
  |> result.try(fn(observe) { observe() })
}

/// Register a wake callback for one streaming client. The callback runs in the
/// session process and must only notify; dead watchers are dropped.
pub fn watch(session: Session, owner: process.Pid, notify: fn() -> Nil) -> Nil {
  process.send(session, Watch(owner, notify))
}

/// A successful frame consumed this cursor. Timers can overtake a queued wake,
/// so only handling that wake rearms its notification.
pub fn consumed(
  session: Session,
  owner: process.Pid,
  cursor: Cursor,
  wake_consumed: Bool,
) -> Nil {
  process.send(session, Consumed(owner, cursor, wake_consumed))
}

/// Events after the fully consumed actor cursor. A reset returns a captured
/// session state; the HTTP owner reads history through its durable boundary.
pub fn read(session: Session, after: Option(Cursor)) -> Result(Page, String) {
  use #(cursor, events, unobserved) <- result.try(
    actor.call(session, 5000, Read(after, _)),
  )
  case unobserved {
    None -> Ok(Page(cursor, events, None))
    Some(observe) ->
      observe() |> result.map(fn(capture) { Page(cursor, [], Some(capture)) })
  }
}

/// Capture the latest prepared request without triggering model work.
/// An observed identity pins navigation to that request.
pub fn prepared_context(
  session: Session,
  expected: Option(String),
) -> Result(context_snapshot.Snapshot, String) {
  let snapshot = actor.call(session, 5000, ReadContext)
  case expected, context_snapshot.identity(snapshot) {
    Some(id), actual if actual != Some(id) -> Error("context_changed")
    _, _ -> Ok(snapshot)
  }
}

fn context(session: Session) -> json.Json {
  actor.call(session, 5000, ReadContext) |> context_snapshot.summary
}

fn context_page(
  session: Session,
  section: String,
  page: Int,
) -> Result(json.Json, String) {
  actor.call(session, 5000, ReadContext)
  |> context_snapshot.page(section, page)
  |> result.map(fn(part) {
    json.object([
      #("snapshot_id", json.string(part.snapshot_id)),
      #("section_id", json.string(part.section_id)),
      #("page", json.int(part.page)),
      #("page_count", json.int(part.page_count)),
      #("text", json.string(part.text)),
      #("omitted", json.nullable(part.omitted, json.string)),
    ])
  })
}

/// Remove the saved variables after a session has stopped.
pub fn discard_state(home: String, id: String) -> Nil {
  case session_namespace.state_path(home, id) {
    Some(path) -> discard(path)
    None -> Nil
  }
}

pub fn claim_deletion(
  session: Session,
  request: family.DeletionRequest,
  token: String,
) -> Result(family.DeletionClaim, String) {
  actor_call.try_call(session, 5000, ClaimDeletion(
    request,
    token,
    clock.monotonic_ms() + 5000,
    _,
  ))
  |> result.map_error(fn(error) {
    case error {
      actor_call.CalleeDown -> "session owner stopped before deletion admission"
      actor_call.TimedOut -> "deletion admission deadline reached"
    }
  })
  |> result.flatten
}

type ClosureEvent {
  Stopped
  StopAcknowledged(Result(Nil, String))
}

/// Wait for termination, not just the close acknowledgment. A timeout leaves
/// the durable row intact so deletion can report it as remaining.
pub fn close_for_deletion(
  session: Session,
  timeout_ms: Int,
) -> Result(Nil, String) {
  case process.subject_owner(session) {
    Error(_) -> Ok(Nil)
    Ok(owner) -> {
      let deadline = clock.monotonic_ms() + timeout_ms
      let monitor = process.monitor(owner)
      let reply = process.new_subject()
      process.send(session, CloseForDeletion(reply))
      let outcome =
        process.new_selector()
        |> process.select_map(reply, StopAcknowledged)
        |> process.select_specific_monitor(monitor, fn(_) { Stopped })
        |> process.selector_receive(timeout_ms)
      let stopped = case outcome {
        Error(_) -> Error("session did not stop before deletion deadline")
        Ok(Stopped) -> Ok(Nil)
        Ok(StopAcknowledged(Error(error))) -> Error(error)
        Ok(StopAcknowledged(Ok(_))) -> {
          let remaining = deadline - clock.monotonic_ms()
          case remaining <= 0 {
            True -> Error("session did not stop before deletion deadline")
            False ->
              process.new_selector()
              |> process.select_specific_monitor(monitor, fn(_) { Nil })
              |> process.selector_receive(remaining)
              |> result.replace_error(
                "session did not stop before deletion deadline",
              )
          }
        }
      }
      process.demonitor_process(monitor)
      stopped
    }
  }
}

/// Whether the session's actor still runs; an unloaded one stops before its
/// registry hears of it.
pub fn alive(session: Session) -> Bool {
  process.subject_owner(session)
  |> result.map(process.is_alive)
  |> result.unwrap(False)
}

pub fn close(session: Session) -> Nil {
  actor.call(session, 30_000, Close)
}

/// Whether this session holds a kernel, and how long since a client last spoke.
pub fn report(session: Session) -> Report {
  actor.call(session, 5000, Idle)
}

/// Release the kernel if nothing is attached or running. True when one was released.
pub fn release(session: Session) -> Bool {
  actor.call(session, 40_000, Release)
}

/// Drop an idle actor's reloadable transcript cache without touching its event
/// cursor or durable requests. Active runs always retain their prepared history.
pub fn evict_history(session: Session) -> Bool {
  actor.call(session, 5000, EvictHistory)
}

fn answer(
  state: State,
  reply: Subject(a),
  value: a,
) -> actor.Next(State, Message) {
  process.send(reply, value)
  actor.continue(state)
}

fn tool_progress_delta(
  state: State,
  run_id: String,
  step: Int,
  attempt: Int,
  output_index: Int,
  name: String,
  fragment: String,
  reply: Subject(Bool),
) -> actor.Next(State, Message) {
  case turn.live(state.activity, run_id) {
    False -> answer(state, reply, False)
    True -> {
      let was_enabled = tool_progress_state.enabled(state.tool_progress)
      let had_calls = tool_progress_state.has_calls(state.tool_progress)
      let tool_progress_state.Update(progress, snapshot, invalidates_progress) =
        tool_progress_state.update(
          state.tool_progress,
          generation: state.generation,
          run_id: run_id,
          step: step,
          attempt: attempt,
          output_index: output_index,
          incoming_name: name,
          fragment: fragment,
        )
      let overflow = was_enabled && !tool_progress_state.enabled(progress)
      let clear_previous = { invalidates_progress && had_calls } || overflow
      let state = apply_tool_progress(state, progress, snapshot, clear_previous)
      answer(state, reply, True)
    }
  }
}

fn tool_progress_running(
  state: State,
  run_id: String,
  step: Int,
  attempt: Int,
  output_index: Int,
  tool_call_id: String,
  name: String,
  reply: Subject(Bool),
) -> actor.Next(State, Message) {
  case turn.live(state.activity, run_id) {
    False -> answer(state, reply, False)
    True -> {
      let had_calls = tool_progress_state.has_calls(state.tool_progress)
      let tool_progress_state.Update(progress, snapshot, invalidates_progress) =
        tool_progress_state.running(
          state.tool_progress,
          generation: state.generation,
          run_id: run_id,
          step: step,
          attempt: attempt,
          output_index: output_index,
          tool_call_id: tool_call_id,
          name: name,
        )
      let state =
        apply_tool_progress(
          state,
          progress,
          snapshot,
          invalidates_progress && had_calls,
        )
      answer(state, reply, True)
    }
  }
}

fn apply_tool_progress(
  state: State,
  progress: tool_progress_state.Projection,
  snapshot: Option(tool_progress_state.Snapshot),
  clear_previous: Bool,
) -> State {
  let state = case clear_previous {
    True -> invalidate_progress_timer(state)
    False -> state
  }
  let state = session_state.State(..state, tool_progress: progress)
  let state = case clear_previous {
    True -> session_state.emit(state, view.clear_tool_progress())
    False -> state
  }
  let state = case snapshot {
    Some(snapshot) ->
      session_state.emit(state, view.tool_progress_event(snapshot))
    None -> state
  }
  schedule_progress_flush(state)
}

fn tool_progress_reset(
  state: State,
  run_id: String,
  attempt: Int,
  reply: Subject(Nil),
) -> actor.Next(State, Message) {
  case turn.live(state.activity, run_id) {
    False -> answer(state, reply, Nil)
    True -> {
      let state = invalidate_progress_timer(state)
      let progress = tool_progress_state.reset_attempt(attempt)
      let state = session_state.State(..state, tool_progress: progress)
      answer(session_state.emit(state, view.clear_tool_progress()), reply, Nil)
    }
  }
}

fn tool_progress_finish(
  state: State,
  run_id: String,
  progress_id: String,
  reply: Subject(Nil),
) -> actor.Next(State, Message) {
  case turn.owner(state.activity, run_id) {
    None -> answer(state, reply, Nil)
    Some(_) -> {
      let progress =
        tool_progress_state.finish_call(state.tool_progress, progress_id)
      let state = session_state.State(..state, tool_progress: progress)
      answer(schedule_progress_flush(state), reply, Nil)
    }
  }
}

fn invalidate_progress_timer(state: State) -> State {
  let _ = case state.progress_timer {
    Some(timer) -> process.cancel_timer(timer)
    None -> process.TimerNotFound
  }
  session_state.State(
    ..state,
    progress_timer_token: state.progress_timer_token + 1,
    progress_timer: None,
  )
}

fn schedule_progress_flush(state: State) -> State {
  case
    tool_progress_state.has_dirty(state.tool_progress),
    state.progress_timer
  {
    False, Some(_) -> invalidate_progress_timer(state)
    False, None | True, Some(_) -> state
    True, None -> {
      let token = state.progress_timer_token + 1
      let timer = process.send_after(state.self, 100, ProgressFlush(token))
      session_state.State(
        ..state,
        progress_timer_token: token,
        progress_timer: Some(timer),
      )
    }
  }
}

fn tool_progress_flush(state: State, token: Int) -> actor.Next(State, Message) {
  case state.progress_timer, state.progress_timer_token == token {
    Some(_), True -> {
      let #(progress, snapshots) =
        tool_progress_state.flush_dirty(state.tool_progress)
      let state =
        session_state.State(
          ..state,
          tool_progress: progress,
          progress_timer: None,
        )
      let state =
        list.fold(snapshots, state, fn(state, snapshot) {
          session_state.emit(state, view.tool_progress_event(snapshot))
        })
      actor.continue(state)
    }
    _, _ -> actor.continue(state)
  }
}

fn transition(
  reply: Subject(a),
  transition: #(State, a),
) -> actor.Next(State, Message) {
  process.send(reply, transition.1)
  actor.continue(transition.0)
}

/// Interrupt the live kernel, if there is one.
fn interrupt_kernel(state: State) -> Nil {
  case state.kernel {
    Some(kernel) -> runtime.interrupt(kernel)
    None -> Nil
  }
}

pub fn upgrade_kernel(
  session: Session,
) -> Result(runtime.KernelUpgrade, String) {
  actor_call.try_call(session, 185_000, UpgradeKernel)
  |> result.replace_error(
    "kernel upgrade response unavailable; inspect the session kernel",
  )
  |> result.flatten
}

fn begin_upgrade(
  state: State,
  reply: Subject(Result(runtime.KernelUpgrade, String)),
) -> actor.Next(State, Message) {
  case busy(state) || state.booting != None {
    True ->
      answer(state, reply, Error("session must be idle to upgrade the kernel"))
    False -> {
      let self = state.self
      runtime.upgrade_async(state.host, state.info.id, fn(outcome) {
        process.send(self, UpgradeCompletion(outcome, reply))
      })
      actor.continue(
        session_state.State(..state, booting: Some(#(1, [])))
        |> session_state.announce,
      )
    }
  }
}

fn upgraded_kernel(
  state: State,
  outcome: Result(runtime.KernelUpgrade, String),
  reply: Subject(Result(runtime.KernelUpgrade, String)),
) -> actor.Next(State, Message) {
  let parked =
    option.map(state.booting, fn(value) { value.1 }) |> option.unwrap([])
  let state = session_state.State(..state, booting: None)
  let state = case outcome {
    Ok(report) -> session_namespace.upgrade(state, report)
    Error(_) -> state
  }
  let state =
    session_state.announce(state)
    |> session_state.invalidate("session", "/sessions/" <> state.info.id)
  list.each(parked, process.send(state.self, _))
  process.send(state.self, StartQueued)
  answer(state, reply, outcome)
}

fn call_submit(
  session: Session,
  submission: Submission,
) -> Result(Bool, SubmissionError) {
  actor.call(session, 10_000, Submit(submission, _))
}

fn summary_state(state: State) -> Summary {
  Summary(
    Cursor(state.generation, state.sequence),
    session_state.current_status(state),
    tool_progress_state.snapshots(state.tool_progress),
    state.live_activity,
    state.latest_usage,
  )
}

/// A capture finished by its caller with the session's composition. The
/// runtime observes composition on worker slots that kernel boots share, so
/// it can queue for seconds; the caller waits for it, never the actor.
type Unobserved =
  fn() -> Result(Capture, String)

/// Everything the actor knows of itself, taken in one turn. Binds no `state`
/// in the closure, so the transcript stays in the actor.
fn capture_state(state: State) -> Result(Unobserved, String) {
  use durable <- result.try(conversation.capture(
    runtime.ledger(state.host),
    state.info.id,
  ))
  let summary = summary_state(state)
  use active_output <- result.try(active_output.capture(state.active_output))
  use kernel <- result.try(session_namespace.observe_kernel(state))
  let #(host, home, id) = #(state.host, state.home, state.info.id)
  Ok(fn() {
    use composition <- result.try(runtime.observe_composition(host, home, id))
    Ok(Capture(
      durable.info,
      summary.cursor,
      summary.status,
      durable.pending_inputs,
      durable.input_order,
      summary.current_progress,
      durable.history_high_water,
      summary.usage,
      kernel,
      summary.activity,
      durable.created_at,
      durable.activity_at,
      durable.revision,
      durable.family,
      durable.continuation_high_water,
      durable.automatic_name,
      durable.configuration,
      composition,
      durable.workspace_change,
      durable.preview,
      active_output,
    ))
  })
}

fn publish_active(state: State, event: view.Event) -> State {
  let #(projection, event) = case event {
    view.Text(run_id, message_id, text) -> {
      let id = active_output.namespace(state.active_output, message_id)
      #(
        active_output.observe(
          state.active_output,
          run_id,
          id,
          "text",
          text,
          None,
        ),
        view.Text(run_id, id, text),
      )
    }
    view.Thinking(run_id, message_id, text, elapsed) -> {
      let id = active_output.namespace(state.active_output, message_id)
      #(
        active_output.observe(
          state.active_output,
          run_id,
          id,
          "thinking",
          text,
          elapsed,
        ),
        view.Thinking(run_id, id, text, elapsed),
      )
    }
    view.Retry(..) -> #(active_output.retry(state.active_output), event)
    _ -> #(state.active_output, event)
  }
  session_state.emit(
    session_state.State(..state, active_output: projection),
    event,
  )
}

fn cleanup_registrations(id: String) -> Nil {
  wakes_forget(id)
  commands_forget(id)
  mailbox_forget(id)
  live_forget(id)
}

fn handle(
  state: State,
  message: Message,
) -> actor.Next(session_state.State(Message), Message) {
  // Anything a client sends counts as attention; a detached session goes quiet.
  // Listing sessions reads their summaries and is not attention.
  let state = case message {
    Submit(..)
    | ReadCapture(..)
    | ChangeConfiguration(..)
    | InterruptCaptured(..)
    | ReadCommands(..)
    | Interrupt(..)
    | CancelInput(..)
    | Read(..)
    | ReadContext(..)
    | ChangeModel(..)
    | Compact(..)
    | ReloadData(..)
    | ChangeWorkspace(..)
    | ApplyWorkspace(..) ->
      session_state.State(..state, last_touch: clock.monotonic_ms())
    _ -> state
  }
  // Runs end in finish_turn and background_finish, which follow at once; this
  // catches a turn that never started, such as one whose kernel failed to boot.
  let state = settle(state)
  case message {
    ReadCapture(reply) -> answer(state, reply, capture_state(state))
    ReadSummary(reply) -> answer(state, reply, summary_state(state))
    ReadAwaitingJobs(reply) -> answer(state, reply, awaiting_jobs(state))
    ChangeConfiguration(expected, patch, reply) -> {
      let #(state, changed) = session_configure.change(state, expected, patch)
      case changed {
        Error(error) -> answer(state, reply, Error(error))
        Ok(_) -> {
          let state =
            session_state.invalidate(
              state,
              "session",
              "/sessions/" <> state.info.id,
            )
          bus.invalidate(
            ["/sessions", "/sessions/" <> state.info.id],
            [state.info.id],
            False,
          )
          answer(state, reply, capture_state(state))
        }
      }
    }
    Resume ->
      case kernel_or_park(state, Resume) {
        Error(state) -> actor.continue(state)
        Ok(state) -> actor.continue(resume(state))
      }
    KernelOpened(result) -> actor.continue(kernel_opened(state, result))
    StartQueued -> actor.continue(start_queued(state))
    AdmitOperation(operation, submission, reply) ->
      admit_operation(state, operation, submission, reply)
    Abort(id) ->
      case turn.owner(state.activity, id) {
        Some(run) if run.cancelled -> {
          // The Cancel-time interrupt may have landed on an idle kernel,
          // before the turn reached a tool; a stalled actor can delay this
          // Abort past a tool gate, so interrupt whatever runs now too.
          interrupt_kernel(state)
          kill(run.pid)
          finish_run(state, run, Error("cancelled"))
        }
        _ -> actor.continue(state)
      }
    // The dispatcher retries letters it cannot see were admitted; one already
    // queued or committed here is accepted again without a second copy.
    Submit(Submission(source: turn.Mail(id, _), ..) as submission, reply) ->
      case
        turn.holds_letter(state.steering, id),
        mail.undelivered(runtime.ledger(state.host), id)
      {
        True, _ -> answer(state, reply, Ok(True))
        False, False -> answer(state, reply, Ok(False))
        False, True -> admit(state, submission, reply)
      }
    Submit(submission, reply) -> admit(state, submission, reply)
    ReadCommands(reply) -> {
      let host = state.host
      let id = state.info.id
      let cwd = state.info.cwd
      process.spawn_unlinked(fn() {
        process.send(reply, runtime.peek_commands(host, id, cwd))
      })
      actor.continue(state)
    }
    ReadSelection(reply) -> answer(state, reply, model_selection(state.info))
    CancelInput(id, reply) -> {
      let #(selected, remaining) =
        list.partition(state.steering, fn(submission) {
          submission.operation_id == Some(id)
        })
      case list.length(remaining) != list.length(state.steering) {
        True ->
          case
            operations.cancel_inputs(
              runtime.ledger(state.host),
              state.info.id,
              turn.operations(selected),
            )
          {
            Error(error) -> answer(state, reply, Error(error))
            Ok(_) ->
              answer(
                session_state.State(..state, steering: remaining)
                  |> session_submission.refresh_ids([id])
                  |> session_state.announce,
                reply,
                Ok(Cancelled),
              )
          }
        False ->
          case turn.running(state.activity), state.active_submissions {
            Some(run), [submission] if submission.operation_id == Some(id) -> {
              interrupt_kernel(state)
              let _ = process.send_after(state.self, 2500, Abort(run.id))
              answer(
                session_state.State(
                  ..state,
                  activity: turn.cancel(state.activity),
                )
                  |> session_state.announce,
                reply,
                Ok(InterruptRequested),
              )
            }
            Some(_), submissions ->
              answer(
                state,
                reply,
                Ok(
                  case
                    list.any(submissions, fn(submission) {
                      submission.operation_id == Some(id)
                    })
                  {
                    True -> SharedRunning
                    False -> NotPending
                  },
                ),
              )
            _, _ -> answer(state, reply, Ok(NotPending))
          }
      }
    }
    InterruptCaptured(run_id, through_order, reply) -> {
      case
        operations.cancel_through(
          runtime.ledger(state.host),
          state.info.id,
          through_order,
        )
      {
        Error(error) -> answer(state, reply, Error(error))
        Ok(cancelled) -> {
          let steering =
            list.filter(state.steering, fn(input) {
              case input.operation_id {
                Some(id) -> !list.contains(cancelled, id)
                None -> True
              }
            })
          let state = session_state.State(..state, steering: steering)
          let requested = case turn.running(state.activity), run_id {
            Some(run), Some(id) if run.id == id -> {
              interrupt_kernel(state)
              let _ = process.send_after(state.self, 2500, Abort(run.id))
              True
            }
            _, _ -> False
          }
          let state = case requested {
            True ->
              session_state.State(
                ..clear_tool_progress(state),
                activity: turn.cancel(state.activity),
              )
            False -> state
          }
          let state =
            session_submission.refresh_ids(state, cancelled)
            |> session_state.announce
          answer(state, reply, Ok(Interruption(run_id, requested, cancelled)))
        }
      }
    }
    Interrupt(reply) -> {
      case operations.cancel(runtime.ledger(state.host), state.info.id) {
        Error(error) ->
          answer(session_state.emit(state, view.error(error)), reply, False)
        Ok(_) -> interrupt_waiting(state, reply)
      }
    }
    ChangeWorkspace(request, reply) -> {
      let state = stirred(state)
      let recorded = case busy(state) || state.booting != None {
        True ->
          Error(session_workspace.Native(
            "session must be idle to change workspace",
          ))
        False -> {
          use destination <- result.try(
            location.workspace(request.destination)
            |> result.map_error(session_workspace.Destination),
          )
          session_workspace.record(
            runtime.ledger(state.host),
            session_workspace.Request(
              ..request,
              session: state.info.id,
              destination: location.to_string(destination),
            ),
          )
          |> result.map_error(session_workspace.Native)
        }
      }
      let state = case recorded {
        Ok(_) -> workspace_changed(state)
        Error(_) -> state
      }
      answer(state, reply, recorded)
    }
    ApplyWorkspace(reply) -> {
      case busy(state) || state.booting != None {
        True -> answer(state, reply, Ok(False))
        False -> {
          case apply_workspace_state(state) {
            Error(#(state, error)) -> answer(state, reply, Error(error))
            Ok(state) -> answer(state, reply, Ok(True))
          }
        }
      }
    }
    ChangeModel(model, provider_name, effort, remember, reply) -> {
      let #(state, outcome) =
        session_provider.select(
          stirred(state),
          model,
          provider_name,
          effort,
          remember,
        )
      answer(
        state,
        reply,
        result.map(outcome, fn(_) { model_selection(state.info) }),
      )
    }

    UpgradeKernel(reply) -> begin_upgrade(state, reply)
    UpgradeCompletion(outcome, reply) -> upgraded_kernel(state, outcome, reply)
    ReadEffort(reply) ->
      answer(state, reply, session_provider.read_effort(state))
    ChangeEffort(level, reply) ->
      transition(reply, session_provider.change_effort(stirred(state), level))

    ReloadData(reply) ->
      transition(
        reply,
        session_extensions.reload(state, "session data reloaded"),
      )
    RefreshRequested(reason) ->
      actor.continue(session_extensions.refresh_requested(state, reason))
    Compact(strategy, reply) ->
      case busy(state) {
        True -> answer(state, reply, Error("session must be idle to compact"))
        False ->
          case kernel_or_park(state, Compact(strategy, reply)) {
            Error(state) -> actor.continue(state)
            Ok(state) -> compact(state, strategy, reply)
          }
      }
    StopJob(id, reply) ->
      case state.kernel {
        Some(kernel) -> answer(state, reply, runtime.stop_job(kernel, id))
        None ->
          answer(state, reply, Error("no kernel attached to this session"))
      }
    Watch(owner, notify) -> {
      let watchers = case
        list.any(state.watchers, fn(watcher) { watcher.owner == owner })
      {
        True -> state.watchers
        False -> {
          let _ = process.monitor(owner)
          [session_state.Watcher(owner, notify, False), ..state.watchers]
        }
      }
      actor.continue(session_state.State(..state, watchers: watchers))
    }
    Consumed(owner, cursor, wake_consumed) -> {
      let watchers = case
        cursor.generation == state.generation
        && cursor.sequence >= 0
        && cursor.sequence <= state.sequence
      {
        False -> state.watchers
        True ->
          list.map(state.watchers, fn(watcher) {
            case watcher.owner == owner {
              False -> watcher
              True -> {
                let notified = watcher.notified && !wake_consumed
                case !notified && cursor.sequence < state.sequence {
                  True -> {
                    watcher.notify()
                    session_state.Watcher(..watcher, notified: True)
                  }
                  False -> session_state.Watcher(..watcher, notified: notified)
                }
              }
            }
          })
      }
      actor.continue(session_state.State(..state, watchers: watchers))
    }
    Read(after, reply) -> {
      let cursor = Cursor(state.generation, state.sequence)
      let replay = case after {
        Some(after) if after.generation == state.generation ->
          event_buffer.since(state.events, after.sequence, state.sequence)
        _ -> Error(Nil)
      }
      let page = case replay {
        Ok(events) -> Ok(#(cursor, events, None))
        Error(_) ->
          capture_state(state)
          |> result.map(fn(observe) { #(cursor, [], Some(observe)) })
      }
      answer(state, reply, page)
    }

    AgentProgress(text) ->
      actor.continue(session_state.emit(
        state,
        view.Note(mail.new_id(), "agent", text, None),
      ))
    Publish(id, event, reply) ->
      case turn.live(state.activity, id) {
        True ->
          case event {
            view.ProviderStarted ->
              answer(
                session_state.State(
                  ..state,
                  activity: turn.committed(
                    state.activity,
                    id,
                    conversation.Idle,
                  ),
                )
                  |> session_state.announce,
                reply,
                True,
              )
            view.Compacted(observed, evicted, summary) -> {
              let activity = case turn.running(state.activity) {
                Some(turn.Run(work: turn.Compaction(reply, report), ..) as run) ->
                  turn.Running(
                    turn.Run(
                      ..run,
                      work: turn.Compaction(
                        reply,
                        turn.CompactionReport(
                          ..report,
                          observation: Some(turn.CompactionObservation(
                            observed,
                            evicted,
                            summary,
                          )),
                        ),
                      ),
                    ),
                  )
                _ -> state.activity
              }
              answer(
                session_state.emit(
                  session_state.State(..state, activity: activity),
                  event,
                ),
                reply,
                True,
              )
            }
            _ -> answer(publish_active(state, event), reply, True)
          }
        False -> answer(state, reply, False)
      }
    ToolProgressDelta(id, step, attempt, output_index, name, fragment, reply) ->
      tool_progress_delta(
        state,
        id,
        step,
        attempt,
        output_index,
        name,
        fragment,
        reply,
      )
    ToolProgressRunning(
      id,
      step,
      attempt,
      output_index,
      tool_call_id,
      name,
      reply,
    ) ->
      tool_progress_running(
        state,
        id,
        step,
        attempt,
        output_index,
        tool_call_id,
        name,
        reply,
      )
    ToolProgressReset(id, attempt, reply) ->
      tool_progress_reset(state, id, attempt, reply)
    ToolProgressFinish(id, progress_id, reply) ->
      tool_progress_finish(state, id, progress_id, reply)
    ProgressFlush(token) -> tool_progress_flush(state, token)
    Commit(id, inputs, stage, thought_ms, reply) ->
      case turn.owner(state.activity, id) {
        Some(_) -> {
          // Completed tool results are saved even when cancellation was requested.
          let written =
            conversation.commit_response(
              runtime.ledger(state.host),
              state.info.id,
              inputs,
              stage,
              Some(state.info.provider),
              thought_ms,
              id,
            )
          case written {
            Ok(#(timestamp, _)) ->
              answer(
                session_history.remember_response(
                  session_state.State(
                    ..state,
                    activity: turn.committed(state.activity, id, stage),
                  ),
                  inputs,
                  timestamp,
                  thought_ms,
                ),
                reply,
                written,
              )
            Error(_) -> answer(state, reply, written)
          }
        }
        _ -> answer(state, reply, Error("stale run"))
      }
    CommitFits(id, fits, reply) ->
      case turn.owner(state.activity, id) {
        Some(_) ->
          case
            conversation.commit_fits(
              runtime.ledger(state.host),
              state.info.id,
              fits,
              state.info.provider,
            )
          {
            Ok(timestamp) -> {
              answer(
                session_history.remember_fits(state, fits, timestamp),
                reply,
                Ok(Nil),
              )
            }
            Error(error) -> answer(state, reply, Error(error))
          }
        None -> answer(state, reply, Error("stale run"))
      }
    DrainSteering(id, reply) ->
      case turn.live(state.activity, id), state.steering {
        False, _ -> answer(state, reply, Error("cancelled"))
        True, [] -> answer(state, reply, Ok([]))
        True, queued -> {
          let inputs = session_submission.inputs(queued)
          case
            conversation.commit_operations(
              runtime.ledger(state.host),
              state.info.id,
              inputs,
              conversation.Model,
              Some(state.info.provider),
              turn.letters(queued),
              session_submission.commits(queued, 0),
              id,
              state.info.cwd,
            )
          {
            Error(error) -> answer(state, reply, Error(error))
            Ok(timestamp) -> {
              let state =
                session_submission.emit(
                  session_history.remember(state, inputs, timestamp),
                  queued,
                  timestamp,
                )
              answer(
                session_state.State(
                  ..state,
                  steering: [],
                  active_submissions: list.append(
                    state.active_submissions,
                    queued,
                  ),
                )
                  |> session_submission.membership(id),
                reply,
                Ok(list.map(queued, session_submission.input)),
              )
            }
          }
        }
      }
    ReportPin(id, head, reply) -> {
      process.send(reply, Nil)
      case turn.live(state.activity, id), head, state.pin {
        True, Some(head), loop.Pinned(prompt, _) ->
          actor.continue(
            session_state.State(
              ..state,
              pin: loop.Pinned(prompt, Some(head)),
              prepared_head: Some(head),
            ),
          )
        True, Some(head), loop.Unpinned ->
          actor.continue(
            session_state.State(..state, prepared_head: Some(head)),
          )
        True, None, loop.Pinned(..) ->
          case
            conversation.clear_prompt_pin(
              runtime.ledger(state.host),
              state.info.id,
            )
          {
            Ok(_) ->
              actor.continue(
                session_state.State(
                  ..state,
                  pin: loop.Unpinned,
                  prepared_head: None,
                ),
              )
            Error(error) ->
              actor.continue(session_state.emit(
                state,
                view.error(
                  "compaction finished but the pinned system prompt could not be released: "
                  <> error,
                ),
              ))
          }
        _, _, _ -> actor.continue(state)
      }
    }
    ReportSent(id, call, reply) -> {
      process.send(reply, Nil)
      case turn.live(state.activity, id) {
        True -> observe(state, extension.CallSent(call))
        False -> Nil
      }
      actor.continue(state)
    }
    CallInBackground(request, prefix, reply) ->
      actor.continue(start_background(state, request, prefix, reply))
    BackgroundFinished(id, started, outcome) ->
      case turn.owner(state.activity, id) {
        Some(turn.Run(work: turn.Background(reply), ..) as run) -> {
          let state = case run.cancelled, outcome {
            False, Ok(_) -> rewarmed(state, started)
            _, _ -> state
          }
          background_finish(state, run, reply, outcome)
        }
        _ -> actor.continue(state)
      }
    RecordContext(id, snapshot, compacted, reply) ->
      answer(
        case turn.live(state.activity, id) {
          True -> {
            let state = session_state.State(..state, context: snapshot)
            case compacted {
              True -> elide_compacted_images(state)
              False -> state
            }
            |> session_state.invalidate(
              "context",
              "/sessions/" <> state.info.id <> "/context?view=summary",
            )
          }
          False -> state
        },
        reply,
        Nil,
      )
    ReadContext(reply) -> answer(state, reply, state.context)
    RecordUsage(id, metadata, reply) ->
      case turn.owner(state.activity, id) {
        Some(_) -> {
          let written =
            conversation.record_usage(
              runtime.ledger(state.host),
              state.info.id,
              metadata,
            )
          case written {
            Ok(_) ->
              answer(
                session_state.State(
                  ..state,
                  latest_usage: Some(metadata),
                  context: context_snapshot.with_usage(state.context, metadata),
                )
                  |> session_state.emit(view.Usage(metadata)),
                reply,
                written,
              )
            Error(_) -> answer(state, reply, written)
          }
        }
        _ -> answer(state, reply, Error("stale run"))
      }
    Finished(id, outcome) ->
      case turn.owner(state.activity, id) {
        Some(run) -> finish_run(state, run, outcome)
        _ -> actor.continue(state)
      }
    Down(process.ProcessDown(_, pid, _)) -> {
      let state =
        session_state.State(
          ..state,
          watchers: list.filter(state.watchers, fn(watcher) {
            watcher.owner != pid
          }),
        )
      case turn.running(state.activity) {
        Some(run) if run.pid == pid ->
          case run.work {
            turn.Background(reply) ->
              background_finish(
                state,
                run,
                reply,
                Error("background call worker stopped"),
              )
            _ ->
              finish_run(
                state,
                run,
                Error("worker stopped; execution may have had effects"),
              )
          }
        _ -> actor.continue(state)
      }
    }
    Down(_) -> actor.continue(state)
    Idle(reply) -> {
      let #(kernel, jobs) = case state.kernel {
        Some(kernel) -> #(
          option.from_result(runtime.kernel_pid(kernel)),
          runtime.job_count(kernel),
        )
        None -> #(None, 0)
      }
      // Live background jobs keep their kernel: releasing it would kill work
      // the session still owes a wake for, so the reaper counts them.
      answer(
        state,
        reply,
        Report(
          turn.running(state.activity) != None,
          kernel,
          state.history != None,
          clock.monotonic_ms() - state.last_touch,
          jobs,
        ),
      )
    }
    Release(reply) ->
      case state.kernel, turn.running(state.activity) {
        Some(kernel), None -> {
          let saved =
            session_namespace.save_state(state.home, state.info.id, kernel)
          runtime.reset_session(state.host, state.info.id)
          process.send(state.self, Collect)
          answer(
            session_state.State(
              ..state,
              kernel: None,
              context: session_state.unprepared(),
            )
              |> session_state.emit(view.note(
                "daemon",
                session_namespace.released_text(saved, "nothing was attached"),
              )),
            reply,
            True,
          )
        }
        _, _ -> answer(state, reply, False)
      }
    EvictHistory(reply) ->
      case turn.running(state.activity) {
        Some(_) -> answer(state, reply, False)
        None -> {
          let evicted = state.history != None
          process.send(state.self, Collect)
          answer(session_state.State(..state, history: None), reply, evicted)
        }
      }
    Collect -> {
      collect()
      actor.continue(state)
    }
    ClaimDeletion(request, token, deadline, reply) -> {
      let claimed = case
        !request.subtree && { busy(state) || state.booting != None }
      {
        True -> Error("session must be idle to delete")
        False ->
          family.claim_deletion(
            runtime.ledger(state.host),
            request,
            token,
            deadline,
          )
      }
      answer(state, reply, claimed)
    }
    CloseForDeletion(reply) -> {
      let state = session_state.State(..state, steering: [], booting: None)
      case turn.running(state.activity) {
        Some(run) -> {
          interrupt_kernel(state)
          kill(run.pid)
        }
        None -> Nil
      }
      case runtime.delete_session(state.host, state.info.id) {
        Error(error) -> answer(state, reply, Error(error))
        Ok(_) -> {
          active_output.revoke(state.home, state.info.id)
          cleanup_registrations(state.info.id)
          process.send(reply, Ok(Nil))
          actor.stop()
        }
      }
    }
    Close(reply) -> {
      case turn.running(state.activity) {
        Some(run) -> {
          interrupt_kernel(state)
          kill(run.pid)
          forget(state)
        }
        None -> close_idle(state)
      }
      process.send(reply, Nil)
      actor.stop()
    }
    Unload(reply) -> {
      let jobs = option.map(state.kernel, runtime.job_count) |> option.unwrap(0)
      case
        busy(state)
        || state.booting != None
        || state.steering != []
        || state.watchers != []
        || jobs > 0
      {
        True -> answer(state, reply, False)
        False -> {
          close_idle(state)
          process.send(reply, True)
          actor.stop()
        }
      }
    }
  }
}

/// Stop an idle session, keeping its kernel's variables first: a clean stop is
/// the other moment they are worth saving.
fn close_idle(state: State) -> Nil {
  case state.kernel {
    Some(kernel) -> {
      let _ =
        session_namespace.save_state_within(
          state.home,
          state.info.id,
          kernel,
          session_namespace.close_state_timeout,
        )
      Nil
    }
    None -> Nil
  }
  forget(state)
}

fn forget(state: State) -> Nil {
  runtime.forget_session(state.host, state.info.id)
  cleanup_registrations(state.info.id)
}

/// The registered command state seam: one operation in, session state out.
///
/// Runs on whichever process invoked the command (the kernel's host-call
/// process or an HTTP request process), so every branch that reads session
/// state is one actor call that reuses the ordinary message handlers instead
/// of duplicating their logic.
fn command_op(
  session: Session,
  host: runtime.Runtime,
  id: String,
  op: command.StateOp,
) -> Result(json.Json, String) {
  case op {
    command.ModelGet ->
      Ok(selection_json(actor.call(session, 5000, ReadSelection)))
    command.ModelSelect(model, provider, effort) ->
      actor.call(session, 5000, ChangeModel(model, provider, effort, True, _))
      |> result.map(selection_json)
    command.EffortGet -> actor.call(session, 5000, ReadEffort)
    command.EffortSelect(level) ->
      actor.call(session, 5000, ChangeEffort(level, _))
    command.ContextSummary -> Ok(context(session))
    // Switching strategy reloads the session's extensions first.
    command.Compact(strategy) ->
      compact_session(session, strategy)
      |> result.map(fn(report) {
        json.object([
          #("state", json.string(report.state)),
          #("strategy", json.nullable(report.effective_strategy, json.string)),
          #(
            "message",
            json.string(case report.failure {
              Some(reason) -> reason
              None -> "Compaction " <> report.state
            }),
          ),
        ])
      })
    command.Refresh ->
      reload(session)
      |> result.map(fn(reloaded) {
        json.object([
          #("reloaded", json.string("session")),
          #("warnings", json.array(reloaded.warnings, json.string)),
        ])
      })
    // Catalog fetches read no session state, so they stay off the actor.
    command.ReloadCatalogs ->
      runtime.reload_catalogs(host, id) |> result.map(catalogs_json)
    command.ContextPage(section, page) -> context_page(session, section, page)
    command.Submit(display, text, client) ->
      submitted(
        session,
        Submission(display, text, client, turn.Chat, [], None, None),
        "submitted",
      )
    command.Note(origin, display, text) ->
      submitted(
        session,
        Submission(display, text, "", turn.Note(origin), [], None, None),
        "queued",
      )
    command.KernelReport ->
      capture(session)
      |> result.map(fn(captured) {
        json.object([
          #("state", json.string(captured.kernel.state)),
          #(
            "instance_id",
            json.nullable(captured.kernel.instance_id, json.string),
          ),
          #("build", json.nullable(captured.kernel.build, json.string)),
          #(
            "live_job_count",
            json.nullable(captured.kernel.live_job_count, json.int),
          ),
        ])
      })
    command.KernelUpgrade ->
      upgrade_kernel(session)
      |> result.map(fn(report) {
        json.object([
          #("state", json.string(report.state)),
          #("warnings", json.array(report.warnings, json.string)),
          #("failure", json.nullable(report.failure, json.string)),
        ])
      })
    command.KernelJobs(project) ->
      capture(session)
      |> result.try(fn(captured) {
        case captured.kernel.running_jobs {
          Some(jobs) -> Ok(project(jobs, captured.kernel.live_job_count))
          None -> Error("kernel job observation unavailable")
        }
      })
    command.KernelStopJob(id) ->
      actor.call(session, 5000, StopJob(id, _))
      |> result.map(fn(_) { json.object([#("stopped", json.bool(True))]) })
  }
}

/// One command-routed submission: admitted like any other, reported as
/// `{"<key>": true}` when it lands.
fn submitted(
  session: Session,
  submission: Submission,
  key: String,
) -> Result(json.Json, String) {
  actor.call(session, 10_000, Submit(submission, _))
  |> result.map_error(submission_error)
  |> result.replace(json.object([#(key, json.bool(True))]))
}

/// `{"reloaded": [catalog, ..], "failed": {catalog: error, ..}}`.
fn catalogs_json(outcomes: List(#(String, Result(Nil, String)))) -> json.Json {
  let #(reloaded, failed) =
    list.fold_right(outcomes, #([], []), fn(acc, outcome) {
      case outcome {
        #(name, Ok(_)) -> #([json.string(name), ..acc.0], acc.1)
        #(name, Error(error)) -> #(acc.0, [#(name, json.string(error)), ..acc.1])
      }
    })
  json.object([
    #("reloaded", json.preprocessed_array(reloaded)),
    #("failed", json.object(failed)),
  ])
}

fn model_selection(info: conversation.Info) -> ModelSelection {
  ModelSelection(info.provider, info.model, info.protocol, info.effort)
}

fn selection_json(selection: ModelSelection) -> json.Json {
  json.object([
    #("provider", json.string(selection.provider)),
    #("model", json.string(selection.model)),
    #("protocol", json.string(conversation.protocol(selection.protocol))),
    #("effort", json.nullable(selection.effort, json.string)),
  ])
}

@external(erlang, "albedo_daemon", "directory")
fn directory(path: String) -> Bool

/// A turn needs a kernel in the workspace: a local folder that still exists,
/// or, when a kernel must boot, a host albedo can reach. A host still being
/// probed after a moment is left to the kernel's boot, which waits for the
/// probe and reports its failure; one known to need a sign-in or to be out
/// of reach is refused.
fn workspace_ready(state: State) -> Result(Nil, SubmissionError) {
  let cwd = state.info.cwd
  case location.parse(cwd) {
    // A kernel the session holds (attached, or reattaching through its
    // outbox) needs nothing from here: a dropped connection is its bridge's
    // to recover, and a host only matters again once that gives up.
    Ok(location.Remote(..)) if state.kernel != None -> Ok(Nil)
    Ok(location.Remote(..) as at) ->
      case location.ssh_target(at) {
        Error(Nil) -> Ok(Nil)
        Ok(target) -> {
          let recorded =
            python.recorded_for(runtime.ledger(state.host), state.info.id)
          case ssh.ready(target, 3000) {
            Ok(_) | Error(ssh.Warming) -> Ok(Nil)
            // A kernel on record is attached again in the background, and the
            // turn waits for it like any reattach.
            Error(ssh.NeedsAuth(..)) | Error(ssh.Unreachable(_)) if recorded ->
              Ok(Nil)
            // The turn waits blocked with ssh's words, and a sign-in (the
            // tui's ctrl+l) lets the next try through.
            Error(failure) -> Error(Rejected(ssh.describe(target, failure)))
          }
        }
      }
    _ ->
      case directory(cwd) {
        True -> Ok(Nil)
        False -> Error(WorkspaceMissing(cwd))
      }
  }
}

@external(erlang, "albedo_session", "kill")
fn kill(pid: process.Pid) -> Nil

@external(erlang, "albedo_inspect", "label")
fn label(kind: String, id: String) -> Nil

@external(erlang, "albedo_session", "collect")
fn collect() -> Nil

@external(erlang, "albedo_wakes", "register")
fn wakes_register(
  session: String,
  submit: fn(String, String, String) -> run.Wake,
) -> Nil

@external(erlang, "albedo_wakes", "forget")
fn wakes_forget(session: String) -> Nil

@external(erlang, "albedo_commands", "register")
fn commands_register(
  session: String,
  state_op: fn(command.StateOp) -> Result(json.Json, String),
) -> Nil

@external(erlang, "albedo_commands", "forget")
fn commands_forget(session: String) -> Nil

@external(erlang, "albedo_mailbox", "register")
fn mailbox_register(
  session: String,
  admit: fn(mail.Letter) -> Result(Bool, String),
) -> Nil

@external(erlang, "albedo_mailbox", "forget")
fn mailbox_forget(session: String) -> Nil

@external(erlang, "albedo_sessions", "register")
fn live_register(session: String, subject: Session) -> Nil

@external(erlang, "albedo_sessions", "forget")
fn live_forget(session: String) -> Nil

@external(erlang, "albedo_sessions", "find")
fn live_find(session: String) -> Result(Session, Nil)

fn owner_alive(session: Session) -> Bool {
  case process.subject_owner(session) {
    Ok(pid) -> process.is_alive(pid)
    Error(_) -> False
  }
}

/// The session's actor when one is already running, so nobody starts another.
pub fn live(id: String) -> Option(Session) {
  case live_find(id) {
    Ok(session) ->
      case owner_alive(session) {
        True -> Some(session)
        False -> None
      }
    Error(_) -> None
  }
}

@external(erlang, "albedo_session", "discard")
fn discard(path: String) -> Nil

fn prepare_submission(
  state: State,
) -> Result(#(State, runtime.Session, extension.Upstream), SubmissionError) {
  use _ <- result.try(workspace_ready(state))
  use state <- result.try(
    session_history.ensure_history(state) |> result.map_error(Rejected),
  )
  use #(state, client) <- result.try(
    session_provider.configured_client(state) |> result.map_error(Rejected),
  )
  case session_namespace.ready(state) {
    #(state, Some(kernel)) -> Ok(#(state, kernel, client))
    #(_, None) -> Error(Rejected("the session python kernel is not ready"))
  }
}

/// The state when a live kernel is here; otherwise `work` is parked until one
/// arrives and the state that asked for it comes back as the error.
fn kernel_or_park(state: State, work: Message) -> Result(State, State) {
  case session_namespace.ready(state) {
    #(state, Some(_)) -> Ok(state)
    #(state, None) -> Error(park(state, work))
  }
}

/// The kernel's notice (variables restored or lost) rides on the newest user
/// message, where the model reads it; the transcript keeps the message as sent.
/// The kernel notice reaches the model but not the ledger, as it does for a
/// chat message. Projection is newest-first: the head is this submission.
fn with_notice(
  history: List(types.Input),
  notice: Option(String),
) -> List(types.Input) {
  case notice, history {
    Some(notice), [types.User(text), ..rest] -> [
      types.User(text <> notice),
      ..rest
    ]
    Some(notice), [types.UserImage(text, image), ..rest] -> [
      types.UserImage(text <> notice, image),
      ..rest
    ]
    _, _ -> history
  }
}

/// Whether a turn is waiting for the kernel to boot before it can start.
fn waiting_turn(state: State) -> Bool {
  case state.booting {
    Some(#(_, parked)) ->
      list.contains(parked, StartQueued) || list.contains(parked, Resume)
    None -> False
  }
}

/// Running a turn, or about to once the kernel is up.
fn busy(state: State) -> Bool {
  turn.running(state.activity) != None || waiting_turn(state)
}

/// Keep `work` for when the kernel is ready, asking for one if nobody has.
fn park(state: State, work: Message) -> State {
  case state.booting {
    Some(#(attempts, parked)) ->
      case list.contains(parked, work) {
        True -> state
        False ->
          session_state.State(
            ..state,
            booting: Some(#(attempts, list.append(parked, [work]))),
          )
      }
    None -> {
      request_kernel(state)
      session_state.State(..state, booting: Some(#(1, [work])))
    }
  }
  |> session_state.announce
}

fn request_kernel(state: State) -> Nil {
  let self = state.self
  runtime.open_session_async(
    state.host,
    state.info.id,
    state.info.cwd,
    fn(result) { process.send(self, KernelOpened(result)) },
  )
}

/// The kernel arrived or failed. Parked work runs again on success; a lost
/// kernel is reset and asked for once more; any other failure fails only the
/// parked work. Queued letters are not lost: they stay undelivered, and the
/// dispatcher offers them again.
/// Adopting revives saved variables only for a session with history, so the
/// history is loaded first, as the old synchronous open did.
fn adopt(state: State, kernel: runtime.Session) -> State {
  session_history.ensure_history(state)
  |> result.unwrap(state)
  |> session_namespace.adopt(kernel)
}

fn kernel_opened(
  state: State,
  result: Result(runtime.Session, python.Error),
) -> State {
  case state.booting, result {
    None, Ok(kernel) ->
      case state.kernel {
        None -> adopt(state, kernel)
        // The held kernel is gone, so this arrival is its replacement: adopt
        // it, so its notice reaches the model, instead of dropping both the
        // kernel and the story about what the swap ended.
        Some(existing) ->
          case runtime.alive(existing) {
            False -> adopt(state, kernel)
            // An arrival nobody asked for while a live kernel serves: the
            // runtime still holds it for the session's next open.
            True -> state
          }
      }
    None, Error(_) -> state
    Some(#(attempts, parked)), Error(python.Lost) if attempts < 2 -> {
      runtime.reset_session(state.host, state.info.id)
      request_kernel(state)
      session_state.State(..state, booting: Some(#(attempts + 1, parked)))
    }
    Some(#(_, parked)), Ok(kernel) -> {
      let state = adopt(session_state.State(..state, booting: None), kernel)
      let state =
        list.fold(runtime.warnings(kernel), state, fn(state, warning) {
          session_state.emit(state, view.note("daemon", "Warning: " <> warning))
        })
      // Turns start here and now, so no status read can fall between the
      // kernel arriving and its turn starting; work that answers a caller is
      // handled as a message again.
      list.fold(parked, state, fn(state, work) {
        case work {
          StartQueued -> start_queued(state)
          Resume -> resume(state)
          other -> {
            process.send(state.self, other)
            state
          }
        }
      })
    }
    Some(#(_, parked)), Error(error) -> {
      let why =
        "could not start the session python kernel: "
        <> case error {
          python.Unavailable(message) | python.Invalid(message) -> message
          python.Lost -> "the kernel exited while starting"
          python.Busy | python.Detached -> "the kernel is busy"
        }
      list.fold(
        parked,
        session_state.State(..state, booting: None),
        fn(state, work) {
          case work {
            StartQueued -> failed_queued(state, why)
            Resume ->
              session_state.State(..state, activity: turn.Resting)
              |> session_state.emit(view.error(why))
            Compact(_, reply) -> {
              process.send(reply, Error(why))
              state
            }
            _ -> state
          }
        },
      )
    }
  }
}

fn failed_queued(state: State, error: String) -> State {
  let _ =
    operations.block(
      runtime.ledger(state.host),
      turn.operations(state.steering),
      error,
    )
  let _ = process.send_after(state.self, 15_000, StartQueued)
  session_state.emit(
    session_state.State(..state, blocked_until: clock.monotonic_ms() + 15_000),
    view.error("waiting inputs are blocked: " <> error),
  )
  |> session_submission.refresh_ids(turn.operations(state.steering))
  |> fn(state) { session_state.State(..state, active_submissions: []) }
}

/// A child whose run ends without having answered its parent's latest task or
/// message sends its last words, marked unreviewed, so nothing it found is
/// lost. Letters already queued here mean the child is not done yet.
fn answer_parent(state: State, outcome: Result(Nil, String)) -> State {
  let db = runtime.ledger(state.host)
  let owed = case turn.starts_turn(state.steering) {
    True -> Error(Nil)
    False ->
      case family.get(db, state.info.id) {
        Ok(Some(member)) ->
          case mail.owes_reply(db, state.info.id, member.parent) {
            Ok(True) -> Ok(member)
            _ -> Error(Nil)
          }
        _ -> Error(Nil)
      }
  }
  case owed {
    Error(_) -> state
    Ok(member) -> {
      let #(state, words) = last_words(state)
      let body = case outcome, words {
        Ok(_), Some(text) -> text
        Ok(_), None -> "(finished without writing anything)"
        Error(error), Some(text) -> "run failed: " <> error <> "\n\n" <> text
        Error(error), None -> "run failed: " <> error
      }
      case
        mail.post(
          db,
          mail.new_id(),
          member.parent,
          Some(state.info.id),
          member.name,
          mail.Answer(unreviewed: True),
          body,
        )
      {
        // Off the actor: the parent's actor may be the one calling into us.
        Ok(letter) -> {
          process.spawn_unlinked(fn() { mail.deliver(letter) })
          state
        }
        Error(error) ->
          session_state.emit(
            state,
            view.error("could not answer the parent: " <> error),
          )
      }
    }
  }
}

/// The newest assistant text in this session's transcript.
fn last_words(state: State) -> #(State, Option(String)) {
  case session_history.ensure_history(state) {
    Error(_) -> #(state, None)
    Ok(state) -> #(
      state,
      option.unwrap(state.history, [])
        |> list.find_map(fn(entry) {
          message_content.visible_assistant_text(entry.input)
          |> option.to_result(Nil)
        })
        |> option.from_result,
    )
  }
}

/// Whether a submission starts a run, waits in the queue, or is refused.
fn admit(
  state: State,
  submission: Submission,
  reply: Subject(Result(Bool, SubmissionError)),
) -> actor.Next(State, Message) {
  // Anything a client submits counts as attention.
  let state = stirred(state)
  case refused_image(state, submission) {
    #(state, Some(reason)) -> answer(state, reply, Error(Rejected(reason)))
    #(state, None) -> admit_within_limits(state, submission, reply)
  }
}

/// Why the session's provider would refuse one of the submission's images,
/// so it is turned away before the transcript keeps it rather than failing
/// every request after.
fn refused_image(
  state: State,
  submission: Submission,
) -> #(State, Option(String)) {
  case submission.images {
    [] -> #(state, None)
    images ->
      case session_provider.configured_client(state) {
        // Without a provider the turn is refused on its own when it starts.
        Error(_) -> #(state, None)
        Ok(#(state, client)) -> #(
          state,
          list.find_map(images, fn(image) {
            types.image_refusal(client.images, image) |> option.to_result(Nil)
          })
            |> option.from_result,
        )
      }
  }
}

fn admit_within_limits(
  state: State,
  submission: Submission,
  reply: Subject(Result(Bool, SubmissionError)),
) -> actor.Next(State, Message) {
  case turn.admit(state.activity, submission, list.length(state.steering)) {
    turn.Reject(turn.Busy) -> answer(state, reply, Error(Busy))
    turn.Reject(turn.Oversized) ->
      answer(
        state,
        reply,
        Error(Rejected("prompt or activation exceeds its bounded size")),
      )
    turn.Queue ->
      answer(
        session_state.State(
          ..state,
          steering: list.append(state.steering, [submission]),
        ),
        reply,
        Ok(True),
      )
    turn.Start ->
      case workspace_ready(state) {
        Error(error) -> answer(state, reply, Error(error))
        Ok(Nil) ->
          case session_namespace.ready(state) {
            // It starts once the kernel boots, not behind another turn, so to
            // the caller it is not queued; the actor keeps answering meanwhile.
            #(state, None) ->
              answer(
                park(
                  session_state.State(
                    ..state,
                    steering: list.append(state.steering, [submission]),
                  ),
                  StartQueued,
                ),
                reply,
                Ok(False),
              )
            #(state, Some(_)) -> start_now(state, submission, reply)
          }
      }
  }
}

fn resume(state: State) -> State {
  case
    prepare_turn_pipeline(state, list.append([restart_note], state.steering))
  {
    Error(#(state, err)) ->
      failed_queued(
        session_state.State(..state, activity: turn.Resting),
        submission_error(err),
      )
    Ok(#(state, kernel, client, history, run_id)) ->
      start_worker(state, kernel, client, history, turn.Turn(None), run_id)
  }
}

/// The plugin has committed its new projection. Clean up before the next
/// provider request, while the session actor serializes transcript writes.
fn elide_compacted_images(state: State) -> State {
  let elided = case context_snapshot.retained_tool_calls(state.context) {
    Some(calls) ->
      images.elide_evicted(runtime.ledger(state.host), state.info.id, calls)
    None -> Ok(0)
  }
  case elided {
    Ok(0) -> state
    Ok(_) -> session_state.State(..state, history: None)
    Error(error) ->
      session_state.emit(state, view.error("image cleanup skipped: " <> error))
  }
}

/// Wait for the compaction worker's observed outcome without retrying the action.
pub fn compact_session(
  session: Session,
  strategy: Option(String),
) -> Result(turn.CompactionReport, String) {
  actor_call.try_call(session, 185_000, Compact(strategy, _))
  |> result.replace_error(
    "compaction response unavailable; inspect session context",
  )
  |> result.flatten
}

fn compact(
  state: State,
  strategy: Option(String),
  reply: Subject(Result(turn.CompactionReport, String)),
) -> actor.Next(State, Message) {
  // The switch keeps its state even when compaction then fails: the runtime
  // already runs the new extension set.
  let #(state, selected) = case busy(state) {
    True -> #(state, Error("session must be idle to compact"))
    False -> select_strategy(state, strategy)
  }
  let report =
    turn.CompactionReport(
      selection_applied: strategy != None && result.is_ok(selected),
      effective_strategy: option.then(state.kernel, runtime.compaction_name),
      state: "failed",
      observation: None,
      failure: None,
    )
  let prepared = {
    use _ <- result.try(selected)
    use _ <- result.try(case turn.running(state.activity) {
      Some(_) -> Error("session must be idle to compact")
      None -> Ok(Nil)
    })
    use #(state, kernel, client) <- result.try(
      prepare_submission(state) |> result.map_error(submission_error),
    )
    use strategy <- result.try(case runtime.compaction_name(kernel) {
      Some(strategy) -> Ok(strategy)
      None -> Error("no compaction strategy is enabled")
    })
    use history <- result.try(projected_inputs(state))
    use _ <- result.try(case history {
      [] -> Error("no conversation history to compact")
      _ -> Ok(Nil)
    })
    let run_id = mail.new_id()
    use _ <- result.try(
      store.query(runtime.ledger(state.host), fn(db) {
        store.transaction(db, fn() {
          operations.begin_turn_in(
            db,
            state.info.id,
            run_id,
            usage.now(),
            Some(state.info.cwd),
          )
        })
      }),
    )
    Ok(#(state, kernel, client, strategy, history, run_id))
  }
  case prepared {
    Error(error) ->
      answer(
        state,
        reply,
        Ok(turn.CompactionReport(..report, failure: Some(error))),
      )
    Ok(#(state, kernel, client, strategy, history, run_id)) ->
      actor.continue(start_worker(
        state,
        kernel,
        client,
        history,
        turn.Compaction(
          reply,
          turn.CompactionReport(..report, effective_strategy: Some(strategy)),
        ),
        run_id,
      ))
  }
}

/// A named strategy becomes the session's own compaction extension, so the
/// projection it saves is the one every later request reads.
fn select_strategy(
  state: State,
  strategy: Option(String),
) -> #(State, Result(Nil, String)) {
  case strategy {
    None -> #(state, Ok(Nil))
    Some(name) ->
      case runtime.extension_summaries(state.host, state.info.id) {
        Error(error) -> #(state, Error(error))
        Ok(summaries) -> {
          let strategies =
            list.filter(summaries, fn(summary) {
              list.contains(summary.plugins, "compaction")
            })
          case list.find(strategies, fn(summary) { summary.name == name }) {
            Ok(_) -> {
              let #(state, outcome) =
                session_extensions.change(
                  state,
                  extension.SetSession(name, True),
                )
              let state = case outcome {
                Error(_) -> state
                Ok(_) -> {
                  let base = "/sessions/" <> state.info.id
                  bus.invalidate(
                    [base, base <> "?view=configuration", base <> "/catalog"],
                    [state.info.id],
                    False,
                  )
                  state
                  |> session_state.invalidate(
                    "settings",
                    base <> "?view=configuration",
                  )
                  |> session_state.invalidate("catalog", base <> "/catalog")
                }
              }
              #(state, result.replace(outcome, Nil))
            }
            Error(_) -> #(
              state,
              Error(
                "unknown compaction strategy "
                <> name
                <> "; available: "
                <> string.join(
                  list.map(strategies, fn(summary) { summary.name }),
                  ", ",
                ),
              ),
            )
          }
        }
      }
  }
}

fn prepare_turn_pipeline(
  state: State,
  submissions: List(Submission),
) -> Result(
  #(State, runtime.Session, extension.Upstream, List(types.Input), String),
  #(State, SubmissionError),
) {
  use state <- result.try(case turn.running(state.activity) {
    Some(_) -> Ok(state)
    None ->
      apply_workspace_state(state)
      |> result.map_error(fn(failure) { #(failure.0, Rejected(failure.1)) })
  })
  use #(state, kernel, client) <- result.try(
    prepare_submission(state) |> result.map_error(fn(err) { #(state, err) }),
  )
  let accepted =
    list.append(
      session_history.recover_pending(
        state.host,
        state.history,
        kernel,
        client.images,
      ),
      session_submission.inputs(submissions),
    )
  use history <- result.try(
    projected_inputs(session_history.remember(state, accepted, 0))
    |> result.map_error(fn(err) { #(state, Rejected(err)) }),
  )
  let run_id = mail.new_id()
  use timestamp <- result.try(
    conversation.commit_operations(
      runtime.ledger(state.host),
      state.info.id,
      accepted,
      conversation.Model,
      Some(state.info.provider),
      turn.letters(submissions),
      session_submission.commits(
        submissions,
        list.length(accepted)
          - list.length(session_submission.inputs(submissions)),
      ),
      run_id,
      state.info.cwd,
    )
    |> result.map_error(fn(err) { #(state, Rejected(err)) }),
  )
  let continuations =
    list.filter(submissions, fn(submission) {
      submission.source == turn.Continue
    })
    |> list.map(session_submission.input)
  let history =
    with_notice(list.append(list.reverse(continuations), history), state.notice)
  let state =
    session_history.remember(state, accepted, timestamp)
    |> session_submission.emit(submissions, timestamp)
    |> fn(state) {
      session_state.State(
        ..state,
        notice: None,
        steering: [],
        active_submissions: submissions,
        blocked_until: 0,
      )
    }
  Ok(#(state, kernel, client, history, run_id))
}

fn start_now(
  state: State,
  submission: Submission,
  reply: Subject(Result(Bool, SubmissionError)),
) -> actor.Next(State, Message) {
  // Notes queued while idle ride along ahead of this message.
  case prepare_turn_pipeline(state, list.append(state.steering, [submission])) {
    Error(#(state, err)) -> answer(state, reply, Error(err))
    Ok(#(state, kernel, client, history, run_id)) ->
      answer(
        start_worker(state, kernel, client, history, turn.Turn(None), run_id),
        reply,
        Ok(False),
      )
  }
}

fn finish_run(
  state: State,
  run: turn.Run,
  outcome: Result(Nil, String),
) -> actor.Next(State, Message) {
  case run.work {
    // A background call holds the session like a compaction run does, but
    // commits nothing and never reaches the transcript.
    turn.Background(reply) ->
      background_finish(state, run, reply, result.replace(outcome, None))
    _ -> finish_turn(state, run, outcome)
  }
}

fn finish_turn(
  state: State,
  run: turn.Run,
  outcome: Result(Nil, String),
) -> actor.Next(State, Message) {
  process.demonitor_process(run.monitor)
  let persisted =
    conversation.finish_turn(
      runtime.ledger(state.host),
      conversation.RunCompletion(
        state.info.id,
        run.id,
        turn.final_stage(run, outcome),
        case run.cancelled, outcome {
          True, _ -> "interrupted"
          _, Error(_) -> "failed"
          _, Ok(_) -> "completed"
        },
      ),
    )
  let state = clear_tool_progress(state)
  let state =
    session_state.State(
      ..state,
      activity: turn.Resting,
      active_output: active_output.retire(state.active_output),
    )
  bus.running(state.info.id, False)
  // A webhook or wake refused while this run held the session can
  // be admitted now.
  mail.waiting()
  let state = case run.work, run.cancelled, outcome, persisted {
    _, _, _, Error(error) ->
      session_state.emit(
        state,
        view.Failure(Some(run.id), "turn_persistence_failed", error),
      )
    _, True, _, Ok(_) -> state
    _, _, Error(error), _ ->
      session_state.emit(
        state,
        view.Failure(Some(run.id), "turn_failed", error),
      )
    // Compaction makes no provider request, so the footer's last real
    // usage is stale; the strategy's own estimate replaces it.
    turn.Compaction(..), _, Ok(_), Ok(_) -> {
      case context_snapshot.estimate(state.context) {
        Some(tokens) -> {
          let metadata =
            usage.Metadata(
              state.info.model,
              usage.now(),
              Some(usage.Tokens(tokens, 0, None, None, None, None, None)),
              None,
            )
          session_state.emit(
            session_state.State(..state, latest_usage: Some(metadata)),
            view.Usage(metadata),
          )
        }
        None -> state
      }
    }
    _, _, _, _ -> state
  }
  case run.work {
    turn.Compaction(reply, report) -> {
      let failure = case persisted, run.cancelled, outcome {
        Error(error), _, _ -> Some(error)
        _, True, _ -> Some("compaction interrupted")
        _, _, Error(error) -> Some(error)
        _, _, Ok(_) -> None
      }
      process.send(
        reply,
        Ok(
          turn.CompactionReport(
            ..report,
            state: case failure, report.observation {
              Some(_), _ -> "failed"
              None, Some(_) -> "compacted"
              None, None -> "unchanged"
            },
            failure: failure,
          ),
        ),
      )
    }
    _ -> Nil
  }
  let state = case run.work, run.cancelled, persisted {
    turn.Turn(_), False, Ok(_) -> answer_parent(state, outcome)
    _, _, _ -> state
  }
  let state = case run.work, persisted {
    turn.Turn(_), Ok(_) -> {
      let ids = turn.operations(state.active_submissions)
      state
      |> session_submission.refresh_ids(ids)
      |> session_state.emit(view.TurnCompleted(
        run.id,
        case run.cancelled, outcome {
          True, _ -> "interrupted"
          _, Error(_) -> "failed"
          _, Ok(_) -> "completed"
        },
        ids,
      ))
    }
    _, _ -> state
  }
  let state =
    session_state.State(..state, active_submissions: [])
    |> session_state.announce
  report_end(state, run)
  process.send(state.self, Collect)
  actor.continue(start_queued(follow_up(state)))
}

/// An extension's background call starts only while nothing else holds the
/// session and a live kernel can carry it; otherwise the caller hears why.
fn start_background(
  state: State,
  request: types.Request,
  prefix: requests.Prefix,
  reply: Subject(Result(Option(types.Usage), String)),
) -> State {
  let #(state, kernel) = session_namespace.ready(state)
  let refused = fn(state, reason) {
    process.send(reply, Error(reason))
    state
  }
  case turn.running(state.activity), kernel {
    Some(_), _ -> refused(state, "the session is busy")
    None, None -> refused(state, "the session has no live kernel")
    None, Some(_) ->
      case session_provider.configured_client(state) {
        Ok(#(primed, client)) ->
          session_run.start_background(
            primed,
            client,
            request,
            prefix,
            reply,
            BackgroundFinished,
          )
          |> session_state.announce
        Error(error) -> refused(state, error)
      }
  }
}

/// A background call ended. It never touched the transcript, so nothing
/// commits and nothing is announced; its caller gets the outcome, and the
/// submissions it held back start now.
fn background_finish(
  state: State,
  run: turn.Run,
  reply: Subject(Result(Option(types.Usage), String)),
  outcome: Result(Option(types.Usage), String),
) -> actor.Next(State, Message) {
  process.demonitor_process(run.monitor)
  process.send(reply, case run.cancelled {
    True -> Error("cancelled")
    False -> outcome
  })
  let state =
    session_state.State(..state, activity: turn.Resting)
    |> session_state.announce
  // A webhook or wake refused while the call held the session can be
  // admitted now.
  mail.waiting()
  actor.continue(start_queued(follow_up(state)))
}

/// A background call repeats the session's last turn call, so the provider's
/// cache clock starts over from it, warm or cold: the cached count fades from
/// there now, and clients hear the moved steps.
fn rewarmed(state: State, started: Int) -> State {
  case state.latest_usage {
    Some(usage.Metadata(cache: Some(fade), ..) as metadata) -> {
      let fade = cache_fade.reanchor(fade, started, usage.now())
      let metadata = usage.Metadata(..metadata, cache: Some(fade))
      case
        conversation.record_usage(
          runtime.ledger(state.host),
          state.info.id,
          metadata,
        )
      {
        Ok(_) ->
          session_state.emit(
            session_state.State(..state, latest_usage: Some(metadata)),
            view.Usage(metadata),
          )
        Error(_) -> state
      }
    }
    _ -> state
  }
}

/// A run that held the session ended: its extensions hear that a turn
/// ended, or that a compaction rewrote the history.
fn report_end(state: State, run: turn.Run) -> Nil {
  case run.work {
    turn.Turn(_) -> observe(state, extension.TurnEnded(run.cancelled))
    turn.Compaction(_, turn.CompactionReport(observation: Some(_), ..)) ->
      observe(state, extension.Compacted)
    turn.Compaction(..) -> Nil
    turn.Background(_) -> Nil
  }
}

/// Any new activity, which the session's extensions hear.
fn stirred(state: State) -> State {
  observe(state, extension.Stirred)
  state
}

/// Tells the extensions this session composed about one of its events. A
/// released kernel's session reports nothing: it cannot run anything either.
fn observe(state: State, event: extension.SessionEvent) -> Nil {
  case state.kernel {
    Some(kernel) ->
      runtime.observe(
        kernel,
        background_handle(state.info.id, state.self),
        event,
      )
    None -> Nil
  }
}

/// What an observer may ask of this session. It travels to the observer, so
/// it captures the actor's subject, never the state and its transcript.
fn background_handle(id: String, self: Session) -> extension.Session {
  extension.Session(
    id,
    fn(request, prefix) {
      case
        actor_call.try_call(self, 600_000, CallInBackground(request, prefix, _))
      {
        Ok(outcome) -> outcome
        Error(actor_call.TimedOut) ->
          Error("the background call went unanswered for ten minutes")
        Error(actor_call.CalleeDown) -> Error("the session stopped")
      }
    },
    fn(reason) { process.send(self, RefreshRequested(reason)) },
    fn() {
      actor_call.try_call(self, 5000, ReadAwaitingJobs)
      |> result.unwrap(False)
    },
  )
}

/// Whether a live job that is not a service runs in the kernel. Jobs the
/// kernel cannot list, such as a remote one with no summary, do not count.
fn awaiting_jobs(state: State) -> Bool {
  case session_namespace.observe_kernel(state) {
    Ok(session_namespace.KernelObservation(running_jobs: Some(jobs), ..)) ->
      list.any(jobs, fn(job) { !job.service })
    _ -> False
  }
}

fn start_queued(state: State) -> State {
  case turn.running(state.activity) {
    Some(_) -> state
    None ->
      case
        state.blocked_until != 0 && clock.monotonic_ms() < state.blocked_until
      {
        True -> state
        False -> start_waiting(state)
      }
  }
}

fn start_waiting(state: State) -> State {
  case state.booting {
    Some(_) -> start_waiting_in_workspace(state)
    None ->
      case apply_workspace_state(state) {
        Error(#(state, error)) -> failed_queued(state, error)
        Ok(state) -> start_waiting_in_workspace(state)
      }
  }
}

fn start_waiting_in_workspace(state: State) -> State {
  // `kernel_or_park` asks for a kernel as a side effect, so it only runs when
  // its answer is kept: a Gleam `case` evaluates both subjects before
  // matching, so parking behind a False `starts_turn` started a swap whose
  // arriving kernel was then dropped with no notice, killing the old kernel
  // and the wakes it still owed.
  case turn.starts_turn(state.steering) {
    False -> state
    True ->
      case kernel_or_park(state, StartQueued) {
        Error(state) -> state
        Ok(state) ->
          case prepare_turn_pipeline(state, state.steering) {
            Error(#(state, err)) -> failed_queued(state, submission_error(err))
            Ok(#(state, kernel, client, history, run_id)) ->
              start_worker(
                state,
                kernel,
                client,
                history,
                turn.Turn(None),
                run_id,
              )
          }
      }
  }
}

/// Deliver one job wake as an ordinary submission. Runs in the kernel's route
/// process, so it waits with its own deadline instead of `actor.call`, whose
/// timeout would crash the route: an owner too occupied to answer is busy and
/// the kernel retries; only a stopped owner is unavailable.
fn wake(session: Session, submission: Submission) -> run.Wake {
  case owner_alive(session) {
    False -> run.Unavailable("session stopped")
    True -> {
      let reply = process.new_subject()
      process.send(session, Submit(submission, reply))
      case process.receive(reply, 10_000) {
        Ok(Ok(_)) -> run.Delivered
        Ok(Error(Busy)) | Error(Nil) -> run.Busy
        Ok(Error(error)) -> run.Unavailable(submission_error(error))
      }
    }
  }
}

fn start_worker(
  state: State,
  kernel: runtime.Session,
  client: extension.Upstream,
  model_history: List(types.Input),
  work: turn.Work,
  run_id: String,
) -> State {
  bus.running(state.info.id, True)
  let state = stirred(state)
  session_run.start(
    state,
    kernel,
    client,
    model_history,
    work,
    run_id,
    session_run.Messages(
      Publish,
      ToolProgressDelta,
      ToolProgressRunning,
      ToolProgressReset,
      ToolProgressFinish,
      Commit,
      CommitFits,
      RecordContext,
      RecordUsage,
      DrainSteering,
      ReportPin,
      ReportSent,
      Finished,
      Collect,
    ),
  )
  |> session_state.announce
}

fn projected_inputs(state: State) -> Result(List(types.Input), String) {
  session_history.projected_for(
    state.history,
    state.info.provider,
    state.info.protocol,
  )
  |> result.map_error(fn(error) { "cannot prepare model history: " <> error })
}

/// Commit the desired destination for the captured family before kernel work.
pub fn change_workspace(
  session: Session,
  request: session_workspace.Request,
) -> Result(session_workspace.Recorded, session_workspace.ChangeFailure) {
  actor.call(session, 20_000, ChangeWorkspace(request, _))
}

/// Apply a recorded destination, or report that an existing run still owns it.
pub fn apply_workspace(session: Session) -> Result(Bool, String) {
  actor.call(session, 20_000, ApplyWorkspace)
}

fn workspace_changed(state: State) -> State {
  bus.invalidate(
    [
      "/sessions/" <> state.info.id,
      "/sessions/" <> state.info.id <> "?view=configuration",
    ],
    [state.info.id],
    False,
  )
  state
  |> session_state.invalidate("session", "/sessions/" <> state.info.id)
  |> session_state.invalidate(
    "settings",
    "/sessions/" <> state.info.id <> "?view=configuration",
  )
}

fn apply_workspace_state(state: State) -> Result(State, #(State, String)) {
  let ledger = runtime.ledger(state.host)
  use pending <- result.try(
    store.query(ledger, fn(db) {
      session_workspace.pending_in(db, state.info.id)
    })
    |> result.map_error(fn(error) { #(state, error) }),
  )
  case pending {
    None -> Ok(state)
    Some(pending) -> {
      use _ <- result.try(
        location.workspace(pending.desired)
        |> result.map_error(fn(error) { #(state, error.detail) }),
      )
      let reset_namespace = pending.desired != state.info.cwd
      use state <- result.try(case reset_namespace {
        False -> Ok(state)
        True -> {
          use _ <- result.try(
            runtime.delete_session(state.host, state.info.id)
            |> result.map_error(fn(error) { #(state, error) }),
          )
          discard_state(state.home, state.info.id)
          Ok(
            session_state.State(
              ..state,
              kernel: None,
              notice: Some(session_namespace.lost_notice),
              context: session_state.unprepared(),
            ),
          )
        }
      })
      use applied <- result.try(
        session_workspace.applied(ledger, state.info.id, pending)
        |> result.map_error(fn(error) { #(state, error) }),
      )
      case applied {
        False -> Ok(state)
        True -> {
          let state =
            session_state.State(
              ..state,
              info: conversation.Info(..state.info, cwd: pending.desired),
            )
            |> workspace_changed
          Ok(case reset_namespace {
            False -> state
            True ->
              session_state.emit(
                state,
                view.note(
                  "workspace",
                  "workspace changed; python variables were cleared, the transcript is intact",
                ),
              )
          })
        }
      }
    }
  }
}

/// A busy session makes the move it owes an ancestor when its run ends.
fn settle(state: State) -> State {
  case busy(state) || state.booting != None {
    True -> state
    False -> follow_up(state)
  }
}

/// Failed application leaves the destination durable. Turn admission reports
/// the failure before using an old kernel; a later attempt may apply it.
fn follow_up(state: State) -> State {
  case apply_workspace_state(state) {
    Ok(state) -> state
    Error(#(state, _)) -> state
  }
}

/// Admission commits before kernel or provider preparation begins.
pub fn admit_durable(
  worker: Session,
  operation: operations.Request,
  submission: Submission,
) -> Result(operations.Receipt, String) {
  actor.call(worker, 15_000, AdmitOperation(operation, submission, _))
}

pub fn continuation(client: String, operation_id: String) -> Submission {
  Submission(
    "",
    continue_prompt,
    client,
    turn.Continue,
    [],
    None,
    Some(operation_id),
  )
}

fn admit_operation(
  state: State,
  operation: operations.Request,
  submission: Submission,
  reply: Subject(Result(operations.Receipt, String)),
) -> actor.Next(State, Message) {
  let db = runtime.ledger(state.host)
  case operations.check(db, operation) {
    Error(error) -> answer(state, reply, Error(error))
    Ok(Some(receipt)) -> answer(state, reply, Ok(receipt))
    Ok(None) -> {
      let #(state, image_error) = refused_image(state, submission)
      let refusal = case
        image_error,
        turn.admit(state.activity, submission, list.length(state.steering))
      {
        Some(reason), _ ->
          Some(operations.Rejection(409, "image_rejected", reason))
        _, turn.Reject(turn.Busy) -> {
          case
            turn.admit(turn.Resting, submission, list.length(state.steering))
          {
            turn.Reject(turn.Busy) ->
              Some(operations.Rejection(
                429,
                "queue_full",
                "the session input queue is full",
              ))
            _ ->
              Some(operations.Rejection(
                409,
                "session_busy",
                "the session cannot admit this input while busy",
              ))
          }
        }
        _, turn.Reject(turn.Oversized) ->
          Some(operations.Rejection(
            413,
            "input_too_large",
            "prompt or activation exceeds its bounded size",
          ))
        _, _ -> None
      }
      case refusal {
        Some(reason) ->
          answer(state, reply, operations.reject(db, operation, reason))
        None -> {
          case
            operations.admit_pending(
              db,
              operation,
              session_submission.encode(submission),
              202,
              "",
            )
          {
            Error(error) -> answer(state, reply, Error(error))
            Ok(receipt) -> {
              let state =
                session_state.State(
                  ..state,
                  steering: list.append(state.steering, [submission]),
                )
              process.send(state.self, StartQueued)
              answer(
                session_submission.observed(state, submission)
                  |> session_state.announce,
                reply,
                Ok(receipt),
              )
            }
          }
        }
      }
    }
  }
}

fn interrupt_waiting(
  state: State,
  reply: Subject(Bool),
) -> actor.Next(State, Message) {
  let waiting = state.steering != [] || waiting_turn(state)
  case turn.running(state.activity), waiting {
    None, True -> {
      let state =
        clear_tool_progress(state)
        |> session_submission.refresh_ids(turn.operations(state.steering))
      answer(
        session_state.State(
          ..state,
          steering: [],
          active_submissions: [],
          blocked_until: 0,
          booting: option.map(state.booting, fn(boot) {
            #(
              boot.0,
              list.filter(boot.1, fn(work) {
                work != StartQueued && work != Resume
              }),
            )
          }),
        )
          |> session_state.announce,
        reply,
        True,
      )
    }
    None, False -> answer(state, reply, False)
    Some(run), _ -> {
      interrupt_kernel(state)
      let _ = process.send_after(state.self, 2500, Abort(run.id))
      let state = clear_tool_progress(state)
      answer(
        session_state.State(
          ..state,
          steering: [],
          blocked_until: 0,
          activity: turn.cancel(state.activity),
        )
          |> session_state.announce,
        reply,
        True,
      )
    }
  }
}

fn clear_tool_progress(state: State) -> State {
  let had_calls = tool_progress_state.has_calls(state.tool_progress)
  let state = invalidate_progress_timer(state)
  let state =
    session_state.State(
      ..state,
      tool_progress: tool_progress_state.clear(state.tool_progress),
    )
  case had_calls {
    False -> state
    True -> session_state.emit(state, view.clear_tool_progress())
  }
}

@external(erlang, "albedo_session", "new_generation")
fn new_generation() -> String
