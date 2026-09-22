//// One coordinator per session. Workers own model/tool loops; clients never own workers.

import albedo/daemon/configuration
import albedo/daemon/context_snapshot
import albedo/daemon/conversation
import albedo/daemon/events as view
import albedo/daemon/projection
import albedo/daemon/transcript
import albedo/daemon/usage
import albedo/harness/extension
import albedo/harness/loop
import albedo/harness/python/kernel as python
import albedo/harness/rolling
import albedo/harness/runtime
import albedo/harness/skills/catalog as skill_catalog
import albedo/harness/skills/rpc as skills_rpc
import albedo/openai_api as openai
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
  Report(running: Bool, kernel: Option(Int), history_loaded: Bool, idle_ms: Int)
}

pub type ModelSelection {
  ModelSelection(provider: String, model: String, protocol: types.Protocol)
}

pub type SubmissionError {
  WorkspaceMissing(String)
  Rejected(String)
}

fn submission_error(error: SubmissionError) -> String {
  case error {
    WorkspaceMissing(path) -> "workspace not found: " <> path
    Rejected(message) -> message
  }
}

pub type Message {
  Resume
  Abort(String)
  Submit(
    String,
    String,
    String,
    Option(types.Image),
    Subject(Result(Nil, SubmissionError)),
  )
  ReadSkills(
    Subject(Result(#(List(skill_catalog.Command), List(String)), String)),
  )
  ActivateSkill(String, String, String, Subject(Result(Nil, SubmissionError)))
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
  Publish(String, String, Subject(Bool))
  Commit(String, List(types.Input), String, Subject(Result(Int, String)))
  RecordContext(String, context_snapshot.Snapshot, Subject(Nil))
  RecordUsage(String, usage.Metadata, Subject(Result(Nil, String)))
  ReadContext(Subject(json.Json))
  ReadContextPage(String, Int, Subject(Result(json.Json, String)))
  Finished(String, Result(Nil, String))
  Down(process.Down)
  Idle(Subject(Report))
  Release(Subject(Bool))
  EvictHistory(Subject(Bool))
  Close(Subject(Nil))
}

type Run {
  Run(id: String, pid: process.Pid, monitor: process.Monitor, cancelled: Bool)
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
    run: Option(Run),
    sequence: Int,
    events: List(#(Int, String)),
    phase: String,
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
    case info.stage {
      "model" | "tool" -> process.send(self, Resume)
      _ -> Nil
    }
    let phase = case info.stage {
      "idle" -> "resting"
      _ -> "interrupted"
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
        None,
        0,
        [],
        phase,
        None,
        unprepared(),
        now_ms(),
      )
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
) -> Result(Nil, SubmissionError) {
  actor.call(session, 10_000, Submit(text, text, client_id, image, _))
}

pub fn skills(
  session: Session,
) -> Result(#(List(skill_catalog.Command), List(String)), String) {
  actor.call(session, 15_000, ReadSkills)
}

pub fn activate_skill(
  session: Session,
  name: String,
  arguments: String,
  client_id: String,
) -> Result(Nil, SubmissionError) {
  actor.call(session, 15_000, ActivateSkill(name, arguments, client_id, _))
}

pub fn interrupt(session: Session) -> Bool {
  actor.call(session, 5000, Interrupt)
}

pub fn status(session: Session) -> String {
  actor.call(session, 5000, Status)
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

fn emit(state: State, event: String) -> State {
  let seq = state.sequence + 1
  let events = trim([#(seq, event), ..state.events], 256, 4_194_304)
  State(..state, sequence: seq, events: events)
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
    | ReadSkills(..)
    | ActivateSkill(..)
    | Interrupt(..)
    | Status(..)
    | Read(..)
    | ReadContext(..)
    | ReadContextPage(..)
    | ChangeModel(..)
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
            State(..state, phase: "resting")
            |> emit(view.text("error", submission_error(error))),
          )
        Ok(#(state, kernel, client)) -> {
          let recovered = recover_pending(state, kernel)
          let candidate = remember(state, recovered, 0)
          case projected_inputs(candidate) {
            Error(error) ->
              actor.continue(
                State(..state, phase: "resting")
                |> emit(view.text("error", error)),
              )
            Ok(model_history) ->
              case
                conversation.commit_from(
                  runtime.ledger(state.host),
                  state.info.id,
                  recovered,
                  "model",
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
      case state.run {
        Some(run) if run.id == id && run.cancelled -> {
          kill(run.pid)
          handle(state, Finished(id, Error("cancelled")))
        }
        _ -> actor.continue(state)
      }
    Submit(display, text, client_id, image, reply) ->
      case state.run {
        Some(_) -> {
          process.send(reply, Error(Rejected("session is busy")))
          actor.continue(state)
        }
        None -> {
          let maximum = case display == text {
            True -> 1_048_576
            False -> 2_200_000
          }
          case
            string.trim(text) == ""
            || string.byte_size(text) > maximum
            || string.byte_size(display) > 1_048_576
          {
            True -> {
              process.send(
                reply,
                Error(Rejected("prompt or activation exceeds its bounded size")),
              )
              actor.continue(state)
            }
            False ->
              case prepare_submission(state) {
                Error(error) -> {
                  process.send(reply, Error(error))
                  actor.continue(state)
                }
                Ok(#(state, kernel, client)) -> {
                  let user_input = case image {
                    Some(image) -> types.UserImage(text, image)
                    None -> types.User(text)
                  }
                  let accepted =
                    list.append(recover_pending(state, kernel), [user_input])
                  let candidate = remember(state, accepted, 0)
                  case projected_inputs(candidate) {
                    Error(error) -> {
                      process.send(reply, Error(Rejected(error)))
                      actor.continue(state)
                    }
                    Ok(history) -> {
                      let model_history = case state.notice {
                        None -> history
                        Some(notice) ->
                          case history {
                            [types.User(_), ..rest] -> [
                              types.User(text <> notice),
                              ..rest
                            ]
                            [types.UserImage(_, image), ..rest] -> [
                              types.UserImage(text <> notice, image),
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
                          "model",
                          Some(state.info.provider),
                        )
                      {
                        Error(error) -> {
                          process.send(reply, Error(Rejected(error)))
                          actor.continue(state)
                        }
                        Ok(timestamp) -> {
                          let state = remember(state, accepted, timestamp)
                          let state =
                            State(..state, phase: "preparing", notice: None)
                          let state =
                            start_run(state, kernel, client, model_history)
                          let event = case image {
                            Some(image) ->
                              view.user_image(
                                display,
                                "chat",
                                Some(client_id),
                                Some(timestamp),
                                image,
                              )
                            None ->
                              view.user(
                                display,
                                "chat",
                                Some(client_id),
                                Some(timestamp),
                              )
                          }
                          process.send(reply, Ok(Nil))
                          actor.continue(emit(state, event))
                        }
                      }
                    }
                  }
                }
              }
          }
        }
      }
    ReadSkills(reply) ->
      case directory(state.info.cwd) {
        False -> {
          process.send(reply, Error("workspace not found: " <> state.info.cwd))
          actor.continue(state)
        }
        True ->
          case ensure_kernel(state) {
            Error(error) -> {
              process.send(reply, Error(error))
              actor.continue(state)
            }
            Ok(#(next, kernel)) -> {
              let commands = {
                use response <- result.try(runtime.host_request(
                  next.host,
                  kernel,
                  "{\"method\":\"skills.list\",\"args\":{}}",
                ))
                skills_rpc.decode_commands_response(response)
              }
              process.send(reply, commands)
              actor.continue(next)
            }
          }
      }
    ActivateSkill(name, arguments, client_id, reply) ->
      case state.run, directory(state.info.cwd) {
        Some(_), _ -> {
          process.send(reply, Error(Rejected("session is busy")))
          actor.continue(state)
        }
        None, False -> {
          process.send(reply, Error(WorkspaceMissing(state.info.cwd)))
          actor.continue(state)
        }
        None, True ->
          case ensure_kernel(state) {
            Error(error) -> {
              process.send(reply, Error(Rejected(error)))
              actor.continue(state)
            }
            Ok(#(next, kernel)) -> {
              let request =
                json.object([
                  #("method", json.string("skills.activate")),
                  #(
                    "args",
                    json.object([
                      #("name", json.string(name)),
                      #("arguments", json.string(arguments)),
                    ]),
                  ),
                ])
                |> json.to_string
              let resolved = {
                use response <- result.try(runtime.host_request(
                  next.host,
                  kernel,
                  request,
                ))
                skills_rpc.decode_activation_response(response)
              }
              case resolved {
                Error(error) -> {
                  process.send(reply, Error(Rejected(error)))
                  actor.continue(next)
                }
                Ok(activation) -> {
                  let display =
                    skill_catalog.command_name(activation.name)
                    <> case arguments {
                      "" -> ""
                      _ -> " " <> arguments
                    }
                  handle(
                    next,
                    Submit(
                      display,
                      skill_catalog.activation_prompt(activation),
                      client_id,
                      None,
                      reply,
                    ),
                  )
                }
              }
            }
          }
      }
    Interrupt(reply) ->
      case state.run {
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
          actor.continue(State(..state, run: Some(Run(..run, cancelled: True))))
        }
      }
    ChangeWorkspace(cwd, reply) -> {
      let changed = case state.run, directory(cwd) {
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
              runtime.reset_session(state.host, state.info.id)
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
      case state.run {
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
        state.run == None
        && string.trim(model) != ""
        && string.byte_size(model) <= 512
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

    Status(reply) -> {
      process.send(
        reply,
        json.object([
          #("running", json.bool(state.run != None)),
          #("idle", json.bool(state.run == None)),
          #("phase", json.string(state.phase)),
        ])
          |> json.to_string,
      )
      actor.continue(state)
    }
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
      case state.run {
        Some(run) if run.id == id && !run.cancelled -> {
          process.send(reply, True)
          actor.continue(emit(state, event))
        }
        _ -> {
          process.send(reply, False)
          actor.continue(state)
        }
      }
    Commit(id, inputs, phase, reply) ->
      case state.run {
        Some(run) if run.id == id -> {
          // Completed tool results are saved even when cancellation was requested.
          let written =
            conversation.commit_from(
              runtime.ledger(state.host),
              state.info.id,
              inputs,
              phase,
              Some(state.info.provider),
            )
          process.send(reply, written)
          case written {
            Ok(timestamp) -> {
              let state = remember(state, inputs, timestamp)
              actor.continue(State(..state, phase: phase))
            }
            Error(_) -> actor.continue(state)
          }
        }
        _ -> {
          process.send(reply, Error("stale run"))
          actor.continue(state)
        }
      }
    RecordContext(id, snapshot, reply) -> {
      process.send(reply, Nil)
      case state.run {
        Some(run) if run.id == id && !run.cancelled ->
          actor.continue(State(..state, context: snapshot))
        _ -> actor.continue(state)
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
      case state.run {
        Some(run) if run.id == id -> {
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
      case state.run {
        Some(run) if run.id == id -> {
          process.demonitor_process(run.monitor)
          let stage = case outcome, run.cancelled {
            Ok(_), False -> "idle"
            _, _ -> "interrupted"
          }
          let persisted =
            conversation.commit_from(
              runtime.ledger(state.host),
              state.info.id,
              [],
              stage,
              Some(state.info.provider),
            )
          let state = State(..state, run: None, phase: "resting")
          let state = case run.cancelled, outcome, persisted {
            True, _, _ -> emit(state, view.event("interrupted", []))
            _, Error(error), _ -> emit(state, view.text("error", error))
            _, _, Error(error) -> emit(state, view.text("error", error))
            _, _, _ -> state
          }
          actor.continue(state)
        }
        _ -> actor.continue(state)
      }
    Down(process.ProcessDown(_, pid, _)) ->
      case state.run {
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
      process.send(
        reply,
        Report(
          state.run != None,
          kernel,
          state.history != None,
          now_ms() - state.last_touch,
        ),
      )
      actor.continue(state)
    }
    Release(reply) ->
      case state.kernel, state.run {
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
      case state.run {
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
      case state.run, state.kernel {
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
      runtime.reset_session(state.host, state.info.id)
      process.send(reply, Nil)
      actor.stop()
    }
  }
}

@external(erlang, "albedo_native", "new_id")
fn new_id() -> String

@external(erlang, "albedo_session", "kill")
fn kill(pid: process.Pid) -> Nil

@external(erlang, "albedo_session", "now_ms")
fn now_ms() -> Int

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
  Ok(#(
    state,
    openai.client(state.info.protocol, provider.base_url, provider.api_key),
  ))
}

fn start_run(
  state: State,
  kernel: runtime.Session,
  client: types.Client,
  model_history: List(types.Input),
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
      fn(inputs, phase) {
        actor.call(owner, 10_000, Commit(run_id, inputs, phase, _))
      },
      fn(request) {
        let observation = case runtime.compaction_name(kernel) {
          Some("rolling") ->
            rolling.observation(runtime.ledger(state.host), state.info.id)
            |> result.unwrap(None)
          _ -> None
        }
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
    )
  let pid =
    process.spawn(fn() {
      process.send(
        owner,
        Finished(run_id, loop.run(worker, run_id, model_history, 0)),
      )
    })
  let active = Run(run_id, pid, process.monitor(pid), False)
  State(..state, run: Some(active), phase: "preparing", context: unprepared())
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
        types.ToolOutput(id, _) -> Ok(id)
        _ -> Error(Nil)
      }
    })
  let pending =
    list.flat_map(inputs, view.calls)
    |> list.filter(fn(call) { !list.contains(completed, call.id) })
  list.map(pending, runtime.recover(state.host, kernel, _))
}

pub fn select_model(
  session: Session,
  model: String,
  provider: Option(String),
) -> Result(ModelSelection, String) {
  actor.call(session, 5000, ChangeModel(model, provider, _))
}

pub fn set_model(session: Session, model: String) -> Result(Nil, String) {
  select_model(session, model, None) |> result.replace(Nil)
}

@external(erlang, "albedo_daemon", "directory")
fn directory(path: String) -> Bool

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
