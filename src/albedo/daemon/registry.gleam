//// The supervised session registry owns lifecycle, admission, schedules, and maintenance.

import albedo/clock

import albedo/daemon/agents
import albedo/daemon/bus
import albedo/daemon/configuration
import albedo/daemon/conversation
import albedo/daemon/family
import albedo/daemon/history
import albedo/daemon/http_api
import albedo/daemon/mail
import albedo/daemon/maintenance
import albedo/daemon/migrations
import albedo/daemon/operations
import albedo/daemon/quota
import albedo/daemon/session
import albedo/daemon/session_preferences
import albedo/daemon/session_provider
import albedo/daemon/session_submission
import albedo/daemon/state_expiry
import albedo/daemon/store
import albedo/daemon/turn
import albedo/daemon/usage
import albedo/harness/credentials
import albedo/harness/extension
import albedo/harness/extensions/python/kernel as python
import albedo/harness/extensions/schedule/ledger as schedule
import albedo/harness/location
import albedo/harness/oauth
import albedo/harness/runtime
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string

pub type Config {
  Config(
    home: String,
    token: String,
    idle_ms: Int,
    budget_kb: Int,
    state_expiry_seconds: Int,
    /// How often schedules fire and letters left undelivered are retried.
    tick_ms: Int,
  )
}

/// Minimum idle time before reclaiming detached session memory.
const detached_ms = 30_000

/// Examine idleness often enough to honour the limit, never more than once a minute.
fn sweep_interval(config: Config) -> Int {
  int.clamp(config.idle_ms / 4, 250, 60_000)
}

