//// One coordinator per session. Workers own model/tool loops; clients never own workers.

import albedo/daemon/configuration
import albedo/daemon/context_snapshot
import albedo/daemon/conversation
import albedo/daemon/events as view
import albedo/daemon/projection
import albedo/daemon/transcript
import albedo/daemon/turn.{type Submission, Submission}
import albedo/daemon/usage
import albedo/harness/command
import albedo/harness/extension
import albedo/harness/extensions/bash/extension as bash
import albedo/harness/extensions/python/kernel as python
import albedo/harness/loop
import albedo/harness/runtime
import albedo/openai_api/types
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string

const lost_notice = "<system-note>The python kernel got reset and all variables are lost</system-note>"

/// A kernel is opened on demand and released when nobody is attached, so an idle
/// session costs no operating system process. Variables outlive the kernel when
/// they can be written to disk; the model is told either way.
const state_timeout = 30_000

/// Shutdown waits on this per session, so a restart cannot stall behind a large
/// namespace. An idle release is nobody's wait and gets the full budget.
const close_state_timeout = 5000

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
  ModelSelection(provider: String, model: String, protocol: types.Protocol)
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
    String,
    Bool,
    Subject(Result(List(extension.Summary), String)),
  )
  Interrupt(Subject(Bool))
  ChangeModel(String, Option(String), Subject(Result(ModelSelection, String)))
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
  Close(Subject(Nil))
}

