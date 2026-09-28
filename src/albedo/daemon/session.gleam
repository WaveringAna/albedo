//// One coordinator per session. Workers own model/tool loops; clients never own workers.

import albedo/daemon/bus
import albedo/daemon/context_snapshot
import albedo/daemon/conversation
import albedo/daemon/event_buffer
import albedo/daemon/events as view
import albedo/daemon/family
import albedo/daemon/images
import albedo/daemon/mail
import albedo/daemon/requests
import albedo/daemon/session_extensions
import albedo/daemon/session_history
import albedo/daemon/session_namespace
import albedo/daemon/session_provider
import albedo/daemon/session_run
import albedo/daemon/session_state
import albedo/daemon/session_submission
import albedo/daemon/turn.{type Submission, Submission}
import albedo/daemon/usage
import albedo/harness/command
import albedo/harness/extension
import albedo/harness/extensions/python/kernel as python
import albedo/harness/extensions/run/extension as run
import albedo/harness/loop
import albedo/harness/runtime
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
  None,
)

pub const continue_prompt = "<system-notice>
continue your unfinished task, by resuming the most recent intent.
if interrupted mid-step, just pick it back up from where it stopped.
never pause to summarize progress, re-confirm the plan, or ask whether to proceed.
just continue.
</system-notice>"

pub type Session =
  Subject(Message)