pub type Message {
  CreateIdentified(
    String,
    http_api.Creation,
    Subject(Result(operations.Receipt, String)),
  )

  /// A session in a workspace, on a named provider or the active one, with a
  /// model or "" for the provider's.
  Create(
    String,
    Option(String),
    String,
    Subject(Result(conversation.Info, String)),
  )
  /// A child of the first session: its name among its siblings, its task, and
  /// a model, or "" for the parent's.
  CreateChild(
    String,
    String,
    String,
    String,
    Subject(Result(#(conversation.Info, family.Member), String)),
  )
  Lookup(String, Subject(Result(session.Session, String)))
  Existing(String, Subject(Result(Option(session.Session), String)))
  SessionDeleted(String)
  /// What an agent asks of other sessions, through the agents seam.
  AgentOp(agents.Op, Subject(Result(json.Json, String)))
  List(Subject(List(conversation.Info)))
  Logins(Subject(List(oauth.Login)))
  Host(Subject(Result(runtime.Runtime, String)))
  WorkerDown(process.Down)
  Sweep
  ScheduleTick
  /// A stored letter may be deliverable now: it was posted while its recipient
  /// was not running, or a recipient that refused it while busy has come to
  /// rest.
  MailWaiting
  Shutdown
  ReadHealth(Subject(Result(Nil, String)))
}

type State {
  State(
    host: runtime.Runtime,
    config: Config,
    sessions: Dict(String, #(conversation.Info, Option(session.Session))),
    self: Subject(Message),
    scheduling: Option(process.Pid),
    maintenance: Option(process.Pid),
    /// Mail arrived while a dispatcher ran; read the inbox again after it.
    mail_waiting: Bool,
    stage: Stage,
    last_state_expiry: Int,
  )
}

/// Whether the registry serves from the store. Once it does not, every
/// request is refused in its handler's error shape rather than reaching a
/// store that is closing or gone.
type Stage {
  Open
  /// Shutdown is closing sessions and then the store; the VM halts after.
  Closing
  /// The store died while the VM lives on.
  Orphaned
}

/// Why a registry that is not open refuses.
const closed = "daemon is shutting down"

fn handle(state: State, message: Message) -> actor.Next(State, a) {
  case state.stage, message {
    Open, _ -> serve(state, message)
    // A second shutdown while the first drains must not cut it short.
    Closing, Shutdown -> actor.continue(state)
    Orphaned, Shutdown -> {
      shutdown()
      actor.continue(state)
    }
    _, _ -> {
      refuse(state, message)
      actor.continue(state)
    }
  }
}

fn serve(state: State, message: Message) -> actor.Next(State, a) {
  case message {
    CreateIdentified(id, creation, reply) -> {
      let #(state, outcome) = create_identified(state, id, creation)
      process.send(reply, outcome)
      actor.continue(state)
    }
    ReadHealth(reply) -> {
      process.send(reply, Ok(Nil))
      actor.continue(state)
    }
    Create(cwd, provider, model, reply) -> {
      let created = {
        use workspace <- result.try(
          location.workspace(cwd)
          |> result.map_error(fn(failure) { failure.detail }),
        )
        use provider <- result.try(case provider {
          Some(name) -> configuration.named(state.config.home, name)
          None -> configuration.active(state.config.home)
        })
        let model = case model {
          "" -> provider.model
          _ -> model
        }
        use effort <- result.try(selected_effort(
          state,
          provider.name,
          model,
          None,
        ))
        let info =
          conversation.Info(
            new_id(),
            "new session",
            location.to_string(workspace),
            provider.name,
            model,
            provider.protocol,
            conversation.Idle,
            None,
            effort,
          )
        case
          string.trim(info.model) != ""
          && string.byte_size(info.model) <= 512
          && !string.contains(info.model, "\r")
          && !string.contains(info.model, "\n")
        {
          False -> Error("expected a model")
          True ->
            conversation.create(runtime.ledger(state.host), info)
            |> result.replace(info)
        }
      }
      process.send(reply, created)
      case created {
        Ok(info) -> actor.continue(holding(state, info.id, #(info, None)))
        Error(_) -> actor.continue(state)
      }
    }
    CreateChild(parent, name, task, model, reply) -> {
      let #(state, created) = create_child(state, parent, name, task, model)
      process.send(reply, created)
      actor.continue(state)
    }
    AgentOp(op, reply) -> {
      let #(state, answer) = agent_op(state, op)
      process.send(reply, answer)
      actor.continue(state)
    }
    Lookup(id, reply) -> {
      let #(state, found) = activate(state, id)
      process.send(reply, found)
      actor.continue(state)
    }
    Existing(id, reply) -> {
      process.send(
        reply,
        Ok(case dict.get(state.sessions, id) {
          Ok(pair) -> pair.1
          Error(_) -> None
        }),
      )
      actor.continue(state)
    }
    List(reply) -> {
      let db = runtime.ledger(state.host)
      process.send(reply, conversation.list(db) |> result.unwrap([]))
      actor.continue(state)
    }
    Logins(reply) -> {
      process.send(reply, runtime.logins(state.host))
      actor.continue(state)
    }
    Host(reply) -> {
      process.send(reply, Ok(state.host))
      actor.continue(state)
    }
    WorkerDown(process.ProcessDown(_, pid, _))
      if state.scheduling == Some(pid)
    -> {
      let state = State(..state, scheduling: None)
      case state.mail_waiting {
        True -> actor.continue(dispatch(state, False))
        False -> actor.continue(state)
      }
    }
    WorkerDown(process.ProcessDown(_, pid, _))
      if state.maintenance == Some(pid)
    -> actor.continue(State(..state, maintenance: None))
    WorkerDown(process.ProcessDown(_, pid, _)) -> {
      let entry =
        dict.values(state.sessions)
        |> list.find(fn(pair) {
          case pair.1 {
            Some(worker) -> process.subject_owner(worker) == Ok(pid)
            None -> False
          }
        })
      case entry {
        Error(_) -> actor.continue(state)
        Ok(#(previous, _)) -> {
          // It cannot announce that it stopped; say so for it.
          bus.running(previous.id, False)
          case conversation.get(runtime.ledger(state.host), previous.id) {
            Ok(info) -> actor.continue(holding(state, info.id, #(info, None)))
            Error("session not found") ->
              actor.continue(
                State(
                  ..state,
                  sessions: dict.delete(state.sessions, previous.id),
                ),
              )
            Error(reason) -> {
              io.println_error(
                "session observation after owner stop: " <> reason,
              )
              actor.continue(holding(state, previous.id, #(previous, None)))
            }
          }
        }
      }
    }
    WorkerDown(_) -> actor.continue(state)
    SessionDeleted(id) ->
      actor.continue(State(..state, sessions: dict.delete(state.sessions, id)))
    ScheduleTick -> {
      let _ = operations.prune(runtime.ledger(state.host))
      let _ = conversation.prune_creation(runtime.ledger(state.host))
      let _ = process.send_after(state.self, state.config.tick_ms, ScheduleTick)
      case state.scheduling {
        Some(_) -> actor.continue(state)
        None -> actor.continue(dispatch(state, True))
      }
    }
    MailWaiting ->
      case state.scheduling {
        Some(_) -> actor.continue(State(..state, mail_waiting: True))
        None -> actor.continue(dispatch(state, False))
      }
    Sweep -> {
      let state = case state.maintenance {
        Some(_) -> state
        None -> {
          let config = state.config
          let now = usage.now() / 1000
          let should_expire =
            now - state.last_state_expiry
            >= state_expiry.sweep_seconds(config.state_expiry_seconds)
          let sweep =
            maintenance.Sweep(
              home: config.home,
              ledger: runtime.ledger(state.host),
              workers: dict.values(state.sessions)
                |> list.filter_map(fn(entry) {
                  option.map(entry.1, fn(worker) { #(entry.0.id, worker) })
                  |> option.to_result(Nil)
                }),
              idle_ms: config.idle_ms,
              budget_kb: config.budget_kb,
              detached_ms: detached_ms,
              state_expiry_seconds: config.state_expiry_seconds,
              expire_states: should_expire,
              now_seconds: now,
            )
          let worker = process.spawn_unlinked(fn() { maintenance.run(sweep) })
          let _ = process.monitor(worker)
          State(
            ..state,
            maintenance: Some(worker),
            last_state_expiry: case should_expire {
              True -> now
              False -> state.last_state_expiry
            },
          )
        }
      }
      let _ =
        process.send_after(state.self, sweep_interval(state.config), Sweep)
      actor.continue(state)
    }
    Shutdown -> {
      // Off the registry, which stays up refusing until the VM halts, so a
      // caller queued behind the drain gets an answer, not a dead callee.
      // Linked: a drain that crashes takes the registry with it and the
      // daemon keeps serving, as when the registry drained itself.
      let workers = workers(state)
      let host = state.host
      process.spawn(fn() {
        runtime.detach_kernels(host)
        list.each(workers, session.close)
        runtime.stop(host)
        shutdown()
      })
      actor.continue(State(..state, stage: Closing))
    }
  }
}

/// A registry that is not open answers without the store, which may be gone.
fn refuse(state: State, message: Message) -> Nil {
  case message {
    CreateIdentified(_, _, reply) -> process.send(reply, Error(closed))
    ReadHealth(reply) ->
      process.send(
        reply,
        Error(case state.stage {
          Closing -> "daemon_stopping"
          _ -> "daemon_unavailable"
        }),
      )
    Create(_, _, _, reply) -> process.send(reply, Error(closed))
    CreateChild(_, _, _, _, reply) -> process.send(reply, Error(closed))
    Lookup(_, reply) -> process.send(reply, Error(closed))
    Existing(_, reply) -> process.send(reply, Error(closed))
    AgentOp(_, reply) -> process.send(reply, Error(closed))
    List(reply) -> process.send(reply, [])
    Logins(reply) -> process.send(reply, runtime.logins(state.host))
    Host(reply) -> process.send(reply, Error(closed))
    WorkerDown(_)
    | SessionDeleted(_)
    | Sweep
    | ScheduleTick
    | MailWaiting
    | Shutdown -> Nil
  }
}

fn workers(state: State) -> List(session.Session) {
  dict.values(state.sessions)
  |> list.filter_map(fn(pair) { option.to_result(pair.1, Nil) })
}

/// Schema and one-time migrations, before any session starts.
pub fn prepare_storage(
  config: Config,
  host: runtime.Runtime,
) -> Result(Nil, String) {
  use _ <- result.try(conversation.initialise(runtime.ledger(host)))
  use _ <- result.try(quota.initialise(runtime.ledger(host)))
  use _ <- result.try(mail.initialise(runtime.ledger(host)))
  use _ <- result.try(family.initialise(runtime.ledger(host)))
  let backup =
    config.home
    <> "/backups/albedo-before-image-store-"
    <> int.to_string(usage.now())
    <> ".sqlite"
  use moved <- result.try(migrations.run(runtime.ledger(host), backup))
  use upgraded <- result.try(runtime.migrate(host, backup))
  use _ <- result.try(python.recover_staged(runtime.ledger(host)))
  list.each(upgraded, fn(migration) {
    case migration.1 {
      0 -> Nil
      rows ->
        io.println(
          "migration " <> migration.0 <> ": " <> int.to_string(rows) <> " rows",
        )
    }
  })
  case moved {
    0 -> Nil
    rows ->
      io.println(
        "image store: moved images out of "
        <> int.to_string(rows)
        <> " transcript rows",
      )
  }
  case credentials.migrate(config.home, int.to_string(usage.now())) {
    Ok([]) -> Nil
    Ok(moved) ->
      io.println(
        "credentials: moved secrets from "
        <> string.join(moved, ", ")
        <> " into creds.json",
      )
    Error(reason) -> io.println("credentials: not migrated: " <> reason)
  }
  use _ <- result.try(case configuration.legacy(config.home) {
    Ok(provider) ->
      conversation.assign_provider(runtime.ledger(host), provider.name)
    Error(_) -> Ok(Nil)
  })
  use _ <- result.try(session_preferences.migrate(
    config.home,
    runtime.inventory(host),
  ))
  Ok(Nil)
}

/// The session registry. It restarts on a crash: sessions keep running, since
/// they are not linked to it, and the new registry adopts the live ones.
pub fn start(
  config: Config,
  host: runtime.Runtime,
  name: process.Name(Message),
) -> Result(actor.Started(Subject(Message)), actor.StartError) {
  actor.new_with_initialiser(30_000, fn(self) {
    // A store that died while the VM lives on leaves nothing to serve: come
    // up empty and refusing, with none of the store-backed timers below.
    let ledger = runtime.ledger(host)
    let stage = case process.is_alive(store.owner(ledger)) {
      True -> Open
      False -> Orphaned
    }
    use saved <- result.try(case stage {
      Open -> conversation.list(ledger)
      _ -> Ok([])
    })
    use pending_sessions <- result.try(operations.pending_sessions(ledger))
    let sessions =
      list.map(saved, fn(info) {
        let worker = case
          session.live(info.id),
          conversation.resumable(info.stage)
          || list.contains(pending_sessions, info.id)
        {
          // Still running from before a registry restart: adopt it.
          Some(worker), _ -> {
            watch(worker)
            Some(worker)
          }
          None, True ->
            case session.start(host, info, config.home) {
              Ok(worker) -> {
                watch(worker)
                Some(worker)
              }
              Error(error) -> {
                report_start_error(info.id, error)
                io.println(
                  "session unavailable: "
                  <> info.id
                  <> "; recovery will retry when opened",
                )
                None
              }
            }
          None, False -> None
        }
        #(info.id, #(info, worker))
      })
    let _ =
      maintenance.reclaim(
        config.home,
        [],
        [],
        list.map(saved, fn(info) { info.id }),
      )
    case stage {
      Open -> {
        let _ = process.send_after(self, sweep_interval(config), Sweep)
        let _ = process.send_after(self, config.tick_ms, ScheduleTick)
        // Letters left from before a restart go out now, not a tick later.
        process.send(self, MailWaiting)
        // Agents start and stop other sessions from kernel host routes.
        agents.register(fn(op) { actor.call(self, 60_000, AgentOp(op, _)) })
        mail.on_waiting(fn() { process.send(self, MailWaiting) })
      }
      _ -> Nil
    }
    Ok(
      actor.initialised(State(
        host,
        config,
        dict.from_list(sessions),
        self,
        None,
        None,
        False,
        stage,
        0,
      ))
      |> actor.returning(self)
      |> actor.selecting(
        process.new_selector()
        |> process.select(self)
        |> process.select_monitors(WorkerDown),
      ),
    )
  })
  |> actor.named(name)
  |> actor.on_message(handle)
  |> actor.start
}

/// One dispatcher at a time, off the registry: due schedules on a tick, then
/// the inbox.
fn dispatch(state: State, schedules: Bool) -> State {
  let db = runtime.ledger(state.host)
  let registry = state.self
  let worker =
    process.spawn_unlinked(fn() {
      case schedules {
        True -> dispatch_schedules(db, registry)
        False -> Nil
      }
      dispatch_mail(db, registry)
    })
  let _ = process.monitor(worker)
  State(..state, scheduling: Some(worker), mail_waiting: False)
}

fn dispatch_schedules(db: store.Store, registry: Subject(Message)) -> Nil {
  let time = clock.system_seconds()
  case schedule.due(db, time) {
    Error(error) -> io.println("scheduler query failed: " <> error)
    Ok(jobs) -> list.each(jobs, dispatch_schedule(db, registry, _))
  }
}

/// Hand undelivered letters to their recipients: after a restart, for a
/// recipient whose actor was not running, or for one whose queue was full.
fn dispatch_mail(db: store.Store, registry: Subject(Message)) -> Nil {
  case mail.pending(db, 50) {
    Error(error) -> io.println_error("mail inbox query failed: " <> error)
    Ok(letters) ->
      list.each(letters, fn(letter) {
        let outcome =
          actor.call(registry, 10_000, Lookup(letter.recipient, _))
          |> result.try(fn(worker) {
            session.submit_mail(worker, letter)
            |> result.map_error(fn(error) {
              case error {
                // A webhook waits for idle and a full queue drains; neither
                // is a failure worth recording.
                session.Busy -> ""
                other -> session.submission_error(other)
              }
            })
          })
        case outcome {
          Error("") | Ok(_) -> Nil
          // Refused by a closing registry: it goes out after the restart.
          Error(reason) if reason == closed -> Nil
          Error(reason) -> {
            case mail.record_failure(db, letter.id, reason) {
              Ok(_) -> Nil
              Error(error) ->
                io.println_error("mail failure could not be saved: " <> error)
            }
          }
        }
      })
  }
}

fn dispatch_schedule(
  db: store.Store,
  registry: Subject(Message),
  job: schedule.Job,
) -> Nil {
  case actor.call(registry, 10_000, Lookup(job.session, _)) {
    Error(_) -> Nil
    Ok(worker) -> {
      let busy = bus.is_running(job.session)
      let delivered = case job.kind == "heartbeat" && busy {
        True -> True
        False ->
          session.submit(
            worker,
            "[scheduled "
              <> job.kind
              <> " #"
              <> int.to_string(job.id)
              <> "] "
              <> job.prompt,
            "schedule",
            None,
          )
          |> result.is_ok
      }
      case delivered {
        True -> {
          case schedule.advance(db, job, clock.system_seconds()) {
            Ok(_) -> Nil
            Error(error) ->
              io.println_error(
                "schedule occurrence could not be advanced: " <> error,
              )
          }
        }
        False -> Nil
      }
    }
  }
}

fn report_start_error(id: String, error: actor.StartError) -> Nil {
  let reason = case error {
    actor.InitFailed(reason) -> reason
    actor.InitTimeout -> "initialisation timed out"
    actor.InitExited(_) -> "initialiser exited"
  }
  io.println_error("session " <> id <> " could not start: " <> reason)
}

fn activate(
  state: State,
  id: String,
) -> #(State, Result(session.Session, String)) {
  case dict.get(state.sessions, id) {
    Error(_) -> #(state, Error("session not found"))
    Ok(#(_, Some(worker))) -> #(state, Ok(worker))
    Ok(#(info, None)) ->
      case
        session.live(id)
        |> option.to_result(Nil)
        |> result.lazy_or(fn() {
          session.start(state.host, info, state.config.home)
          |> result.map_error(fn(error) {
            report_start_error(info.id, error)
            Nil
          })
        })
      {
        Error(_) -> #(state, Error("session could not start"))
        Ok(worker) -> {
          watch(worker)
          #(
            State(
              ..state,
              sessions: dict.insert(state.sessions, id, #(info, Some(worker))),
            ),
            Ok(worker),
          )
        }
      }
  }
}

fn provider_models(
  state: State,
  provider: configuration.Provider,
) -> List(String) {
  // A generic extension (openai) serves many gateways; the profile's endpoint
  // names which catalog provider's models it lists.
  let endpoint =
    session_provider.profile_endpoint(state.config.home, provider.name)
  list.unique([
    provider.model,
    ..runtime.model_names(state.host, provider.extension, endpoint)
  ])
}

fn child_model(
  state: State,
  parent: conversation.Info,
  requested: String,
) -> Result(#(configuration.Provider, String), String) {
  use profiles <- result.try(configuration.providers(state.config.home))
  let models =
    list.map(profiles, fn(profile) {
      #(profile, provider_models(state, profile))
    })
  let qualified =
    list.find_map(models, fn(pair) {
      let #(profile, available) = pair
      let prefix = profile.name <> "/"
      case string.starts_with(requested, prefix) {
        True ->
          Ok(#(
            profile,
            string.drop_start(requested, string.length(prefix)),
            available,
          ))
        False -> Error(Nil)
      }
    })
  case qualified {
    Ok(#(profile, model, available)) ->
      case list.contains(available, model) {
        True -> Ok(#(profile, model))
        False -> Error("model is not available from provider " <> profile.name)
      }
    Error(_) -> {
      use current <- result.try(configuration.named(
        state.config.home,
        parent.provider,
      ))
      let model = case requested {
        "" -> parent.model
        _ -> requested
      }
      case list.contains(provider_models(state, current), model) {
        True -> Ok(#(current, model))
        False -> {
          let matches =
            list.filter(models, fn(pair) {
              let #(profile, available) = pair
              profile.name != current.name && list.contains(available, model)
            })
          case matches {
            [#(profile, _)] -> Ok(#(profile, model))
            [] -> Ok(#(current, model))
            _ ->
              Error(
                "model is available from multiple providers; use provider/model",
              )
          }
        }
      }
    }
  }
}

/// A child of `parent`, linked, running, and handed its task.
fn create_child(
  state: State,
  parent: String,
  name: String,
  task: String,
  model: String,
) -> #(State, Result(#(conversation.Info, family.Member), String)) {
  let db = runtime.ledger(state.host)
  let created = {
    use #(cached, _) <- result.try(
      dict.get(state.sessions, parent)
      |> result.replace_error("session not found"),
    )
    // A parent that followed its own parent after a turn moved only its row.
    let above = case conversation.get(db, parent) {
      Ok(row) -> conversation.Info(..cached, cwd: row.cwd)
      Error(_) -> cached
    }
    use _ <- result.try(family.valid_name(name))
    use #(provider, selected_model) <- result.try(child_model(
      state,
      above,
      model,
    ))
    let efforts =
      session_provider.model_efforts(
        state.host,
        state.config.home,
        provider.name,
        selected_model,
      )
    let info =
      conversation.Info(
        ..above,
        id: new_id(),
        title: name,
        stage: conversation.Idle,
        last_assistant_at: None,
        provider: provider.name,
        model: selected_model,
        protocol: provider.protocol,
        effort: extension.default_effort(efforts),
      )
    conversation.create_child(db, info, parent, name)
  }
  case created {
    Error(error) -> #(state, Error(error))
    Ok(#(info, member)) -> {
      bus.spawned(member)
      let state =
        State(
          ..state,
          sessions: dict.insert(state.sessions, info.id, #(info, None)),
        )
      let #(state, worker) = activate(state, info.id)
      let sent = {
        use letter <- result.try(mail.post(
          db,
          mail.new_id(),
          info.id,
          Some(parent),
          family.name_of(db, parent),
          mail.Task,
          task,
        ))
        // Off the registry: admitting the task may boot the child's kernel.
        // The letter is durable, so a failed hand-off is the dispatcher's.
        case worker {
          Ok(worker) -> {
            process.spawn_unlinked(fn() { session.submit_mail(worker, letter) })
            Ok(Nil)
          }
          Error(_) -> Ok(Nil)
        }
      }
      #(state, sent |> result.replace(#(info, member)))
    }
  }
}

fn agent_op(
  state: State,
  op: agents.Op,
) -> #(State, Result(json.Json, String)) {
  let worker = fn(id) {
    case dict.get(state.sessions, id) {
      Ok(#(_, Some(active))) -> Some(active)
      _ -> None
    }
  }
  case op {
    agents.Spawn(parent, name, task, model) -> {
      let #(state, created) = create_child(state, parent, name, task, model)
      #(
        state,
        result.map(created, fn(pair) {
          json.object([
            #("member", member_json(pair.1)),
            #("model", json.string({ pair.0 }.model)),
          ])
        }),
      )
    }
    agents.Running(id) -> #(state, Ok(json.bool(bus.is_running(id))))
    // The registry never waits on a session: interrupts and releases run in
    // their own processes, and running state comes from the status cache.
    agents.Stop(id) -> {
      let running = bus.is_running(id)
      case worker(id), running {
        Some(active), True -> {
          process.spawn_unlinked(fn() { session.interrupt(active) })
          Nil
        }
        _, _ -> Nil
      }
      #(state, Ok(json.bool(running)))
    }
    agents.Close(id) -> {
      case worker(id) {
        Some(active) -> {
          // Saving the kernel's variables can take a while.
          process.spawn_unlinked(fn() {
            let _ = session.interrupt(active)
            session.release(active)
          })
          Nil
        }
        None -> Nil
      }
      let closed = family.close(runtime.ledger(state.host), id)
      case closed {
        Ok(_) -> bus.closed(id)
        Error(_) -> Nil
      }
      #(state, closed |> result.replace(json.bool(True)))
    }
    agents.Models(id) -> {
      let listed = case dict.get(state.sessions, id) {
        Error(_) -> []
        Ok(#(info, _)) -> {
          let profiles =
            configuration.providers(state.config.home)
            |> result.unwrap([])
          let #(same, other) =
            list.partition(profiles, fn(profile) {
              profile.name == info.provider
            })
          let same_models = list.flat_map(same, provider_models(state, _))
          let other_models =
            list.flat_map(other, fn(profile) {
              provider_models(state, profile)
              |> list.map(fn(model) { profile.name <> "/" <> model })
            })
          list.unique([info.model, ..list.append(same_models, other_models)])
        }
      }
      #(state, Ok(json.array(listed, json.string)))
    }
  }
}

fn member_json(member: family.Member) -> json.Json {
  json.object([
    #("session", json.string(member.session)),
    #("parent", json.string(member.parent)),
    #("name", json.string(member.name)),
    #("depth", json.int(member.depth)),
    #("closed", json.bool(member.closed)),
  ])
}

/// The registry remembering a session, live or not.
fn holding(
  state: State,
  id: String,
  pair: #(conversation.Info, Option(session.Session)),
) -> State {
  State(..state, sessions: dict.insert(state.sessions, id, pair))
}

@external(erlang, "albedo_daemon", "shutdown")
fn shutdown() -> Nil

@external(erlang, "albedo_native", "new_id")
fn new_id() -> String

fn watch(worker: session.Session) -> Nil {
  case process.subject_owner(worker) {
    Ok(pid) -> {
      let _ = process.monitor(pid)
      Nil
    }
    Error(_) -> Nil
  }
}

fn rejected_operation(
  state: State,
  operation: operations.Request,
  failure: http_api.Failure,
) -> Result(operations.Receipt, String) {
  case failure.status >= 500 {
    True -> Error(failure.detail)
    False ->
      operations.reject(
        runtime.ledger(state.host),
        operation,
        operations.Rejection(failure.status, failure.code, failure.detail),
      )
  }
}

/// The client identity names both the creation decision and the session. All
/// lookup and validation happen before resolving defaults for a first attempt.
fn create_identified(
  state: State,
  id: String,
  intent: http_api.Creation,
) -> #(State, Result(operations.Receipt, String)) {
  let db = runtime.ledger(state.host)
  let submitted = http_api.creation_intent(intent) |> json.to_string
  let operation =
    operations.Request(id, http_api.etag(submitted), "create", id, None)
  let checked = {
    use prior <- result.try(conversation.creation(db, id))
    use _ <- result.try(case prior {
      Some(record) if record.deleted_at != None -> Error("session_deleted")
      _ ->
        case conversation.get(db, id) {
          Ok(_) -> Error("session_exists")
          Error("session not found") -> Ok(Nil)
          Error(reason) -> Error(reason)
        }
    })
    operations.check(db, operation)
  }
  case checked {
    Error(reason) -> #(state, Error(reason))
    Ok(Some(receipt)) -> #(state, Ok(receipt))
    Ok(None) -> {
      let prepared = case intent {
        http_api.NewSession(workspace, _name, provider_name, model, effort) -> {
          use workspace <- result.try(
            location.workspace(workspace)
            |> result.map_error(http_api.workspace_failure),
          )
          use provider <- result.try({
            case provider_name {
              Some(name) -> {
                use profiles <- result.try(configuration.profiles(
                  state.config.home,
                ))
                case
                  list.find(profiles, fn(profile) {
                    case profile {
                      Ok(provider) -> provider.name == name
                      Error(#(id, _)) -> id == name
                    }
                  })
                {
                  Ok(Ok(provider)) -> Ok(provider)
                  Ok(Error(#(_, reason))) -> Error(reason)
                  Error(_) -> Error("provider_profile_unknown")
                }
              }
              None -> configuration.active(state.config.home)
            }
            |> result.map_error(http_api.failure)
          })
          let model = option.unwrap(model, provider.model)
          use effort <- result.try(
            selected_effort(state, provider.name, model, effort)
            |> result.map_error(http_api.failure),
          )
          Ok(conversation.Info(
            id,
            "new session",
            location.to_string(workspace),
            provider.name,
            model,
            provider.protocol,
            conversation.Idle,
            None,
            effort,
          ))
        }
        http_api.ForkSession(source, _, _name) -> {
          use above <- result.try(
            conversation.get(db, source) |> result.map_error(http_api.failure),
          )
          Ok(
            conversation.Info(
              ..above,
              id: id,
              stage: conversation.Idle,
              last_assistant_at: None,
            ),
          )
        }
        http_api.ChildSession(parent, address, _name, _, _, model, effort) -> {
          use above <- result.try(
            conversation.get(db, parent) |> result.map_error(http_api.failure),
          )
          use _ <- result.try(
            family.valid_name(address) |> result.map_error(http_api.failure),
          )
          use #(provider, model) <- result.try(
            child_model(state, above, option.unwrap(model, ""))
            |> result.map_error(http_api.failure),
          )
          use effort <- result.try(
            selected_effort(state, provider.name, model, effort)
            |> result.map_error(http_api.failure),
          )
          Ok(
            conversation.Info(
              ..above,
              id: id,
              title: address,
              provider: provider.name,
              model: model,
              protocol: provider.protocol,
              stage: conversation.Idle,
              last_assistant_at: None,
              effort: effort,
            ),
          )
        }
      }
      case prepared {
        Error(reason) -> #(state, rejected_operation(state, operation, reason))
        Ok(info) -> {
          let resolved =
            json.object([
              #("workspace", json.string(info.cwd)),
              #("provider_profile", json.string(info.provider)),
              #("model", json.string(info.model)),
              #("effort", json.nullable(info.effort, json.string)),
            ])
            |> json.to_string
          let name = case intent {
            http_api.NewSession(_, name, _, _, _)
            | http_api.ForkSession(_, _, name) -> name
            http_api.ChildSession(_, _, name, _, _, _, _) -> Some(name)
          }
          let creation =
            conversation.Creation(operation, submitted, resolved, name)
          let result = case intent {
            http_api.NewSession(..) ->
              conversation.create_identified(db, info, creation)
            http_api.ForkSession(source, checkpoint, _) -> {
              use checkpoint <- result.try(
                int.parse(checkpoint)
                |> result.replace_error("invalid checkpoint"),
              )
              history.fork_identified(
                db,
                history.ForkCreation(source, id, checkpoint, creation),
              )
            }
            http_api.ChildSession(parent, address, _, input_id, task, _, _) -> {
              let letter =
                mail.Letter(
                  input_id,
                  id,
                  Some(parent),
                  family.name_of(db, parent),
                  mail.Task,
                  task,
                  usage.now(),
                )
              let submitted =
                turn.Submission(
                  mail.display(letter),
                  mail.text(letter),
                  "",
                  turn.Mail(input_id, mail.Task),
                  None,
                  Some(input_id),
                  Some(input_id),
                )
              let input_intent =
                http_api.input_intent(http_api.MessageInput(task, None, None))
                |> json.to_string
              let input =
                operations.Request(
                  input_id,
                  http_api.etag(input_intent),
                  "message",
                  id,
                  None,
                )
              use _ <- result.try(operations.validate_id(input_id, usage.now()))
              conversation.create_child_identified(
                db,
                conversation.ChildCreation(
                  info,
                  creation,
                  parent,
                  address,
                  input,
                  session_submission.encode(submitted),
                  letter,
                ),
              )
            }
          }
          case result {
            Error("session_exists") -> #(state, Error("session_exists"))
            Error("session_deleted") -> #(state, Error("session_deleted"))
            Error(reason) -> #(
              state,
              rejected_operation(state, operation, http_api.failure(reason)),
            )
            Ok(receipt) -> {
              let info = conversation.get(db, id) |> result.unwrap(info)
              let state = holding(state, id, #(info, None))
              case intent {
                http_api.ChildSession(parent, _, _, input_id, task, _, _) -> {
                  case family.get(db, id) {
                    Ok(Some(member)) -> bus.spawned(member)
                    _ -> Nil
                  }
                  bus.mailed(
                    input_id,
                    Some(parent),
                    family.name_of(db, parent),
                    id,
                    "task",
                    string.byte_size(task),
                  )
                  let #(state, _) = activate(state, id)
                  #(state, Ok(receipt))
                }
                _ -> #(state, Ok(receipt))
              }
            }
          }
        }
      }
    }
  }
}

fn selected_effort(
  state: State,
  provider: String,
  model: String,
  supplied: Option(String),
) -> Result(Option(String), String) {
  use _ <- result.try(
    case
      string.trim(model) != ""
      && string.byte_size(model) <= 512
      && !string.contains(model, "\r")
      && !string.contains(model, "\n")
    {
      True -> Ok(Nil)
      False -> Error("expected a model")
    },
  )
  let efforts =
    session_provider.model_efforts(
      state.host,
      state.config.home,
      provider,
      model,
    )
  case supplied {
    None -> {
      use profile <- result.try(configuration.named(state.config.home, provider))
      case profile.effort {
        Some(level) ->
          case list.contains(efforts, level) {
            True -> Ok(Some(level))
            False -> Error("saved profile effort is unsupported by this model")
          }
        _ -> Ok(extension.default_effort(efforts))
      }
    }
    Some(value) ->
      case list.contains(efforts, value) {
        True -> Ok(Some(value))
        False -> Error("unsupported effort")
      }
  }
}
