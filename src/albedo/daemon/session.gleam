//// One coordinator per session. Workers own model/tool loops; clients never own workers.

import albedo/daemon/context_snapshot
import albedo/daemon/conversation
import albedo/daemon/events as view
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
import albedo/harness/extensions/bash/extension as bash
import albedo/harness/loop
import albedo/harness/runtime
import albedo/openai_api/types
import gleam/erlang/process.{type Subject}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result

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

fn submission_error(error: SubmissionError) -> String {
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
  ChangeWorkspace(String, Subject(Result(conversation.Info, String)))
  ReadExtensions(Subject(Result(List(extension.Summary), String)))
  ChangeExtension(
    extension.Change,
    Subject(Result(List(extension.Summary), String)),
  )
  Interrupt(Subject(Bool))
  ChangeModel(String, Option(String), Subject(Result(ModelSelection, String)))
  ReadEffort(Subject(Result(json.Json, String)))
  ChangeEffort(String, Subject(Result(json.Json, String)))
  Status(Subject(String))
  Read(Int, Subject(Page))
  Watch(process.Pid, fn() -> Nil)
  Publish(String, String, Subject(Bool))
  Commit(
    String,
    List(types.Input),
    conversation.Stage,
    Subject(Result(Int, String)),
  )
  RecordContext(String, context_snapshot.Snapshot, Subject(Nil))
  RecordUsage(String, usage.Metadata, Subject(Result(Nil, String)))
  ReportPin(String, Option(Int), Subject(Nil))
  Compact(Subject(Result(json.Json, String)))
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
        let efforts = case runtime.global(host) {
          Ok(extensions) ->
            case extension.model_info(extensions, info.model, "") {
              Some(m_info) -> m_info.efforts
              None -> []
            }
          Error(_) -> []
        }
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
        [],
        [],
        None,
        session_state.unprepared(),
        case pinned {
          Some(prompt) -> loop.Pinned(prompt, None)
          None -> loop.Unpinned
        },
        now_ms(),
      )
    // Background jobs wake this session through the kernel's jobs route; the
    // registered closure lands a completion notice as an ordinary submit, so
    // the wake reuses the whole turn pipeline and busy answers itself.
    wakes_register(info.id, fn(display, text) {
      wake(self, Submission(display, text, "bash", turn.JobWake, None))
    })
    commands_register(info.id, fn(op) { command_op(self, op) })
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