pub type Page {
  Page(cursor: Int, reset: Bool, events: List(String))
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
  Abort(String)
  Submit(Submission, Subject(Result(Bool, SubmissionError)))
  ReadCommands(
    Subject(Result(#(List(command.Command), command.Context), String)),
  )
  ReadSelection(Subject(ModelSelection))
  ChangeWorkspace(String, Subject(Result(String, String)))
  /// An ancestor left the first workspace for the second.
  Follow(String, String, Subject(Nil))
  ReadExtensions(Subject(Result(List(extension.Summary), String)))
  ChangeExtension(
    extension.Change,
    Subject(Result(List(extension.Summary), String)),
  )
  Interrupt(Subject(Bool))
  ChangeModel(
    String,
    Option(String),
    Option(String),
    Subject(Result(ModelSelection, String)),
  )
  ReadEffort(Subject(Result(json.Json, String)))
  ChangeEffort(String, Subject(Result(json.Json, String)))
  Status(Subject(String))
  Read(Int, Option(Int), Subject(Page))
  Watch(process.Pid, fn() -> Nil)
  Publish(String, String, Subject(Bool))
  Commit(
    String,
    List(types.Input),
    conversation.Stage,
    Option(Int),
    Subject(Result(#(Int, Option(Int)), String)),
  )
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
  BackgroundFinished(String, Result(Option(types.Usage), String))
  Compact(Option(String), Subject(Result(json.Json, String)))
  RefreshData(Subject(Result(json.Json, String)))
  DrainSteering(String, Subject(Result(List(types.Input), String)))
  ReadContext(Subject(json.Json))
  ReadContextPage(String, Int, Subject(Result(json.Json, String)))
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
  /// The runtime answered this session's kernel request.
  KernelOpened(Result(runtime.Session, python.Error))
  /// Start a turn for what waits in the queue, now that the kernel is here.
  StartQueued
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
    use latest_usage <- result.try(conversation.load_usage(
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
    let info = case info.effort {
      Some(_) -> info
      None -> {
        let efforts =
          session_provider.model_efforts(host, home, info.provider, info.model)
        case extension.default_effort(efforts) {
          Some(def) -> {
            let _ =
              conversation.set_effort(runtime.ledger(host), info.id, Some(def))
            conversation.Info(..info, effort: Some(def))
          }
          None -> info
        }
      }
    }
    let state =
      session_state.State(
        info,
        host,
        None,
        home,
        self,
        None,
        latest_usage,
        activity,
        [],
        0,
        event_buffer.new(),
        [],
        None,
        session_state.unprepared(),
        case pinned {
          Some(#(prompt, head)) -> loop.Pinned(prompt, Some(head))
          None -> loop.Unpinned
        },
        None,
        now_ms(),
        None,
        None,
      )
    // Background jobs wake this session through the kernel's jobs route; the
    // registered closure lands a completion notice as an ordinary submit, so
    // the wake reuses the whole turn pipeline and busy answers itself.
    wakes_register(info.id, fn(display, text) {
      wake(self, Submission(display, text, "job", turn.JobWake, None))
    })
    commands_register(info.id, fn(op) { command_op(self, op) })
    live_register(info.id, self)
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
      None,
    ),
  )
}

pub fn submit(
  session: Session,
  text: String,
  client_id: String,
  image: Option(types.Image),
) -> Result(Bool, SubmissionError) {
  call_submit(session, Submission(text, text, client_id, turn.Chat, image))
}

pub fn submit_continue(
  session: Session,
  client_id: String,
) -> Result(Bool, SubmissionError) {
  call_submit(
    session,
    Submission("", continue_prompt, client_id, turn.Continue, None),
  )
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

pub fn status(session: Session) -> String {
  actor.call(session, 5000, Status)
}

/// Register a wake callback for one streaming client. The callback runs in the
/// session process and must only notify; dead watchers are dropped.
pub fn watch(session: Session, owner: process.Pid, notify: fn() -> Nil) -> Nil {
  process.send(session, Watch(owner, notify))
}

/// Events after `after`. A reset (a new or lagging client) replays the
/// transcript: whole, or with `tail` only its newest rows, which the client
/// pages back from with `history.rendered`.
pub fn read(session: Session, after: Int, tail: Option(Int)) -> Page {
  actor.call(session, 5000, Read(after, tail, _))
}

pub fn context(session: Session) -> json.Json {
  actor.call(session, 5000, ReadContext)
}

pub fn context_page(
  session: Session,
  section: String,
  page: Int,
) -> Result(json.Json, String) {
  actor.call(session, 5000, ReadContextPage(section, page, _))
}

/// Remove the saved variables after a session has stopped.
pub fn discard_state(home: String, id: String) -> Nil {
  case session_namespace.state_path(home, id) {
    Some(path) -> discard(path)
    None -> Nil
  }
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

fn call_submit(
  session: Session,
  submission: Submission,
) -> Result(Bool, SubmissionError) {
  actor.call(session, 10_000, Submit(submission, _))
}

fn transcript_error_events(error: String) -> List(String) {
  [
    view.event("reset", []),
    view.text("error", "could not load transcript: " <> error),
  ]
}

fn transcript_error(sequence: Int, error: String) -> Page {
  Page(sequence, True, transcript_error_events(error))
}

fn cleanup_registrations(id: String) -> Nil {
  wakes_forget(id)
  commands_forget(id)
  mailbox_forget(id)
  live_forget(id)
}

fn handle(state: State, message: Message) {
  // Anything a client sends counts as attention; a detached session goes quiet.
  let state = case message {
    Submit(..)
    | ReadCommands(..)
    | Interrupt(..)
    | Status(..)
    | Read(..)
    | ReadContext(..)
    | ReadContextPage(..)
    | ChangeModel(..)
    | Compact(..)
    | RefreshData(..)
    | ChangeWorkspace(..)
    | ReadExtensions(..)
    | ChangeExtension(..) -> session_state.State(..state, last_touch: now_ms())
    _ -> state
  }
  // Runs end in finish_turn and background_finish, which follow at once; this
  // catches a turn that never started, such as one whose kernel failed to boot.
  let state = settle(state)
  case message {
    Resume ->
      case kernel_or_park(state, Resume) {
        Error(state) -> actor.continue(state)
        Ok(state) -> actor.continue(resume(state))
      }
    KernelOpened(result) -> actor.continue(kernel_opened(state, result))
    StartQueued -> actor.continue(start_queued(state))
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
    ReadCommands(reply) ->
      answer(
        state,
        reply,
        runtime.peek_commands(state.host, state.info.id, state.info.cwd),
      )
    ReadSelection(reply) -> answer(state, reply, model_selection(state.info))
    Interrupt(reply) ->
      case turn.running(state.activity), waiting_turn(state) {
        // A turn still waiting for its kernel: drop it. Letters it held stay
        // undelivered, so the dispatcher offers them again later.
        None, True ->
          answer(
            session_state.State(
              ..state,
              steering: [],
              booting: option.map(state.booting, fn(boot) {
                #(
                  boot.0,
                  list.filter(boot.1, fn(work) {
                    work != StartQueued && work != Resume
                  }),
                )
              }),
            )
              |> session_state.emit(view.event("interrupted", [])),
            reply,
            True,
          )
        None, False -> answer(state, reply, False)
        Some(run), _ -> {
          interrupt_kernel(state)
          let _ = process.send_after(state.self, 2500, Abort(run.id))
          answer(
            session_state.State(..state, activity: turn.cancel(state.activity)),
            reply,
            True,
          )
        }
      }
    ChangeWorkspace(cwd, reply) -> {
      let state = stirred(state)
      let previous = state.info.cwd
      let moved = case turn.running(state.activity), directory(cwd) {
        Some(_), _ -> Error("session must be idle to change workspace")
        None, False -> Error("workspace must be an existing absolute directory")
        None, True -> relocate(state, cwd, "workspace changed")
      }
      case moved {
        Error(error) -> answer(state, reply, Error(error))
        Ok(state) -> answer(state, reply, Ok(previous))
      }
    }
    // A later move replaces an earlier one a busy session has not made yet.
    Follow(from, to, reply) ->
      case option.unwrap(state.following, state.info.cwd) == from {
        False -> state
        True -> settle(session_state.State(..state, following: Some(to)))
      }
      |> answer(reply, Nil)
    ReadExtensions(reply) ->
      answer(
        state,
        reply,
        runtime.extension_summaries(state.host, state.info.id),
      )
    ChangeExtension(change, reply) ->
      transition(reply, session_extensions.change(stirred(state), change))
    ChangeModel(model, provider_name, effort, reply) -> {
      let #(state, outcome) =
        session_provider.select(stirred(state), model, provider_name, effort)
      answer(
        state,
        reply,
        result.map(outcome, fn(_) { model_selection(state.info) }),
      )
    }

    ReadEffort(reply) ->
      answer(state, reply, session_provider.read_effort(state))
    ChangeEffort(level, reply) ->
      transition(reply, session_provider.change_effort(stirred(state), level))

    RefreshData(reply) -> transition(reply, session_extensions.refresh(state))
    Compact(strategy, reply) ->
      case
        turn.running(state.activity),
        kernel_or_park(state, Compact(strategy, reply))
      {
        None, Error(state) -> actor.continue(state)
        _, Ok(state) | Some(_), Error(state) -> compact(state, strategy, reply)
      }
    Status(reply) ->
      answer(
        state,
        reply,
        json.object([
          // A turn waiting for its kernel is already on its way.
          #("running", json.bool(busy(state))),
          #("idle", json.bool(!busy(state))),
          #(
            "phase",
            json.string(case state.booting {
              Some(_) -> "starting"
              None -> turn.phase(state.activity)
            }),
          ),
        ])
          |> json.to_string,
      )
    Watch(owner, notify) ->
      actor.continue(
        session_state.State(..state, watchers: [
          #(owner, notify),
          ..list.filter(state.watchers, fn(watcher) {
            process.is_alive(watcher.0) && watcher.0 != owner
          })
        ]),
      )
    Read(after, tail, reply) -> {
      case event_buffer.since(state.events, after, state.sequence) {
        Ok(events) -> answer(state, reply, Page(state.sequence, False, events))
        Error(_) if tail != None -> {
          let rows = option.unwrap(tail, 0)
          let events = case
            conversation.load_tail(
              runtime.ledger(state.host),
              state.info.id,
              None,
              rows,
            )
          {
            Error(error) -> transcript_error_events(error)
            Ok(#(entries, more)) -> [
              view.event("reset", view.page_fields(entries, more)),
              ..list.append(
                view.rows(runtime.ledger(state.host), entries),
                option.values([option.map(state.latest_usage, usage.event)]),
              )
            ]
          }
          answer(state, reply, Page(state.sequence, True, events))
        }
        Error(_) ->
          case session_history.ensure_history(state) {
            Error(error) ->
              answer(state, reply, transcript_error(state.sequence, error))
            Ok(state) -> {
              let history = state.history |> option.unwrap([]) |> list.reverse
              // A reset renders the transcript once for the client; keeping it
              // afterwards would hold every attached session's conversation in
              // memory between turns. The next turn reads it again.
              process.send(state.self, Collect)
              answer(
                session_state.State(..state, history: None),
                reply,
                Page(state.sequence, True, [
                  view.event("reset", []),
                  ..view.snapshot(
                    runtime.ledger(state.host),
                    history,
                    state.latest_usage,
                  )
                ]),
              )
            }
          }
      }
    }

    Publish(id, event, reply) ->
      case turn.live(state.activity, id) {
        True -> answer(session_state.emit(state, event), reply, True)
        False -> answer(state, reply, False)
      }
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
            )
          case written {
            Ok(#(timestamp, _)) ->
              answer(
                session_state.State(
                  ..session_history.remember_response(
                    state,
                    inputs,
                    timestamp,
                    thought_ms,
                  ),
                  activity: turn.committed(state.activity, id, stage),
                ),
                reply,
                written,
              )
            Error(_) -> answer(state, reply, written)
          }
        }
        _ -> answer(state, reply, Error("stale run"))
      }
    DrainSteering(id, reply) ->
      case turn.live(state.activity, id), state.steering {
        False, _ -> answer(state, reply, Error("cancelled"))
        True, [] -> answer(state, reply, Ok([]))
        True, queued -> {
          let inputs = list.map(queued, session_submission.input)
          case
            conversation.commit_letters(
              runtime.ledger(state.host),
              state.info.id,
              inputs,
              conversation.Model,
              Some(state.info.provider),
              turn.letters(queued),
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
                session_state.State(..state, steering: []),
                reply,
                Ok(inputs),
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
                view.text(
                  "error",
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
    BackgroundFinished(id, outcome) ->
      case turn.owner(state.activity, id) {
        Some(turn.Run(work: turn.Background(reply), ..) as run) ->
          background_finish(state, run, reply, outcome)
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
          }
          False -> state
        },
        reply,
        Nil,
      )
    ReadContext(reply) ->
      answer(state, reply, context_snapshot.summary(state.context))
    ReadContextPage(section, page, reply) ->
      answer(state, reply, context_snapshot.page(state.context, section, page))
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
                ),
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
    Down(process.ProcessDown(_, pid, _)) ->
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
          now_ms() - state.last_touch,
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
              |> session_state.emit(view.text(
                "note",
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
    Close(reply) -> {
      case turn.running(state.activity) {
        Some(run) -> {
          interrupt_kernel(state)
          kill(run.pid)
        }
        // A clean shutdown is the other moment variables are worth keeping.
        None ->
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
      }
      runtime.forget_session(state.host, state.info.id)
      cleanup_registrations(state.info.id)
      process.send(reply, Nil)
      actor.stop()
    }
  }
}

/// The registered command state seam: one operation in, session state out.
///
/// Runs on whichever process invoked the command (the kernel's host-call
/// process or an HTTP request process), so every branch is one actor call that
/// reuses the ordinary message handlers instead of duplicating their logic.
fn command_op(
  session: Session,
  op: command.StateOp,
) -> Result(json.Json, String) {
  case op {
    command.ModelGet ->
      Ok(selection_json(actor.call(session, 5000, ReadSelection)))
    command.ModelSelect(model, provider, effort) ->
      actor.call(session, 5000, ChangeModel(model, provider, effort, _))
      |> result.map(selection_json)
    command.EffortGet -> actor.call(session, 5000, ReadEffort)
    command.EffortSelect(level) ->
      actor.call(session, 5000, ChangeEffort(level, _))
    command.ContextSummary -> Ok(actor.call(session, 5000, ReadContext))
    // Switching strategy reloads the session's extensions first.
    command.Compact(strategy) ->
      actor.call(session, 60_000, Compact(strategy, _))
    command.Refresh -> actor.call(session, 30_000, RefreshData)
    command.ContextPage(section, page) ->
      actor.call(session, 5000, ReadContextPage(section, page, _))
    command.Submit(display, text, client) ->
      submitted(
        session,
        Submission(display, text, client, turn.Chat, None),
        "submitted",
      )
    command.Note(origin, display, text) ->
      submitted(
        session,
        Submission(display, text, "", turn.Note(origin), None),
        "queued",
      )
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

@external(erlang, "albedo_session", "kill")
fn kill(pid: process.Pid) -> Nil

@external(erlang, "albedo_inspect", "label")
fn label(kind: String, id: String) -> Nil

@external(erlang, "albedo_session", "collect")
fn collect() -> Nil

@external(erlang, "albedo_session", "now_ms")
fn now_ms() -> Int

@external(erlang, "albedo_wakes", "register")
fn wakes_register(
  session: String,
  submit: fn(String, String) -> run.Wake,
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
  use _ <- result.try(case directory(state.info.cwd) {
    True -> Ok(Nil)
    False -> Error(WorkspaceMissing(state.info.cwd))
  })
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
        Some(_) -> state
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
          session_state.emit(state, view.text("note", "Warning: " <> warning))
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
          python.Busy -> "the kernel is busy"
        }
      list.fold(
        parked,
        session_state.State(..state, booting: None),
        fn(state, work) {
          case work {
            StartQueued -> failed_queued(state, why)
            Resume ->
              session_state.State(..state, activity: turn.Resting)
              |> session_state.emit(view.text("error", why))
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
  session_state.emit(
    session_state.State(..state, steering: []),
    view.text(
      "error",
      "queued messages were not delivered; resend them: " <> error,
    ),
  )
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
            view.text("error", "could not answer the parent: " <> error),
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
          view.visible_assistant_text(entry.input) |> option.to_result(Nil)
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
      case directory(state.info.cwd), session_namespace.ready(state) {
        False, _ ->
          answer(state, reply, Error(WorkspaceMissing(state.info.cwd)))
        // It starts once the kernel boots, not behind another turn, so to
        // the caller it is not queued; the actor keeps answering meanwhile.
        True, #(state, None) ->
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
        True, #(state, Some(_)) -> start_now(state, submission, reply)
      }
  }
}

fn resume(state: State) -> State {
  case prepare_turn_pipeline(state, [restart_note]) {
    Error(#(state, err)) ->
      session_state.State(..state, activity: turn.Resting)
      |> session_state.emit(view.text("error", submission_error(err)))
    Ok(#(state, kernel, client, history)) ->
      start_run(state, kernel, client, history)
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
      session_state.emit(
        state,
        view.text("error", "image cleanup skipped: " <> error),
      )
  }
}

fn compact(
  state: State,
  strategy: Option(String),
  reply: Subject(Result(json.Json, String)),
) -> actor.Next(State, Message) {
  // The switch keeps its state even when compaction then fails: the runtime
  // already runs the new extension set.
  let #(state, selected) = select_strategy(state, strategy)
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
    Ok(#(state, kernel, client, strategy, history))
  }
  case prepared {
    Error(error) -> answer(state, reply, Error(error))
    Ok(#(state, kernel, client, strategy, history)) ->
      answer(
        start_worker(state, kernel, client, history, turn.Compaction),
        reply,
        Ok(
          json.object([
            #("started", json.bool(True)),
            #("strategy", json.string(strategy)),
            #("message", json.string("Compacting with " <> strategy <> "…")),
          ]),
        ),
      )
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
            Ok(extension.Summary(enabled: True, ..)) -> #(state, Ok(Nil))
            Ok(_) -> {
              let #(state, outcome) =
                session_extensions.change(
                  state,
                  extension.SetSession(name, True),
                )
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
  #(State, runtime.Session, extension.Upstream, List(types.Input)),
  #(State, SubmissionError),
) {
  use #(state, kernel, client) <- result.try(
    prepare_submission(state) |> result.map_error(fn(err) { #(state, err) }),
  )
  let accepted =
    list.append(
      session_history.recover_pending(state.host, state.history, kernel),
      list.map(submissions, session_submission.input),
    )
  use history <- result.try(
    projected_inputs(session_history.remember(state, accepted, 0))
    |> result.map_error(fn(err) { #(state, Rejected(err)) }),
  )
  use timestamp <- result.try(
    conversation.commit_letters(
      runtime.ledger(state.host),
      state.info.id,
      accepted,
      conversation.Model,
      Some(state.info.provider),
      turn.letters(submissions),
    )
    |> result.map_error(fn(err) { #(state, Rejected(err)) }),
  )
  let history = with_notice(history, state.notice)
  let state =
    session_history.remember(state, accepted, timestamp)
    |> session_submission.emit(submissions, timestamp)
    |> fn(state) { session_state.State(..state, notice: None, steering: []) }
  Ok(#(state, kernel, client, history))
}

fn start_now(
  state: State,
  submission: Submission,
  reply: Subject(Result(Bool, SubmissionError)),
) -> actor.Next(State, Message) {
  // Notes queued while idle ride along ahead of this message.
  case prepare_turn_pipeline(state, list.append(state.steering, [submission])) {
    Error(#(state, err)) -> answer(state, reply, Error(err))
    Ok(#(state, kernel, client, history)) ->
      answer(start_run(state, kernel, client, history), reply, Ok(False))
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
    conversation.commit_from(
      runtime.ledger(state.host),
      state.info.id,
      [],
      turn.final_stage(run, outcome),
      Some(state.info.provider),
    )
  let state = session_state.State(..state, activity: turn.Resting)
  bus.running(state.info.id, False)
  // A webhook or wake refused while this run held the session can
  // be admitted now.
  mail.waiting()
  let state = case run.cancelled, outcome, persisted {
    True, _, _ -> session_state.emit(state, view.event("interrupted", []))
    _, Error(error), _ -> session_state.emit(state, view.text("error", error))
    _, _, Error(error) -> session_state.emit(state, view.text("error", error))
    // Compaction makes no provider request, so the footer's last real
    // usage is stale; the strategy's own estimate replaces it.
    _, Ok(_), Ok(_) if run.work == turn.Compaction -> {
      let state = case context_snapshot.estimate(state.context) {
        Some(tokens) -> {
          let metadata =
            usage.Metadata(
              state.info.model,
              usage.now(),
              Some(usage.Tokens(tokens, 0, None, None, None, None, None)),
            )
          session_state.emit(
            session_state.State(..state, latest_usage: Some(metadata)),
            usage.event(metadata),
          )
        }
        None -> state
      }
      state
    }
    _, _, _ -> state
  }
  let state = case run.work, run.cancelled {
    turn.Turn(_), False -> answer_parent(state, outcome)
    _, _ -> state
  }
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
    None, Some(live) ->
      case session_provider.configured_client(state) {
        Ok(#(primed, client)) ->
          session_run.start_background(
            primed,
            live,
            client,
            request,
            prefix,
            reply,
            BackgroundFinished,
          )
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
  let state = session_state.State(..state, activity: turn.Resting)
  // A webhook or wake refused while the call held the session can be
  // admitted now.
  mail.waiting()
  actor.continue(start_queued(follow_up(state)))
}

/// A run that held the session ended: its extensions hear that a turn
/// ended, or that a compaction rewrote the history.
fn report_end(state: State, run: turn.Run) -> Nil {
  case run.work {
    turn.Turn(_) -> observe(state, extension.TurnEnded(run.cancelled))
    turn.Compaction -> observe(state, extension.Compacted)
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
  extension.Session(id, fn(request, prefix) {
    case
      session_run.try_call(self, 600_000, CallInBackground(request, prefix, _))
    {
      Ok(outcome) -> outcome
      Error(session_run.TimedOut) ->
        Error("the background call went unanswered for ten minutes")
      Error(session_run.CalleeDown) -> Error("the session stopped")
    }
  })
}

fn start_queued(state: State) -> State {
  case turn.starts_turn(state.steering), kernel_or_park(state, StartQueued) {
    False, _ -> state
    True, Error(state) -> state
    True, Ok(state) ->
      case prepare_turn_pipeline(state, state.steering) {
        Error(#(state, err)) -> failed_queued(state, submission_error(err))
        Ok(#(state, kernel, client, history)) ->
          start_run(state, kernel, client, history)
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

fn start_run(
  state: State,
  kernel: runtime.Session,
  client: extension.Upstream,
  model_history: List(types.Input),
) -> State {
  start_worker(state, kernel, client, model_history, turn.Turn(None))
}

fn start_worker(
  state: State,
  kernel: runtime.Session,
  client: extension.Upstream,
  model_history: List(types.Input),
  work: turn.Work,
) -> State {
  bus.running(state.info.id, True)
  let state = stirred(state)
  session_run.start(
    state,
    kernel,
    client,
    model_history,
    work,
    session_run.Messages(
      Publish,
      Commit,
      RecordContext,
      RecordUsage,
      DrainSteering,
      ReportPin,
      ReportSent,
      Finished,
      Collect,
    ),
  )
}

fn projected_inputs(state: State) -> Result(List(types.Input), String) {
  session_history.projected_for(
    state.history,
    state.info.provider,
    state.info.protocol,
  )
  |> result.map_error(fn(error) { "cannot prepare model history: " <> error })
}

/// Move an idle session to `cwd`; answers the workspace it left.
pub fn set_workspace(session: Session, cwd: String) -> Result(String, String) {
  actor.call(session, 20_000, ChangeWorkspace(cwd, _))
}

/// An ancestor left `from` for `to`; a session that was in `from` follows.
pub fn follow(session: Session, from: String, to: String) -> Nil {
  actor.call(session, 20_000, Follow(from, to, _))
}

/// Store the new workspace and, when it differs, drop the kernel, which
/// runs in the old one; `what` begins the note that says so.
fn relocate(state: State, cwd: String, what: String) -> Result(State, String) {
  use _ <- result.map(conversation.set_workspace(
    runtime.ledger(state.host),
    state.info.id,
    cwd,
  ))
  case cwd == state.info.cwd {
    True -> state
    False -> {
      runtime.forget_session(state.host, state.info.id)
      discard_state(state.home, state.info.id)
      session_state.State(
        ..state,
        kernel: None,
        info: conversation.Info(..state.info, cwd: cwd),
        notice: Some(session_namespace.lost_notice),
        context: session_state.unprepared(),
      )
      |> session_state.emit(view.text(
        "note",
        what <> "; python variables were cleared, the transcript is intact",
      ))
    }
  }
}

/// A busy session makes the move it owes an ancestor when its run ends.
fn settle(state: State) -> State {
  case busy(state) {
    True -> state
    False -> follow_up(state)
  }
}

/// Make the move an ancestor asked for. A folder gone by then is left alone.
fn follow_up(state: State) -> State {
  case state.following {
    None -> state
    Some(cwd) -> {
      let state = session_state.State(..state, following: None)
      let moved = case directory(cwd) {
        False -> Error(cwd <> " no longer exists")
        True -> relocate(state, cwd, "workspace moved with parent")
      }
      case moved {
        Ok(state) -> state
        Error(error) ->
          session_state.emit(
            state,
            view.text("note", "workspace did not move with parent: " <> error),
          )
      }
    }
  }
}

pub fn extensions(session: Session) -> Result(List(extension.Summary), String) {
  actor.call(session, 5000, ReadExtensions)
}

pub fn set_extension(
  session: Session,
  change: extension.Change,
) -> Result(List(extension.Summary), String) {
  actor.call(session, 40_000, ChangeExtension(change, _))
}