type State {
  State(
    info: conversation.Info,
    host: runtime.Runtime,
    kernel: Option(runtime.Session),
    home: String,
    self: Session,
    history: Option(List(transcript.Entry)),
    latest_usage: Option(usage.Metadata),
    activity: turn.Activity,
    steering: List(Submission),
    sequence: Int,
    events: List(#(Int, String)),
    watchers: List(#(process.Pid, fn() -> Nil)),
    notice: Option(String),
    context: context_snapshot.Snapshot,
    last_touch: Int,
  )
}

/// Starting a session costs no Python process; the first run opens the kernel.
pub fn start(
  host: runtime.Runtime,
  info: conversation.Info,
  home: String,
) -> Result(Session, actor.StartError) {
  actor.new_with_initialiser(10_000, fn(self) {
    use latest_usage <- result.try(conversation.load_usage(
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
    let state =
      State(
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
        unprepared(),
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

fn unprepared() -> context_snapshot.Snapshot {
  context_snapshot.pending(
    "runtime session has not prepared a provider request",
  )
}

/// Streaming clients are woken as each event is published, so a model delta
/// reaches a terminal without waiting for a polling interval.
fn emit(state: State, event: String) -> State {
  let seq = state.sequence + 1
  let events = trim([#(seq, event), ..state.events], 256, 4_194_304)
  let watchers =
    list.filter(state.watchers, fn(watcher) { process.is_alive(watcher.0) })
  list.each(watchers, fn(watcher) { watcher.1() })
  State(..state, sequence: seq, events: events, watchers: watchers)
}

fn trim(
  events: List(#(Int, String)),
  count: Int,
  bytes: Int,
) -> List(#(Int, String)) {
  case events {
    [] -> []
    [event, ..rest] -> {
      let size = string.byte_size(event.1)
      case count > 0 && size <= bytes {
        True -> [event, ..trim(rest, count - 1, bytes - size)]
        False -> []
      }
    }
  }
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
    | ChangeExtension(..) -> State(..state, last_touch: now_ms())
    _ -> state
  }
  case message {
    Resume -> {
      case prepare_submission(state) {
        Error(error) ->
          actor.continue(
            State(..state, activity: turn.Resting)
            |> emit(view.text("error", submission_error(error))),
          )
        Ok(#(state, kernel, client)) -> {
          let recovered = recover_pending(state, kernel)
          let candidate = remember(state, recovered, 0)
          case projected_inputs(candidate) {
            Error(error) ->
              actor.continue(
                State(..state, activity: turn.Resting)
                |> emit(view.text("error", error)),
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
                  actor.continue(emit(state, view.text("error", error)))
                Ok(timestamp) -> {
                  let state = remember(state, recovered, timestamp)
                  actor.continue(
                    start_run(state, kernel, client, model_history)
                    |> emit(view.text(
                      "error",
                      "runtime restarted; python namespace was reset. Resuming from saved work, not replaying cells.",
                    )),
                  )
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
            State(..state, steering: list.append(state.steering, [submission])),
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
                  recover_pending(state, kernel),
                  list.map(notes, submission_input),
                  [submission_input(submission)],
                ])
              case projected_inputs(remember(state, accepted, 0)) {
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
                        remember(state, accepted, timestamp)
                        |> emit_submissions(notes, timestamp)
                        |> fn(state) {
                          State(..state, notice: None, steering: [])
                        }
                        |> start_run(kernel, client, model_history)
                      process.send(reply, Ok(False))
                      actor.continue(emit(
                        state,
                        submission_event(submission, timestamp),
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
          actor.continue(State(..state, activity: turn.cancel(state.activity)))
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
              case state_path(state) {
                Some(path) -> discard(path)
                None -> Nil
              }
              State(
                ..state,
                kernel: None,
                info: conversation.Info(..state.info, cwd: cwd),
                notice: Some(lost_notice),
                context: unprepared(),
              )
              |> emit(view.text(
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
    ChangeExtension(name, enabled, reply) ->
      case turn.running(state.activity) {
        Some(_) -> {
          process.send(
            reply,
            Error("session must be idle to reload extensions"),
          )
          actor.continue(state)
        }
        None -> {
          let saved = case state.kernel {
            Some(kernel) ->
              save_state_within(state, kernel, close_state_timeout)
            None -> Error("no active python namespace")
          }
          case
            runtime.reload_extension(
              state.host,
              state.info.id,
              state.info.cwd,
              name,
              enabled,
            )
          {
            Error(error) -> {
              process.send(reply, Error(error))
              actor.continue(state)
            }
            Ok(kernel) -> {
              let restored = case saved, state_path(state) {
                Ok(_), Some(path) ->
                  runtime.load_state(kernel, path, state_timeout)
                _, _ -> Error(python.Invalid("namespace snapshot unavailable"))
              }
              let namespace = case state.kernel, restored {
                None, _ -> "new python namespace started"
                _, Ok(saved) -> restored_text(saved)
                _, Error(_) ->
                  "python namespace reset; unsaved variables were lost"
              }
              let state =
                State(
                  ..state,
                  kernel: Some(kernel),
                  latest_usage: None,
                  context: unprepared(),
                )
              let usage_cleared =
                conversation.clear_usage(
                  runtime.ledger(state.host),
                  state.info.id,
                )
              let state =
                state
                |> emit(view.text(
                  "note",
                  "extensions reloaded; prompt cache usage reset; " <> namespace,
                ))
              let state = case usage_cleared {
                Ok(_) -> state
                Error(error) ->
                  emit(
                    state,
                    view.text(
                      "error",
                      "extensions reloaded but cached usage metadata could not be cleared: "
                        <> error,
                    ),
                  )
              }
              let summaries =
                runtime.extension_summaries(state.host, state.info.id)
              process.send(reply, summaries)
              actor.continue(state)
            }
          }
        }
      }
    ChangeModel(model, provider_name, reply) -> {
      case
        turn.running(state.activity) == None
        && string.trim(model) != ""
        && string.byte_size(model) <= 512
        && !string.contains(model, "\r")
        && !string.contains(model, "\n")
      {
        False -> {
          process.send(reply, Error("model must be nonempty and session idle"))
          actor.continue(state)
        }
        True ->
          case ensure_history(state) {
            Error(error) -> {
              process.send(reply, Error(error))
              actor.continue(state)
            }
            Ok(state) -> {
              let selected = {
                use #(provider, protocol) <- result.try(case provider_name {
                  None -> Ok(#(state.info.provider, state.info.protocol))
                  Some(name) ->
                    configuration.named(state.home, name)
                    |> result.map(fn(configured) {
                      #(configured.name, configured.protocol)
                    })
                })
                let selection = ModelSelection(provider, model, protocol)
                use _ <- result.try(
                  projected_for(state, provider, protocol)
                  |> result.replace(Nil)
                  |> result.map_error(fn(error) {
                    "cannot switch provider: " <> error
                  }),
                )
                use _ <- result.try(configuration.select_default(
                  state.home,
                  provider,
                  model,
                ))
                use _ <- result.try(conversation.set_configuration(
                  runtime.ledger(state.host),
                  state.info.id,
                  provider,
                  model,
                  protocol,
                ))
                Ok(selection)
              }
              process.send(reply, selected)
              case selected {
                Ok(selection) ->
                  actor.continue(
                    State(
                      ..state,
                      history: option.map(state.history, tag_unknown_provider(
                        _,
                        state.info.provider,
                      )),
                      info: conversation.Info(
                        ..state.info,
                        provider: selection.provider,
                        model: selection.model,
                        protocol: selection.protocol,
                      ),
                      context: unprepared(),
                    ),
                  )
                Error(_) -> actor.continue(state)
              }
            }
          }
      }
    }

    RefreshData(reply) -> {
      case turn.running(state.activity) {
        Some(_) -> {
          process.send(reply, Error("session must be idle to reload"))
          actor.continue(state)
        }
        None ->
          case runtime.refresh_session(state.host, state.info.id) {
            Error(error) -> {
              process.send(reply, Error(error))
              actor.continue(state)
            }
            Ok(update) -> {
              let state = case update {
                Some(kernel) ->
                  State(
                    ..state,
                    kernel: Some(kernel),
                    latest_usage: None,
                    context: unprepared(),
                  )
                None -> state
              }
              process.send(
                reply,
                Ok(
                  json.object([
                    #("reloaded", json.string("session")),
                    #(
                      "message",
                      json.string(
                        "Extension context, skills catalog, and session commands rescanned from disk.",
                      ),
                    ),
                  ]),
                ),
              )
              actor.continue(emit(
                state,
                view.text("note", "session data reloaded from disk"),
              ))
            }
          }
      }
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
        State(..state, watchers: [
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
          case ensure_history(state) {
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
              actor.continue(state)
            }
          }
      }
    }

    Publish(id, event, reply) ->
      case turn.live(state.activity, id) {
        True -> {
          process.send(reply, True)
          actor.continue(emit(state, event))
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
              let state = remember(state, inputs, timestamp)
              actor.continue(
                State(
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
          let inputs = list.map(queued, submission_input)
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
                emit_submissions(
                  remember(state, inputs, timestamp),
                  queued,
                  timestamp,
                )
              process.send(reply, Ok(inputs))
              actor.continue(State(..state, steering: []))
            }
          }
        }
      }
    RecordContext(id, snapshot, reply) -> {
      process.send(reply, Nil)
      case turn.live(state.activity, id) {
        True -> actor.continue(State(..state, context: snapshot))
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
              actor.continue(State(..state, latest_usage: Some(metadata)))
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
          let state = State(..state, activity: turn.Resting)
          let state = case run.cancelled, outcome, persisted {
            True, _, _ -> emit(state, view.event("interrupted", []))
            _, Error(error), _ -> emit(state, view.text("error", error))
            _, _, Error(error) -> emit(state, view.text("error", error))
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
                  emit(
                    State(..state, latest_usage: Some(metadata)),
                    usage.event(metadata),
                  )
                }
                None -> state
              }
              state
            }
            _, _, _ -> state
          }
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
          let saved = save_state(state, kernel)
          runtime.reset_session(state.host, state.info.id)
          process.send(reply, True)
          actor.continue(
            State(..state, kernel: None, context: unprepared())
            |> emit(view.text(
              "note",
              released_text(saved, "nothing was attached"),
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
          actor.continue(State(..state, history: None))
        }
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
          let _ = save_state_within(state, kernel, close_state_timeout)
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
  ModelSelection(info.provider, info.model, info.protocol)
}

fn selection_json(selection: ModelSelection) -> json.Json {
  json.object([
    #("provider", json.string(selection.provider)),
    #("model", json.string(selection.model)),
    #("protocol", json.string(conversation.protocol(selection.protocol))),
  ])
}

@external(erlang, "albedo_native", "new_id")
fn new_id() -> String

@external(erlang, "albedo_daemon", "directory")
fn directory(path: String) -> Bool

@external(erlang, "albedo_session", "kill")
fn kill(pid: process.Pid) -> Nil

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
) -> Result(#(State, runtime.Session, types.Client), SubmissionError) {
  use _ <- result.try(case directory(state.info.cwd) {
    True -> Ok(Nil)
    False -> Error(WorkspaceMissing(state.info.cwd))
  })
  use state <- result.try(ensure_history(state) |> result.map_error(Rejected))
  use #(state, client) <- result.try(
    configured_client(state) |> result.map_error(Rejected),
  )
  use #(state, kernel) <- result.try(
    ensure_kernel(state) |> result.map_error(Rejected),
  )
  Ok(#(state, kernel, client))
}

/// The kernel opens on first use. A session with history had a namespace the
/// model still believes in, so its saved variables are revived and the gap named.
fn ensure_kernel(state: State) -> Result(#(State, runtime.Session), String) {
  case state.kernel {
    Some(kernel) ->
      case runtime.alive(kernel) {
        True -> Ok(#(state, kernel))
        False -> open_kernel(State(..state, kernel: None))
      }
    None -> open_kernel(state)
  }
}

fn open_kernel(state: State) -> Result(#(State, runtime.Session), String) {
  let opened = case
    runtime.open_session(state.host, state.info.id, state.info.cwd)
  {
    Error(python.Lost) -> {
      runtime.reset_session(state.host, state.info.id)
      runtime.open_session(state.host, state.info.id, state.info.cwd)
    }
    result -> result
  }
  use kernel <- result.try(
    opened
    |> result.replace_error("could not start the session python kernel"),
  )
  case state.notice, state.history {
    Some(notice), _ if notice == lost_notice ->
      Ok(#(State(..state, kernel: Some(kernel)), kernel))
    _, None | _, Some([]) -> Ok(#(State(..state, kernel: Some(kernel)), kernel))
    _, Some(_) -> {
      let revived = case state_path(state) {
        Some(path) -> runtime.load_state(kernel, path, state_timeout)
        None -> Error(python.Invalid("session has no state file"))
      }
      let state = case revived {
        Ok(python.Saved([_, ..], _, _) as saved) ->
          State(
            ..state,
            kernel: Some(kernel),
            notice: Some(restored_notice(saved)),
          )
          |> emit(view.text("note", restored_text(saved)))
        _ ->
          State(..state, kernel: Some(kernel), notice: Some(lost_notice))
          |> emit(view.text(
            "note",
            "python kernel restarted; earlier variables are gone, the transcript is intact",
          ))
      }
      Ok(#(state, kernel))
    }
  }
}

/// Saved state lives beside the transcript, one file per session.
fn state_path(state: State) -> Option(String) {
  case
    state.info.id == ""
    || string.contains(state.info.id, "/")
    || string.contains(state.info.id, "..")
  {
    True -> None
    False -> Some(state.home <> "/kernels/" <> state.info.id <> ".state")
  }
}

fn save_state(
  state: State,
  kernel: runtime.Session,
) -> Result(python.Saved, String) {
  save_state_within(state, kernel, state_timeout)
}

fn save_state_within(
  state: State,
  kernel: runtime.Session,
  timeout_ms: Int,
) -> Result(python.Saved, String) {
  case state_path(state) {
    None -> Error("session has no state file")
    Some(path) ->
      runtime.save_state(kernel, path, timeout_ms)
      |> result.replace_error("the kernel could not write its variables")
  }
}

fn names(saved: python.Saved) -> String {
  string.join(list.take(saved.names, 40), ", ")
}

fn restored_notice(saved: python.Saved) -> String {
  "<system-note>The python kernel restarted. These variables were restored from disk: "
  <> names(saved)
  <> case saved.missed {
    [] -> "."
    missed ->
      ". These were not: "
      <> string.join(
        list.map(list.take(missed, 20), fn(entry) {
          entry.0 <> " (" <> entry.1 <> ")"
        }),
        ", ",
      )
      <> "."
  }
  <> " Imports and definitions from earlier cells are gone unless named here.</system-note>"
}

fn restored_text(saved: python.Saved) -> String {
  "python kernel restarted; restored "
  <> int.to_string(list.length(saved.names))
  <> " variables from disk"
  <> case saved.missed {
    [] -> ""
    missed -> ", " <> int.to_string(list.length(missed)) <> " could not be read"
  }
}

fn released_text(
  saved: Result(python.Saved, String),
  reason: String,
) -> String {
  let prefix = "python kernel released: " <> reason <> "; "
  case saved {
    Ok(python.Saved([_, ..] as names, missed, engine)) ->
      prefix
      <> int.to_string(list.length(names))
      <> " variables saved to disk"
      <> case missed, engine {
        [], _ -> ""
        _, "pickle" ->
          ", "
          <> int.to_string(list.length(missed))
          <> " skipped (install dill to also save functions and classes)"
        _, _ -> ", " <> int.to_string(list.length(missed)) <> " skipped"
      }
    _ -> prefix <> "variables are gone, the transcript is intact"
  }
}

fn configured_client(state: State) -> Result(#(State, types.Client), String) {
  use provider <- result.try(case state.info.provider {
    "" -> {
      use provider <- result.try(configuration.legacy(state.home))
      use _ <- result.try(conversation.assign_session_provider(
        runtime.ledger(state.host),
        state.info.id,
        provider.name,
      ))
      Ok(provider)
    }
    name -> configuration.named(state.home, name)
  })
  let state = case state.info.provider {
    "" ->
      State(
        ..state,
        history: option.map(state.history, tag_unknown_provider(
          _,
          provider.name,
        )),
        info: conversation.Info(..state.info, provider: provider.name),
      )
    _ -> state
  }
  use client <- result.try(runtime.model_client(
    state.host,
    state.info.id,
    state.home,
    provider.name,
    provider.extension,
    state.info.model,
    state.info.protocol,
  ))
  Ok(#(state, client))
}

fn failed_queued(state: State, error: String) -> State {
  emit(
    State(..state, steering: []),
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
              recover_pending(state, kernel),
              list.map(queued, submission_input),
            )
          case projected_inputs(remember(state, accepted, 0)) {
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
                    emit_submissions(
                      remember(state, accepted, timestamp),
                      queued,
                      timestamp,
                    )
                  start_run(
                    State(..state, steering: [], notice: None),
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

fn submission_input(submission: Submission) -> types.Input {
  case submission.image {
    Some(image) -> types.UserImage(submission.text, image)
    None -> types.User(submission.text)
  }
}

fn submission_event(submission: Submission, timestamp: Int) -> String {
  let source = turn.source_name(submission.source)
  let client = Some(submission.client_id)
  case submission.image {
    Some(image) ->
      view.user_image(
        submission.display,
        source,
        client,
        Some(timestamp),
        image,
      )
    None -> view.user(submission.display, source, client, Some(timestamp))
  }
}

fn emit_submissions(
  state: State,
  submissions: List(Submission),
  timestamp: Int,
) -> State {
  list.fold(submissions, state, fn(state, submission) {
    emit(state, submission_event(submission, timestamp))
  })
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
  client: types.Client,
  model_history: List(types.Input),
) -> State {
  start_worker(state, kernel, client, model_history, turn.Turn(None))
}

fn start_worker(
  state: State,
  kernel: runtime.Session,
  client: types.Client,
  model_history: List(types.Input),
  work: turn.Work,
) -> State {
  let run_id = new_id()
  let owner = state.self
  let worker =
    loop.Loop(
      state.info.model,
      state.host,
      kernel,
      client,
      fn(event) { actor.call(owner, 5000, Publish(run_id, event, _)) },
      fn(inputs, stage) {
        actor.call(owner, 10_000, Commit(run_id, inputs, stage, _))
      },
      fn(request, observation) {
        let snapshot =
          context_snapshot.from_request(
            Some(usage.now()),
            state.info.provider,
            conversation.protocol(state.info.protocol),
            state.info.protocol,
            request,
            observation,
          )
        actor.call(owner, 5000, RecordContext(run_id, snapshot, _))
      },
      fn(metadata) {
        actor.call(owner, 10_000, RecordUsage(run_id, metadata, _))
      },
      fn() { actor.call(owner, 10_000, DrainSteering(run_id, _)) },
    )
  let pid =
    process.spawn(fn() {
      process.send(
        owner,
        Finished(run_id, case work {
          turn.Compaction -> loop.compact(worker, model_history)
          turn.Turn(_) -> loop.run(worker, run_id, model_history, 0)
        }),
      )
    })
  let run = turn.Run(run_id, pid, process.monitor(pid), False, work)
  State(..state, activity: turn.Running(run), context: case work {
    turn.Compaction -> state.context
    turn.Turn(_) -> unprepared()
  })
}

fn raw_inputs(entries: List(transcript.Entry)) -> List(types.Input) {
  list.map(entries, fn(entry) { entry.input })
}

fn ensure_history(state: State) -> Result(State, String) {
  case state.history {
    Some(_) -> Ok(state)
    None ->
      conversation.load_entries(runtime.ledger(state.host), state.info.id)
      |> result.map(fn(entries) {
        State(
          ..state,
          history: Some(
            entries
            |> tag_unknown_provider(state.info.provider)
            |> list.reverse,
          ),
        )
      })
  }
}

fn projected_for(
  state: State,
  provider: String,
  protocol: types.Protocol,
) -> Result(List(types.Input), String) {
  case state.history {
    None -> Error("transcript is not loaded")
    Some(history) -> projection.for_model(history, provider, protocol)
  }
}

fn projected_inputs(state: State) -> Result(List(types.Input), String) {
  projected_for(state, state.info.provider, state.info.protocol)
  |> result.map_error(fn(error) { "cannot prepare model history: " <> error })
}

fn tag_unknown_provider(
  entries: List(transcript.Entry),
  provider: String,
) -> List(transcript.Entry) {
  case provider {
    "" -> entries
    provider ->
      list.map(entries, fn(entry) {
        case entry.provider {
          Some(_) -> entry
          None -> transcript.Entry(..entry, provider: Some(provider))
        }
      })
  }
}

fn remember(state: State, inputs: List(types.Input), timestamp: Int) -> State {
  let entries =
    list.map(inputs, fn(input) {
      transcript.Entry(input, Some(timestamp), Some(state.info.provider))
    })
  let history = case state.history {
    Some(history) -> list.append(list.reverse(entries), history)
    None -> list.reverse(entries)
  }
  State(..state, history: Some(history))
}

fn recover_pending(state: State, kernel: runtime.Session) -> List(types.Input) {
  let inputs = case state.history {
    Some(history) -> history |> list.reverse |> raw_inputs
    None -> []
  }
  let completed =
    list.filter_map(inputs, fn(input) {
      case input {
        types.ToolOutput(id, _, _) -> Ok(id)
        _ -> Error(Nil)
      }
    })
  let pending =
    list.flat_map(inputs, view.calls)
    |> list.filter(fn(call) { !list.contains(completed, call.id) })
  list.map(pending, runtime.recover(state.host, kernel, _))
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
  name: String,
  enabled: Bool,
) -> Result(List(extension.Summary), String) {
  actor.call(session, 40_000, ChangeExtension(name, enabled, _))
}