pub fn submit(
  session: Session,
  text: String,
  client_id: String,
  image: Option(types.Image),
) -> Result(Bool, SubmissionError) {
  actor.call(session, 10_000, Submit(
    Submission(text, text, client_id, turn.Chat, image),
    _,
  ))
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

pub fn read(session: Session, after: Int) -> Page {
  actor.call(session, 5000, Read(after, _))
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
/// cursor or durable ledger. Active runs always retain their prepared history.
pub fn evict_history(session: Session) -> Bool {
  actor.call(session, 5000, EvictHistory)
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
  case message {
    Resume -> {
      case prepare_submission(state) {
        Error(error) ->
          actor.continue(
            session_state.State(..state, activity: turn.Resting)
            |> session_state.emit(view.text("error", submission_error(error))),
          )
        Ok(#(state, kernel, client)) -> {
          let recovered =
            list.append(
              session_history.recover_pending(state.host, state.history, kernel),
              [
                session_submission.input(restart_note),
              ],
            )
          let candidate = session_history.remember(state, recovered, 0)
          case projected_inputs(candidate) {
            Error(error) ->
              actor.continue(
                session_state.State(..state, activity: turn.Resting)
                |> session_state.emit(view.text("error", error)),
              )
            Ok(model_history) ->
              case
                conversation.commit_from(
                  runtime.ledger(state.host),
                  state.info.id,
                  recovered,
                  conversation.Model,
                  Some(state.info.provider),
                )
              {
                Error(error) ->
                  actor.continue(session_state.emit(
                    state,
                    view.text("error", error),
                  ))
                Ok(timestamp) -> {
                  // The kernel notice reaches the model but not the ledger,
                  // as it does for a chat message.
                  let model_history = case state.notice, model_history {
                    Some(notice), [types.User(text), ..rest] -> [
                      types.User(text <> notice),
                      ..rest
                    ]
                    _, _ -> model_history
                  }
                  let state =
                    session_history.remember(state, recovered, timestamp)
                    |> session_state.emit(session_submission.event(
                      restart_note,
                      timestamp,
                    ))
                  actor.continue(start_run(
                    session_state.State(..state, notice: None),
                    kernel,
                    client,
                    model_history,
                  ))
                }
              }
          }
        }
      }
    }
    Abort(id) ->
      case turn.owner(state.activity, id) {
        Some(run) if run.cancelled -> {
          kill(run.pid)
          handle(state, Finished(id, Error("cancelled")))
        }
        _ -> actor.continue(state)
      }
    Submit(submission, reply) ->
      case turn.admit(state.activity, submission, list.length(state.steering)) {
        turn.Reject(turn.Busy) -> {
          process.send(reply, Error(Busy))
          actor.continue(state)
        }
        turn.Reject(turn.Oversized) -> {
          process.send(
            reply,
            Error(Rejected("prompt or activation exceeds its bounded size")),
          )
          actor.continue(state)
        }
        turn.Queue -> {
          process.send(reply, Ok(True))
          actor.continue(
            session_state.State(
              ..state,
              steering: list.append(state.steering, [submission]),
            ),
          )
        }
        turn.Start ->
          case prepare_submission(state) {
            Error(error) -> {
              process.send(reply, Error(error))
              actor.continue(state)
            }
            Ok(#(state, kernel, client)) -> {
              // Notes queued while idle ride along ahead of this message.
              let notes = state.steering
              let accepted =
                list.flatten([
                  session_history.recover_pending(
                    state.host,
                    state.history,
                    kernel,
                  ),
                  list.map(notes, session_submission.input),
                  [session_submission.input(submission)],
                ])
              case
                projected_inputs(session_history.remember(state, accepted, 0))
              {
                Error(error) -> {
                  process.send(reply, Error(Rejected(error)))
                  actor.continue(state)
                }
                Ok(history) -> {
                  // Projection is newest-first: the head is this submission.
                  let model_history = case state.notice {
                    None -> history
                    Some(notice) ->
                      case history {
                        [types.User(_), ..rest] -> [
                          types.User(submission.text <> notice),
                          ..rest
                        ]
                        [types.UserImage(_, image), ..rest] -> [
                          types.UserImage(submission.text <> notice, image),
                          ..rest
                        ]
                        _ -> history
                      }
                  }
                  case
                    conversation.commit_from(
                      runtime.ledger(state.host),
                      state.info.id,
                      accepted,
                      conversation.Model,
                      Some(state.info.provider),
                    )
                  {
                    Error(error) -> {
                      process.send(reply, Error(Rejected(error)))
                      actor.continue(state)
                    }
                    Ok(timestamp) -> {
                      let state =
                        session_history.remember(state, accepted, timestamp)
                        |> session_submission.emit(notes, timestamp)
                        |> fn(state) {
                          session_state.State(
                            ..state,
                            notice: None,
                            steering: [],
                          )
                        }
                        |> start_run(kernel, client, model_history)
                      process.send(reply, Ok(False))
                      actor.continue(session_state.emit(
                        state,
                        session_submission.event(submission, timestamp),
                      ))
                    }
                  }
                }
              }
            }
          }
      }
    ReadCommands(reply) -> {
      process.send(
        reply,
        runtime.peek_commands(state.host, state.info.id, state.info.cwd),
      )
      actor.continue(state)
    }
    ReadSelection(reply) -> {
      process.send(reply, model_selection(state.info))
      actor.continue(state)
    }
    Interrupt(reply) ->
      case turn.running(state.activity) {
        None -> {
          process.send(reply, False)
          actor.continue(state)
        }
        Some(run) -> {
          case state.kernel {
            Some(kernel) -> runtime.interrupt(kernel)
            None -> Nil
          }
          let _ = process.send_after(state.self, 2500, Abort(run.id))
          process.send(reply, True)
          actor.continue(
            session_state.State(..state, activity: turn.cancel(state.activity)),
          )
        }
      }
    ChangeWorkspace(cwd, reply) -> {
      let changed = case turn.running(state.activity), directory(cwd) {
        Some(_), _ -> Error("session must be idle to change workspace")
        None, False -> Error("workspace must be an existing absolute directory")
        None, True ->
          conversation.set_workspace(
            runtime.ledger(state.host),
            state.info.id,
            cwd,
          )
      }
      case changed {
        Error(error) -> {
          process.send(reply, Error(error))
          actor.continue(state)
        }
        Ok(_) -> {
          let state = case cwd == state.info.cwd {
            True -> state
            False -> {
              runtime.forget_session(state.host, state.info.id)
              case session_namespace.state_path(state.home, state.info.id) {
                Some(path) -> discard(path)
                None -> Nil
              }
              session_state.State(
                ..state,
                kernel: None,
                info: conversation.Info(..state.info, cwd: cwd),
                notice: Some(session_namespace.lost_notice),
                context: session_state.unprepared(),
              )
              |> session_state.emit(view.text(
                "note",
                "workspace changed; python variables were cleared, the transcript is intact",
              ))
            }
          }
          process.send(reply, Ok(state.info))
          actor.continue(state)
        }
      }
    }
    ReadExtensions(reply) -> {
      process.send(
        reply,
        runtime.extension_summaries(state.host, state.info.id),
      )
      actor.continue(state)
    }
    ChangeExtension(change, reply) -> {
      let #(state, outcome) = session_extensions.change(state, change)
      process.send(reply, outcome)
      actor.continue(state)
    }
    ChangeModel(model, provider_name, reply) -> {
      let #(state, outcome) =
        session_provider.select(state, model, provider_name)
      process.send(
        reply,
        result.map(outcome, fn(_) { model_selection(state.info) }),
      )
      actor.continue(state)
    }

    ReadEffort(reply) -> {
      process.send(reply, session_provider.read_effort(state))
      actor.continue(state)
    }
    ChangeEffort(level, reply) -> {
      let #(state, outcome) = session_provider.change_effort(state, level)
      process.send(reply, outcome)
      actor.continue(state)
    }

    RefreshData(reply) -> {
      let #(state, outcome) = session_extensions.refresh(state)
      process.send(reply, outcome)
      actor.continue(state)
    }
    Compact(reply) -> {
      let prepared = {
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
        Error(error) -> {
          process.send(reply, Error(error))
          actor.continue(state)
        }
        Ok(#(state, kernel, client, strategy, history)) -> {
          let state =
            start_worker(state, kernel, client, history, turn.Compaction)
          process.send(
            reply,
            Ok(
              json.object([
                #("started", json.bool(True)),
                #("strategy", json.string(strategy)),
                #("message", json.string("Compacting with " <> strategy <> "…")),
              ]),
            ),
          )
          actor.continue(state)
        }
      }
    }
    Status(reply) -> {
      process.send(
        reply,
        json.object([
          #("running", json.bool(turn.running(state.activity) != None)),
          #("idle", json.bool(turn.running(state.activity) == None)),
          #("phase", json.string(turn.phase(state.activity))),
        ])
          |> json.to_string,
      )
      actor.continue(state)
    }
    Watch(owner, notify) ->
      actor.continue(
        session_state.State(..state, watchers: [
          #(owner, notify),
          ..list.filter(state.watchers, fn(watcher) {
            process.is_alive(watcher.0) && watcher.0 != owner
          })
        ]),
      )
    Read(after, reply) -> {
      let oldest =
        list.last(state.events)
        |> result.map(fn(e) { e.0 })
        |> result.unwrap(state.sequence)
      let reset = after < 0 || after > state.sequence || after < oldest - 1
      case reset {
        False -> {
          let events =
            state.events
            |> list.filter(fn(e) { e.0 > after })
            |> list.reverse
            |> list.map(fn(e) { e.1 })
          process.send(reply, Page(state.sequence, False, events))
          actor.continue(state)
        }
        True ->
          case session_history.ensure_history(state) {
            Error(error) -> {
              process.send(
                reply,
                Page(state.sequence, True, [
                  view.event("reset", []),
                  view.text("error", "could not load transcript: " <> error),
                ]),
              )
              actor.continue(state)
            }
            Ok(state) -> {
              let history = state.history |> option.unwrap([]) |> list.reverse
              process.send(
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
              // A reset renders the transcript once for the client; keeping it
              // afterwards would hold every attached session's conversation in
              // memory between turns. The next turn reads it again.
              process.send(state.self, Collect)
              actor.continue(session_state.State(..state, history: None))
            }
          }
      }
    }

    Publish(id, event, reply) ->
      case turn.live(state.activity, id) {
        True -> {
          process.send(reply, True)
          actor.continue(session_state.emit(state, event))
        }
        False -> {
          process.send(reply, False)
          actor.continue(state)
        }
      }
    Commit(id, inputs, stage, reply) ->
      case turn.owner(state.activity, id) {
        Some(_) -> {
          // Completed tool results are saved even when cancellation was requested.
          let written =
            conversation.commit_from(
              runtime.ledger(state.host),
              state.info.id,
              inputs,
              stage,
              Some(state.info.provider),
            )
          process.send(reply, written)
          case written {
            Ok(timestamp) -> {
              let state = session_history.remember(state, inputs, timestamp)
              actor.continue(
                session_state.State(
                  ..state,
                  activity: turn.committed(state.activity, id, stage),
                ),
              )
            }
            Error(_) -> actor.continue(state)
          }
        }
        _ -> {
          process.send(reply, Error("stale run"))
          actor.continue(state)
        }
      }
    DrainSteering(id, reply) ->
      case turn.live(state.activity, id), state.steering {
        False, _ -> {
          process.send(reply, Error("cancelled"))
          actor.continue(state)
        }
        True, [] -> {
          process.send(reply, Ok([]))
          actor.continue(state)
        }
        True, queued -> {
          let inputs = list.map(queued, session_submission.input)
          case
            conversation.commit_from(
              runtime.ledger(state.host),
              state.info.id,
              inputs,
              conversation.Model,
              Some(state.info.provider),
            )
          {
            Error(error) -> {
              process.send(reply, Error(error))
              actor.continue(state)
            }
            Ok(timestamp) -> {
              let state =
                session_submission.emit(
                  session_history.remember(state, inputs, timestamp),
                  queued,
                  timestamp,
                )
              process.send(reply, Ok(inputs))
              actor.continue(session_state.State(..state, steering: []))
            }
          }
        }
      }
    ReportPin(id, head, reply) -> {
      process.send(reply, Nil)
      case turn.live(state.activity, id), head, state.pin {
        True, Some(head), loop.Pinned(prompt, _) ->
          actor.continue(
            session_state.State(..state, pin: loop.Pinned(prompt, Some(head))),
          )
        True, None, loop.Pinned(..) ->
          case
            conversation.clear_prompt_pin(
              runtime.ledger(state.host),
              state.info.id,
            )
          {
            Ok(_) ->
              actor.continue(session_state.State(..state, pin: loop.Unpinned))
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
    RecordContext(id, snapshot, reply) -> {
      process.send(reply, Nil)
      case turn.live(state.activity, id) {
        True -> actor.continue(session_state.State(..state, context: snapshot))
        False -> actor.continue(state)
      }
    }
    ReadContext(reply) -> {
      process.send(reply, context_snapshot.summary(state.context))
      actor.continue(state)
    }
    ReadContextPage(section, page, reply) -> {
      process.send(reply, context_snapshot.page(state.context, section, page))
      actor.continue(state)
    }
    RecordUsage(id, metadata, reply) ->
      case turn.owner(state.activity, id) {
        Some(_) -> {
          let written =
            conversation.record_usage(
              runtime.ledger(state.host),
              state.info.id,
              metadata,
            )
          process.send(reply, written)
          case written {
            Ok(_) ->
              actor.continue(
                session_state.State(
                  ..state,
                  latest_usage: Some(metadata),
                  context: context_snapshot.with_usage(state.context, metadata),
                ),
              )
            Error(_) -> actor.continue(state)
          }
        }
        _ -> {
          process.send(reply, Error("stale run"))
          actor.continue(state)
        }
      }
    Finished(id, outcome) ->
      case turn.owner(state.activity, id) {
        Some(run) -> {
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
          let state = case run.cancelled, outcome, persisted {
            True, _, _ ->
              session_state.emit(state, view.event("interrupted", []))
            _, Error(error), _ ->
              session_state.emit(state, view.text("error", error))
            _, _, Error(error) ->
              session_state.emit(state, view.text("error", error))
            // Compaction makes no provider request, so the footer's last real
            // usage is stale; the strategy's own estimate replaces it.
            _, Ok(_), Ok(_) if run.work == turn.Compaction -> {
              let state = case context_snapshot.estimate(state.context) {
                Some(tokens) -> {
                  let metadata =
                    usage.Metadata(
                      state.info.model,
                      usage.now(),
                      Some(usage.Tokens(tokens, 0, None)),
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
          process.send(state.self, Collect)
          actor.continue(start_queued(state))
        }
        _ -> actor.continue(state)
      }
    Down(process.ProcessDown(_, pid, _)) ->
      case turn.running(state.activity) {
        Some(run) if run.pid == pid ->
          handle(
            state,
            Finished(
              run.id,
              Error("worker stopped; execution may have had effects"),
            ),
          )
        _ -> actor.continue(state)
      }
    Down(_) -> actor.continue(state)
    Idle(reply) -> {
      let kernel = case state.kernel {
        Some(kernel) -> option.from_result(runtime.kernel_pid(kernel))
        None -> None
      }
      // Live background jobs keep their kernel: releasing it would kill work
      // the session still owes a wake for, so the reaper counts them.
      let jobs = case state.kernel {
        Some(kernel) -> runtime.job_count(kernel)
        None -> 0
      }
      process.send(
        reply,
        Report(
          turn.running(state.activity) != None,
          kernel,
          state.history != None,
          now_ms() - state.last_touch,
          jobs,
        ),
      )
      actor.continue(state)
    }
    Release(reply) ->
      case state.kernel, turn.running(state.activity) {
        Some(kernel), None -> {
          let saved =
            session_namespace.save_state(state.home, state.info.id, kernel)
          runtime.reset_session(state.host, state.info.id)
          process.send(reply, True)
          process.send(state.self, Collect)
          actor.continue(
            session_state.State(
              ..state,
              kernel: None,
              context: session_state.unprepared(),
            )
            |> session_state.emit(view.text(
              "note",
              session_namespace.released_text(saved, "nothing was attached"),
            )),
          )
        }
        _, _ -> {
          process.send(reply, False)
          actor.continue(state)
        }
      }
    EvictHistory(reply) ->
      case turn.running(state.activity) {
        Some(_) -> {
          process.send(reply, False)
          actor.continue(state)
        }
        None -> {
          let evicted = state.history != None
          process.send(reply, evicted)
          process.send(state.self, Collect)
          actor.continue(session_state.State(..state, history: None))
        }
      }
    Collect -> {
      collect()
      actor.continue(state)
    }
    Close(reply) -> {
      case turn.running(state.activity), state.kernel {
        Some(run), Some(kernel) -> {
          runtime.interrupt(kernel)
          kill(run.pid)
        }
        Some(run), None -> kill(run.pid)
        // A clean shutdown is the other moment variables are worth keeping.
        None, Some(kernel) -> {
          let _ =
            session_namespace.save_state_within(
              state.home,
              state.info.id,
              kernel,
              session_namespace.close_state_timeout,
            )
          Nil
        }
        None, None -> Nil
      }
      runtime.forget_session(state.host, state.info.id)
      wakes_forget(state.info.id)
      commands_forget(state.info.id)
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
    command.ModelSelect(model, provider) ->
      actor.call(session, 5000, ChangeModel(model, provider, _))
      |> result.map(selection_json)
    command.EffortGet -> actor.call(session, 5000, ReadEffort)
    command.EffortSelect(level) ->
      actor.call(session, 5000, ChangeEffort(level, _))
    command.ContextSummary -> Ok(actor.call(session, 5000, ReadContext))
    command.Compact -> actor.call(session, 15_000, Compact)
    command.Refresh -> actor.call(session, 30_000, RefreshData)
    command.ContextPage(section, page) ->
      actor.call(session, 5000, ReadContextPage(section, page, _))
    command.Submit(display, text, client) ->
      actor.call(session, 10_000, Submit(
        Submission(display, text, client, turn.Chat, None),
        _,
      ))
      |> result.map_error(submission_error)
      |> result.replace(json.object([#("submitted", json.bool(True))]))
    command.Note(origin, display, text) ->
      actor.call(session, 10_000, Submit(
        Submission(display, text, "", turn.Note(origin), None),
        _,
      ))
      |> result.map_error(submission_error)
      |> result.replace(json.object([#("queued", json.bool(True))]))
  }
}

fn model_selection(info: conversation.Info) -> ModelSelection {
  ModelSelection(info.provider, info.model, info.protocol, info.effort)
}

fn selection_json(selection: ModelSelection) -> json.Json {
  json.object([
    #("provider", json.string(selection.provider)),
    #("model", json.string(selection.model)),
    #("protocol", json.string(conversation.protocol(selection.protocol))),
    #("effort", case selection.effort {
      Some(e) -> json.string(e)
      None -> json.null()
    }),
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
  submit: fn(String, String) -> bash.Wake,
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
  use #(state, kernel) <- result.try(
    session_namespace.ensure_kernel(state) |> result.map_error(Rejected),
  )
  Ok(#(state, kernel, client))
}

/// The kernel opens on first use. A session with history had a namespace the
/// model still believes in, so its saved variables are revived and the gap named.
fn failed_queued(state: State, error: String) -> State {
  session_state.emit(
    session_state.State(..state, steering: []),
    view.text(
      "error",
      "queued messages were not delivered; resend them: " <> error,
    ),
  )
}

fn start_queued(state: State) -> State {
  case turn.starts_turn(state.steering) {
    False -> state
    True -> {
      let queued = state.steering
      case prepare_submission(state) {
        Error(error) -> failed_queued(state, submission_error(error))
        Ok(#(state, kernel, client)) -> {
          let accepted =
            list.append(
              session_history.recover_pending(state.host, state.history, kernel),
              list.map(queued, session_submission.input),
            )
          case projected_inputs(session_history.remember(state, accepted, 0)) {
            Error(error) -> failed_queued(state, error)
            Ok(history) ->
              case
                conversation.commit_from(
                  runtime.ledger(state.host),
                  state.info.id,
                  accepted,
                  conversation.Model,
                  Some(state.info.provider),
                )
              {
                Error(error) -> failed_queued(state, error)
                Ok(timestamp) -> {
                  let state =
                    session_submission.emit(
                      session_history.remember(state, accepted, timestamp),
                      queued,
                      timestamp,
                    )
                  start_run(
                    session_state.State(..state, steering: [], notice: None),
                    kernel,
                    client,
                    history,
                  )
                }
              }
          }
        }
      }
    }
  }
}

/// Deliver one job wake as an ordinary submission. Runs in the kernel's route
/// process, so it waits with its own deadline instead of `actor.call`, whose
/// timeout would crash the route: an owner too occupied to answer is busy and
/// the kernel retries; only a stopped owner is unavailable.
fn wake(session: Session, submission: Submission) -> bash.Wake {
  case process.subject_owner(session) {
    Error(_) -> bash.Unavailable("session stopped")
    Ok(owner) ->
      case process.is_alive(owner) {
        False -> bash.Unavailable("session stopped")
        True -> {
          let reply = process.new_subject()
          process.send(session, Submit(submission, reply))
          case process.receive(reply, 10_000) {
            Ok(Ok(_)) -> bash.Delivered
            Ok(Error(Busy)) | Error(Nil) -> bash.Busy
            Ok(Error(error)) -> bash.Unavailable(submission_error(error))
          }
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

pub fn set_workspace(
  session: Session,
  cwd: String,
) -> Result(conversation.Info, String) {
  actor.call(session, 20_000, ChangeWorkspace(cwd, _))
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
