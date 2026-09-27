import albedo/daemon/agents
import albedo/daemon/bus
import albedo/daemon/configuration
import albedo/daemon/conversation
import albedo/daemon/family
import albedo/daemon/history
import albedo/daemon/image
import albedo/daemon/images
import albedo/daemon/mail
import albedo/daemon/reaper
import albedo/daemon/session
import albedo/daemon/session_provider
import albedo/daemon/store
import albedo/daemon/usage
import albedo/harness/command
import albedo/harness/extension
import albedo/harness/extensions/schedule/ledger as schedule
import albedo/harness/oauth
import albedo/harness/runtime
import albedo/openai_api/types
import gleam/bytes_tree
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/http.{Delete, Get, Patch, Post}
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision
import gleam/result
import gleam/set
import gleam/string
import gleam/string_tree
import gleam/uri
import mist
import sqlight

pub type Config {
  Config(home: String, token: String, idle_ms: Int, budget_kb: Int)
}

/// How long without a word from any client counts as detached. An attached
/// client reads its session every 100ms, so silence is a reliable signal.
const detached_ms = 30_000

/// Examine idleness often enough to honour the limit, never more than once a minute.
fn sweep_interval(config: Config) -> Int {
  int.clamp(config.idle_ms / 4, 2000, 60_000)
}

type Message {
  Create(String, String, Subject(Result(conversation.Info, String)))
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
  /// What an agent asks of other sessions, through the agents seam.
  AgentOp(agents.Op, Subject(Result(json.Json, String)))
  /// The tree `session` belongs to, from its root down.
  ReadAgents(String, Subject(Result(#(String, List(AgentNode)), String)))
  List(Subject(List(conversation.Info)))
  Logins(Subject(List(oauth.Login)))
  Host(Subject(runtime.Runtime))
  ReadTree(String, Int, Int, Subject(Result(history.Page, String)))
  ReadRecent(String, Int, Subject(Result(history.Recent, String)))
  ReadHistory(String, Option(Int), Int, Subject(Result(String, String)))
  Fork(String, Int, Subject(Result(conversation.Info, String)))
  DeleteSession(String, Subject(Result(Nil, String)))
  Rename(String, String, Subject(Result(conversation.Info, String)))
  /// A session's info changed; the session itself already knows. The stored
  /// row is re-read, since the session's own copy keeps the title it started
  /// with rather than a later message's title or a name it was given.
  Remember(String, Subject(Result(conversation.Info, String)))
  WorkerDown(process.Down)
  Sweep
  ScheduleTick
  Shutdown
}

type State {
  State(
    host: runtime.Runtime,
    config: Config,
    sessions: Dict(String, #(conversation.Info, Option(session.Session))),
    self: Subject(Message),
    scheduling: Option(process.Pid),
  )
}

type Stream {
  Tick
  Wake
}

/// The agents stream: bus events arrive one by one and leave in batches.
type AgentStream {
  Flush
  Heard(String)
}

type AgentNode {
  AgentNode(
    info: conversation.Info,
    member: Option(family.Member),
    name: String,
    running: Bool,
  )
}

pub fn start(config: Config, port: Int) -> Result(Int, String) {
  // Storage is the one thing this daemon cannot run without, so the runtime
  // that owns it stays linked to the daemon; everything above it is supervised.
  use host <- result.try(
    runtime.start(config.home <> "/albedo.sqlite")
    |> result.replace_error("could not start runtime"),
  )
  use _ <- result.try(prepare_storage(config, host))
  let name = process.new_name("albedo_registry")
  use _ <- result.try(
    supervisor.new(supervisor.OneForOne)
    |> supervisor.restart_tolerance(intensity: 10, period: 60)
    |> supervisor.add(
      supervision.worker(fn() { start_registry(config, host, name) }),
    )
    |> supervisor.start
    |> result.map_error(string.inspect),
  )
  // A name, not a pid: handlers keep reaching the registry across restarts.
  let registry = process.named_subject(name)
  let selected_port = process.new_subject()
  use _ <- result.try(
    mist.new(route(config, registry, _))
    |> mist.bind("127.0.0.1")
    |> mist.port(port)
    |> mist.after_start(fn(actual, _, _) { process.send(selected_port, actual) })
    |> mist.start
    |> result.map_error(string.inspect),
  )
  process.receive(selected_port, 1000)
  |> result.replace_error("listener did not report its port")
}

fn handle(state: State, message: Message) {
  case message {
    Create(cwd, model, reply) -> {
      let created = {
        use provider <- result.try(configuration.active(state.config.home))
        let model = case model {
          "" -> provider.model
          _ -> model
        }
        let efforts =
          session_provider.model_efforts(
            state.host,
            state.config.home,
            provider.name,
            model,
          )
        let effort = extension.default_effort(efforts)
        let info =
          conversation.Info(
            new_id(),
            "new session",
            cwd,
            provider.name,
            model,
            provider.protocol,
            conversation.Idle,
            None,
            effort,
          )
        case
          directory(cwd)
          && string.trim(info.model) != ""
          && string.byte_size(info.model) <= 512
          && !string.contains(info.model, "\r")
          && !string.contains(info.model, "\n")
        {
          False -> Error("expected an existing absolute workspace and a model")
          True ->
            conversation.create(runtime.ledger(state.host), info)
            |> result.replace(info)
        }
      }
      process.send(reply, created)
      case created {
        Ok(info) ->
          actor.continue(
            State(
              ..state,
              sessions: dict.insert(state.sessions, info.id, #(info, None)),
            ),
          )
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
    ReadAgents(id, reply) -> {
      process.send(reply, agent_tree(state, id))
      actor.continue(state)
    }
    Lookup(id, reply) -> {
      let #(state, found) = activate(state, id)
      process.send(reply, found)
      actor.continue(state)
    }
    Remember(id, reply) -> {
      let stored = conversation.get(runtime.ledger(state.host), id)
      process.send(reply, stored)
      case stored, dict.get(state.sessions, id) {
        Ok(info), Ok(#(_, worker)) ->
          actor.continue(
            State(
              ..state,
              sessions: dict.insert(state.sessions, id, #(info, worker)),
            ),
          )
        _, _ -> actor.continue(state)
      }
    }
    List(reply) -> {
      let db = runtime.ledger(state.host)
      let children =
        family.descendants(db) |> result.unwrap([]) |> set.from_list
      process.send(
        reply,
        conversation.list(db)
          |> result.unwrap([])
          |> list.filter(fn(info) { !set.contains(children, info.id) }),
      )
      actor.continue(state)
    }
    Logins(reply) -> {
      process.send(reply, runtime.logins(state.host))
      actor.continue(state)
    }
    Host(reply) -> {
      process.send(reply, state.host)
      actor.continue(state)
    }
    ReadTree(id, after, limit, reply) -> {
      process.send(
        reply,
        history.page(runtime.ledger(state.host), id, after, limit),
      )
      actor.continue(state)
    }
    ReadRecent(id, limit, reply) -> {
      process.send(reply, history.recent(runtime.ledger(state.host), id, limit))
      actor.continue(state)
    }
    ReadHistory(id, before, rows, reply) -> {
      process.send(
        reply,
        history.rendered(runtime.ledger(state.host), id, before, rows),
      )
      actor.continue(state)
    }
    Fork(id, checkpoint, reply) -> {
      let forked =
        history.fork(runtime.ledger(state.host), id, new_id(), checkpoint)
      process.send(reply, forked)
      case forked {
        Ok(info) ->
          actor.continue(
            State(
              ..state,
              sessions: dict.insert(state.sessions, info.id, #(info, None)),
            ),
          )
        Error(_) -> actor.continue(state)
      }
    }
    DeleteSession(id, reply) -> {
      let children =
        family.children(runtime.ledger(state.host), id) |> result.unwrap([])
      let deleted = case dict.get(state.sessions, id), children {
        Error(_), _ -> Error("session not found")
        // Deleting a parent would strand its children's work; they go first.
        Ok(_), [_, ..] ->
          Error(
            "session has "
            <> int.to_string(list.length(children))
            <> " child sessions; delete them first",
          )
        Ok(pair), [] -> delete_idle(state, id, pair)
      }
      process.send(reply, deleted)
      case deleted {
        Ok(_) -> {
          // Closing saves the kernel's variables and can take a while.
          case dict.get(state.sessions, id) {
            Ok(#(_, Some(worker))) -> {
              process.spawn_unlinked(fn() {
                session.close(worker)
                session.discard_state(state.config.home, id)
              })
              Nil
            }
            _ -> session.discard_state(state.config.home, id)
          }
          runtime.forget_session(state.host, id)
          bus.gone(id)
          actor.continue(
            State(..state, sessions: dict.delete(state.sessions, id)),
          )
        }
        Error(_) -> actor.continue(state)
      }
    }
    Rename(id, name, reply) -> {
      let db = runtime.ledger(state.host)
      let renamed =
        dict.get(state.sessions, id)
        |> result.replace_error("session not found")
        |> result.try(fn(pair) {
          conversation.rename(db, id, name)
          |> result.map(fn(info) { #(info, pair.1) })
        })
      process.send(reply, renamed |> result.map(fn(pair) { pair.0 }))
      case renamed {
        Ok(#(info, worker)) -> {
          let member = family.get(db, id) |> result.unwrap(None)
          bus.renamed(id, agent_name(db, info, member))
          actor.continue(
            State(
              ..state,
              sessions: dict.insert(state.sessions, id, #(info, worker)),
            ),
          )
        }
        Error(_) -> actor.continue(state)
      }
    }
    WorkerDown(process.ProcessDown(_, pid, _))
      if state.scheduling == Some(pid)
    -> actor.continue(State(..state, scheduling: None))
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
          runtime.reset_session(state.host, previous.id)
          let info =
            conversation.list(runtime.ledger(state.host))
            |> result.replace_error(Nil)
            |> result.try(list.find(_, fn(info) { info.id == previous.id }))
            |> result.unwrap(previous)
          case session.start(state.host, info, state.config.home) {
            Ok(worker) -> {
              watch(worker)
              actor.continue(
                State(
                  ..state,
                  sessions: dict.insert(state.sessions, info.id, #(
                    info,
                    Some(worker),
                  )),
                ),
              )
            }
            Error(_) ->
              actor.continue(
                State(
                  ..state,
                  sessions: dict.insert(state.sessions, info.id, #(info, None)),
                ),
              )
          }
        }
      }
    }
    WorkerDown(_) -> actor.continue(state)
    ScheduleTick -> {
      let _ = process.send_after(state.self, 15_000, ScheduleTick)
      case state.scheduling {
        Some(_) -> actor.continue(state)
        None -> {
          let db = runtime.ledger(state.host)
          let registry = state.self
          let worker =
            process.spawn_unlinked(fn() {
              dispatch_schedules(db, registry)
              dispatch_mail(db, registry)
            })
          let _ = process.monitor(worker)
          actor.continue(State(..state, scheduling: Some(worker)))
        }
      }
    }
    Sweep -> {
      // Off the registry: saving Python state and dropping reloadable history
      // must not make API calls wait behind filesystem or database work.
      let workers =
        dict.values(state.sessions)
        |> list.filter_map(fn(pair) {
          case pair.1 {
            Some(worker) -> Ok(worker)
            None -> Error(Nil)
          }
        })
      let config = state.config
      let _ = process.spawn_unlinked(fn() { reap(workers, config) })
      let _ =
        process.send_after(state.self, sweep_interval(state.config), Sweep)
      actor.continue(state)
    }
    Shutdown -> {
      dict.each(state.sessions, fn(_, pair) {
        case pair.1 {
          Some(worker) -> session.close(worker)
          None -> Nil
        }
      })
      runtime.stop(state.host)
      shutdown()
      actor.stop()
    }
  }
}

/// Delete a session that is not running a turn.
fn delete_idle(
  state: State,
  id: String,
  pair: #(conversation.Info, Option(session.Session)),
) -> Result(Nil, String) {
  let #(info, worker) = pair
  let busy = case worker {
    Some(_) -> bus.is_running(id)
    None -> conversation.resumable(info.stage)
  }
  case busy {
    True -> Error("session is busy")
    False -> conversation.delete(runtime.ledger(state.host), id)
  }
}

/// How a session's children and siblings address it.
fn family_name(state: State, session: String) -> String {
  case family.get(runtime.ledger(state.host), session) {
    Ok(Some(member)) -> member.name
    _ ->
      case dict.get(state.sessions, session) {
        Ok(#(info, _)) -> info.title
        Error(_) -> "parent"
      }
  }
}

/// Schema and one-time migrations, before any session starts.
fn prepare_storage(
  config: Config,
  host: runtime.Runtime,
) -> Result(Nil, String) {
  use _ <- result.try(conversation.initialise(runtime.ledger(host)))
  use _ <- result.try(mail.initialise(runtime.ledger(host)))
  use _ <- result.try(family.initialise(runtime.ledger(host)))
  use moved <- result.try(images.migrate(
    runtime.ledger(host),
    config.home
      <> "/backups/albedo-before-image-store-"
      <> int.to_string(usage.now())
      <> ".sqlite",
  ))
  case moved {
    0 -> Nil
    rows ->
      io.println(
        "image store: moved images out of "
        <> int.to_string(rows)
        <> " transcript rows",
      )
  }
  use _ <- result.try(case configuration.legacy(config.home) {
    Ok(provider) ->
      conversation.assign_provider(runtime.ledger(host), provider.name)
    Error(_) -> Ok(Nil)
  })
  Ok(Nil)
}

/// The session registry. It restarts on a crash: sessions keep running, since
/// they are not linked to it, and the new registry adopts the live ones.
fn start_registry(
  config: Config,
  host: runtime.Runtime,
  name: process.Name(Message),
) {
  actor.new_with_initialiser(30_000, fn(self) {
    use saved <- result.try(conversation.list(runtime.ledger(host)))
    let sessions =
      list.map(saved, fn(info) {
        let worker = case
          session.live(info.id),
          conversation.resumable(info.stage)
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
              Error(_) -> {
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
    let _ = process.send_after(self, sweep_interval(config), Sweep)
    let _ = process.send_after(self, 15_000, ScheduleTick)
    // Agents start and stop other sessions from kernel host routes.
    agents.register(fn(op) { actor.call(self, 60_000, AgentOp(op, _)) })
    Ok(
      actor.initialised(State(
        host,
        config,
        dict.from_list(sessions),
        self,
        None,
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

fn dispatch_schedules(db: store.Store, registry: Subject(Message)) -> Nil {
  let time = schedule.now()
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
          Error(reason) -> {
            let _ = mail.record_failure(db, letter.id, reason)
            Nil
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
          case
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
          {
            Ok(_) -> True
            Error(_) -> False
          }
      }
      case delivered {
        True -> {
          let _ = schedule.advance(db, job, schedule.now())
          Nil
        }
        False -> Nil
      }
    }
  }
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
          |> result.map_error(fn(_) { Nil })
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

/// Release kernels that nobody is attached to: first those idle past the limit,
/// then, while the pool is over budget, the ones unattended longest. A session
/// that is attached or running is never a candidate, though its memory counts.
fn reap(workers: List(session.Session), config: Config) -> Nil {
  let reports =
    list.map(workers, fn(worker) { #(worker, session.report(worker)) })
  let held =
    list.filter_map(reports, fn(entry) {
      let #(worker, report) = entry
      case report.kernel {
        Some(pid) -> Ok(#(pid, worker, report))
        None -> Error(Nil)
      }
    })
  let usage = rss(list.map(held, fn(entry) { entry.0 }))
  let candidates =
    list.map(held, fn(entry) {
      let #(pid, _, report) = entry
      reaper.Candidate(
        pid,
        report.idle_ms,
        report.running,
        report.jobs,
        list.key_find(usage, pid) |> result.unwrap(0),
      )
    })
  let held_workers = list.map(held, fn(entry) { #(entry.0, entry.1) })
  reaper.victims(
    candidates,
    reaper.Limits(config.idle_ms, config.budget_kb, detached_ms),
  )
  |> list.each(fn(victim) {
    case list.key_find(held_workers, victim.pid) {
      Ok(worker) -> {
        let _ = session.release(worker)
        Nil
      }
      Error(_) -> Nil
    }
  })
  // Transcript state is durable and cheap to reload. Keep it only while a
  // client is polling or a run owns its prepared request.
  reports
  |> list.each(fn(entry) {
    let #(worker, report) = entry
    case
      report.history_loaded && !report.running && report.idle_ms >= detached_ms
    {
      True -> {
        let _ = session.evict_history(worker)
        Nil
      }
      False -> Nil
    }
  })
}

@external(erlang, "albedo_daemon", "rss")
fn rss(pids: List(Int)) -> List(#(Int, Int))

fn info_json(info: conversation.Info) -> json.Json {
  json.object([
    #("id", json.string(info.id)),
    #("title", json.string(info.title)),
    #("workspace", json.string(info.cwd)),
    #("provider", json.string(info.provider)),
    #("model", json.string(info.model)),
    #("effort", case info.effort {
      Some(effort) -> json.string(effort)
      None -> json.null()
    }),
    #("protocol", json.string(conversation.protocol(info.protocol))),
    #("last_assistant_at", case info.last_assistant_at {
      Some(timestamp) -> json.int(timestamp)
      None -> json.null()
    }),
  ])
}

/// Delete `id` and its descendants, children before parents. A running agent
/// is interrupted and given a few seconds to stop; one that will not stop
/// ends the walk with what was deleted so far still deleted.
fn delete_tree(registry: Subject(Message), id: String) -> Result(Int, String) {
  let db = runtime.ledger(actor.call(registry, 5000, Host))
  subtree(db, id, family.max_depth + 1)
  |> list.try_fold(0, fn(deleted, session_id) {
    case actor.call(registry, 10_000, Lookup(session_id, _)) {
      Ok(worker) -> stop_run(worker, session_id, 50)
      Error(_) -> Nil
    }
    actor.call(registry, 40_000, DeleteSession(session_id, _))
    |> result.replace(deleted + 1)
    |> result.map_error(fn(e) {
      family.name_of(db, session_id)
      <> ": "
      <> e
      <> " ("
      <> int.to_string(deleted)
      <> " deleted before it)"
    })
  })
}

/// `id` after everything below it.
fn subtree(db: store.Store, id: String, budget: Int) -> List(String) {
  let below = case budget {
    0 -> []
    _ ->
      family.children(db, id)
      |> result.unwrap([])
      |> list.flat_map(fn(child) { subtree(db, child.session, budget - 1) })
  }
  list.append(below, [id])
}

/// Interrupt a running session once, then give it up to `polls` tenths of a
/// second to stop.
fn stop_run(worker: session.Session, id: String, polls: Int) -> Nil {
  case bus.is_running(id) {
    False -> Nil
    True -> {
      process.spawn_unlinked(fn() { session.interrupt(worker) })
      wait_stopped(id, polls)
    }
  }
}

fn wait_stopped(id: String, polls: Int) -> Nil {
  case bus.is_running(id), polls {
    False, _ | _, 0 -> Nil
    True, _ -> {
      process.sleep(100)
      wait_stopped(id, polls - 1)
    }
  }
}

fn provider_models(
  host: runtime.Runtime,
  provider: configuration.Provider,
) -> List(String) {
  list.unique([
    provider.model,
    ..runtime.model_names(host, provider.extension, "")
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
      #(profile, provider_models(state.host, profile))
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
      case list.contains(provider_models(state.host, current), model) {
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
    use #(above, _) <- result.try(
      dict.get(state.sessions, parent)
      |> result.replace_error("session not found"),
    )
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
    use _ <- result.try(conversation.create(db, info))
    case family.link(db, info.id, parent, name) {
      Ok(member) -> Ok(#(info, member))
      Error(error) -> {
        let _ = conversation.delete(db, info.id)
        Error(error)
      }
    }
  }
  case created {
    Error(error) -> #(state, Error(error))
    Ok(#(info, member)) -> {
      bus.spawned(member, info.model)
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
          family_name(state, parent),
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
          let same =
            profiles
            |> list.filter(fn(profile) { profile.name == info.provider })
            |> list.flat_map(provider_models(state.host, _))
          let other =
            profiles
            |> list.filter(fn(profile) { profile.name != info.provider })
            |> list.flat_map(fn(profile) {
              provider_models(state.host, profile)
              |> list.map(fn(model) { profile.name <> "/" <> model })
            })
          list.unique([info.model, ..list.append(same, other)])
        }
      }
      #(state, Ok(json.array(listed, json.string)))
    }
  }
}

fn agent_tree(
  state: State,
  id: String,
) -> Result(#(String, List(AgentNode)), String) {
  let db = runtime.ledger(state.host)
  use _ <- result.try(
    dict.get(state.sessions, id) |> result.replace_error("session not found"),
  )
  let root = root_of(db, id, family.max_depth + 1)
  Ok(#(root, descendants(state, db, root, None)))
}

fn root_of(db: store.Store, id: String, budget: Int) -> String {
  case budget, family.get(db, id) {
    0, _ -> id
    _, Ok(Some(member)) -> root_of(db, member.parent, budget - 1)
    _, _ -> id
  }
}

/// `id` and everything below it, parents before children.
fn descendants(
  state: State,
  db: store.Store,
  id: String,
  member: Option(family.Member),
) -> List(AgentNode) {
  case dict.get(state.sessions, id) {
    Error(_) -> []
    Ok(#(cached, worker)) -> {
      // The cache keeps the title a session started with; its row has the
      // latest message's title or the name it was given.
      let info = conversation.get(db, id) |> result.unwrap(cached)
      let running = case worker {
        Some(_) -> bus.is_running(id)
        None -> False
      }
      let below =
        family.children(db, id)
        |> result.unwrap([])
        |> list.flat_map(fn(child) {
          descendants(state, db, child.session, Some(child))
        })
      [AgentNode(info, member, agent_name(db, info, member), running), ..below]
    }
  }
}

/// What the agents view calls a session: the name someone gave it, else a
/// child's family name, else a root's title.
fn agent_name(
  db: store.Store,
  info: conversation.Info,
  member: Option(family.Member),
) -> String {
  case member {
    None -> info.title
    Some(member) ->
      conversation.given_name(db, info.id) |> option.unwrap(member.name)
  }
}

/// `name` is for display; `address` is how agents mail a child, which a
/// rename leaves alone.
fn agent_json(node: AgentNode) -> json.Json {
  let family_fields = case node.member {
    Some(member) -> [
      #("parent", json.string(member.parent)),
      #("address", json.string(member.name)),
      #("depth", json.int(member.depth)),
      #("closed", json.bool(member.closed)),
    ]
    None -> [
      #("parent", json.null()),
      #("address", json.null()),
      #("depth", json.int(0)),
      #("closed", json.bool(False)),
    ]
  }
  json.object([
    #("session", info_json(node.info)),
    #("name", json.string(node.name)),
    #("running", json.bool(node.running)),
    ..family_fields
  ])
}

/// Every bus event, batched every 100 ms so a hundred streaming agents cost the
/// client ten frames a second, not thousands of writes.
fn agents_stream(req) {
  mist.server_sent_events(
    req,
    response.new(200),
    fn(self) {
      case process.subject_owner(self) {
        Ok(owner) ->
          bus.subscribe(owner, fn(event) { process.send(self, Heard(event)) })
        Error(_) -> Nil
      }
      process.send(self, Flush)
      #(self, [], 0, 0)
    },
    fn(state, message, connection) {
      let #(self, buffered, count, quiet) = state
      case message {
        // Past the cap, a stalled client loses deltas rather than memory.
        Heard(event) ->
          case count < 4000 {
            True ->
              actor.continue(#(self, [event, ..buffered], count + 1, quiet))
            False -> actor.continue(state)
          }
        Flush -> {
          let _ = process.send_after(self, 100, Flush)
          case buffered, quiet >= 50 {
            [], False -> actor.continue(#(self, [], 0, quiet + 1))
            _, _ -> {
              let body =
                string_tree.from_string("{\"events\":[")
                |> string_tree.append_tree(
                  list.reverse(buffered)
                  |> list.map(string_tree.from_string)
                  |> string_tree.join(","),
                )
                |> string_tree.append("]}")
              case mist.send_event(connection, mist.event(body)) {
                Error(_) -> actor.stop()
                Ok(_) -> actor.continue(#(self, [], 0, 0))
              }
            }
          }
        }
      }
    },
  )
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

fn listed_model_json(model: runtime.ListedModel) -> json.Json {
  let fact = fn(read) { option.then(model.info, read) }
  json.object([
    #("id", json.string(model.id)),
    #("efforts", json.array(model.efforts, json.string)),
    #(
      "context",
      json.nullable(fact(fn(info) { info.context_tokens }), json.int),
    ),
    // A window the user can raise to, and whether they have.
    #(
      "maxContext",
      json.nullable(fact(fn(info) { info.max_context_tokens }), json.int),
    ),
    #(
      "raised",
      json.bool(case model.info {
        Some(info) ->
          info.max_context_tokens != None
          && extension.window(info) == info.max_context_tokens
        None -> False
      }),
    ),
    #(
      "output",
      json.nullable(fact(fn(info) { info.max_output_tokens }), json.int),
    ),
    #(
      "input",
      model.info
        |> option.map(fn(info) { info.input_modalities })
        |> option.unwrap([])
        |> json.array(json.string),
    ),
  ])
}

fn tree_item_json(item: history.Item) -> json.Json {
  json.object([
    #("id", json.int(item.id)),
    #("type", json.string(history.kind_name(item.kind))),
    #("preview", json.string(item.preview)),
    #("timestamp", case item.timestamp {
      Some(timestamp) -> json.int(timestamp)
      None -> json.null()
    }),
  ])
}

fn tree_page_json(page: history.Page) -> json.Json {
  json.object([
    #("items", json.array(page.items, tree_item_json)),
    #("nextCursor", case page.next_cursor {
      Some(cursor) -> json.int(cursor)
      None -> json.null()
    }),
    #("hasMore", json.bool(page.has_more)),
  ])
}

fn extension_json(summary: extension.Summary) -> json.Json {
  json.object([
    #("name", json.string(summary.name)),
    #("description", json.string(summary.description)),
    #("enabled", json.bool(summary.enabled)),
    #("overridden", json.bool(summary.overridden)),
    #("global_enabled", json.bool(summary.global_enabled)),
    #("context", json.bool(summary.context)),
    #("tools", json.array(summary.tools, json.string)),
    #("python_modules", json.array(summary.python_modules, json.string)),
    #("requires", json.array(summary.requires, json.string)),
    #("plugins", json.array(summary.plugins, json.string)),
  ])
}

fn reply(status: Int, value: json.Json) {
  response.new(status)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(mist.Bytes(
    value |> json.to_string_tree |> bytes_tree.from_string_tree,
  ))
}

fn error(status: Int, message: String) {
  reply(status, json.object([#("error", json.string(message))]))
}

type SubmittedImage {
  SubmittedImage(
    mime_type: String,
    data: String,
    width: Int,
    height: Int,
    bytes: Int,
  )
}

fn submitted_image_decoder() -> decode.Decoder(SubmittedImage) {
  use mime_type <- decode.field("mimeType", decode.string)
  use data <- decode.field("data", decode.string)
  use width <- decode.field("width", decode.int)
  use height <- decode.field("height", decode.int)
  use bytes <- decode.field("bytes", decode.int)
  decode.success(SubmittedImage(mime_type, data, width, height, bytes))
}

fn validate_submitted_image(
  submitted: Option(SubmittedImage),
) -> Result(Option(types.Image), String) {
  case submitted {
    None -> Ok(None)
    Some(SubmittedImage(mime_type, data, width, height, bytes)) ->
      image.validate(mime_type, data, width, height, bytes)
      |> result.map(Some)
  }
}

fn body(req, decoder) {
  mist.read_body(req, 9_200_000)
  |> result.replace_error("invalid request body")
  |> result.try(fn(req) {
    json.parse_bits(req.body, decoder)
    |> result.replace_error("invalid request JSON")
  })
}

/// Sign-ins run here so every client shares one OAuth implementation;
/// clients render the url and poll the status.
fn auth(
  home: String,
  logins: List(oauth.Login),
  req: request.Request(mist.Connection),
  path: List(String),
) {
  let login = fn(provider) {
    list.find(logins, fn(login) { login.provider == provider })
    |> result.replace_error("no enabled sign-in for " <> provider)
  }
  let done = fn(outcome) {
    case outcome {
      Ok(Nil) -> reply(200, json.object([#("ok", json.bool(True))]))
      Error(e) -> error(400, e)
    }
  }
  case req.method, list.map(path, uri_decode) {
    Get, [] ->
      reply(
        200,
        json.object([
          #("logins", json.array(logins, oauth.login_json)),
          #(
            "accounts",
            json.preprocessed_array(
              list.flat_map(logins, fn(login) {
                oauth.accounts(home, login)
                |> distinct_labels
                |> list.map(oauth.account_json(login.provider, _))
              }),
            ),
          ),
        ]),
      )
    Post, [provider] ->
      case login(provider) |> result.try(oauth.start(home, _)) {
        Ok(#(id, url)) ->
          reply(
            201,
            json.object([#("id", json.string(id)), #("url", json.string(url))]),
          )
        Error(e) -> error(400, e)
      }
    Get, ["logins", id] ->
      case oauth.status(id) {
        Ok(status) -> reply(200, oauth.status_json(status))
        Error(e) -> error(404, e)
      }
    Post, ["logins", id] ->
      body(req, decode.field("input", decode.string, decode.success))
      |> result.try(oauth.input(id, _))
      |> done
    http.Delete, ["logins", id] -> oauth.cancel(id) |> done
    Post, [provider, "accounts", id] ->
      login(provider) |> result.try(oauth.select(home, _, id)) |> done
    http.Delete, [provider, "accounts", id] ->
      login(provider) |> result.try(oauth.remove(home, _, id)) |> done
    _, _ -> error(404, "not found")
  }
}

/// Accounts that share a label, such as one email on two plans, are told
/// apart by the start of their id.
fn distinct_labels(accounts: List(oauth.Account)) -> List(oauth.Account) {
  list.map(accounts, fn(account) {
    case list.count(accounts, fn(other) { other.label == account.label }) {
      1 -> account
      _ ->
        oauth.Account(
          ..account,
          label: account.label <> " · " <> string.slice(account.id, 0, 8),
        )
    }
  })
}

fn uri_decode(segment: String) -> String {
  uri.percent_decode(segment) |> result.unwrap(segment)
}

/// The daemon's own top-level routes; a service never shadows them.
const daemon_routes = [
  "health", "sessions", "models", "auth", "shutdown", "agents",
]

fn route(
  config: Config,
  registry: Subject(Message),
  req: request.Request(mist.Connection),
) -> response.Response(mist.ResponseData) {
  case request.path_segments(req) {
    [name, ..rest] ->
      case list.contains(daemon_routes, name) {
        True -> daemon_route(config, registry, req)
        False -> {
          let host = actor.call(registry, 5000, Host)
          case
            runtime.global(host)
            |> result.replace_error(Nil)
            |> result.try(extension.service(_, name))
          {
            // A browser page must not reach a local service that spends the
            // user's credentials, so cross-origin requests stay refused.
            Ok(service) ->
              case request.get_header(req, "origin") {
                Ok(_) -> error(403, "forbidden")
                Error(_) ->
                  service.handle(daemon(config, registry, host), rest, req)
              }
            Error(_) -> daemon_route(config, registry, req)
          }
        }
      }
    [] -> daemon_route(config, registry, req)
  }
}

fn daemon(
  config: Config,
  registry: Subject(Message),
  host: runtime.Runtime,
) -> extension.Daemon {
  extension.Daemon(
    config.home,
    runtime.ledger(host),
    fn(profile, model, session) {
      use provider <- result.try(configuration.named(config.home, profile))
      runtime.upstream(
        host,
        session,
        config.home,
        profile,
        provider.extension,
        model,
        provider.protocol,
        None,
      )
    },
    fn(provider, endpoint) { runtime.model_names(host, provider, endpoint) },
    fn() { actor.call(registry, 5000, List) },
  )
}

fn daemon_route(
  config: Config,
  registry: Subject(Message),
  req: request.Request(mist.Connection),
) -> response.Response(mist.ResponseData) {
  let authorised =
    request.get_header(req, "authorization") == Ok("Bearer " <> config.token)
  // Local API is authenticated and not a cross-origin browser endpoint.
  case authorised && request.get_header(req, "origin") == Error(Nil) {
    False -> error(403, "forbidden")
    True ->
      case req.method, request.path_segments(req) {
        Get, ["health"] ->
          reply(
            200,
            json.object([
              #("ok", json.bool(True)),
              #("version", json.int(2)),
              #(
                "capabilities",
                json.array(
                  [
                    "session_provider",
                    "session_workspace",
                    "session_extensions",
                    "global_extensions",
                    "session_tree",
                    "session_context",
                    "session_commands",
                  ],
                  json.string,
                ),
              ),
            ]),
          )
        Get, ["sessions"] ->
          reply(200, json.array(actor.call(registry, 5000, List), info_json))
        // The tree the given session belongs to, for the orchestrator view.
        Get, ["agents"] -> {
          let id =
            request.get_query(req)
            |> result.unwrap([])
            |> list.key_find("session")
            |> result.unwrap("")
          case actor.call(registry, 10_000, ReadAgents(id, _)) {
            Ok(#(root, nodes)) ->
              reply(
                200,
                json.object([
                  #("root", json.string(root)),
                  #("nodes", json.array(nodes, agent_json)),
                ]),
              )
            Error(e) -> error(404, e)
          }
        }
        Get, ["agents", "stream"] -> agents_stream(req)
        // `details` lists objects with catalog facts. Without it, plain ids.
        // Efforts come from where sessions of this extension look them up,
        // and facts from the endpoint, or there when none is given.
        Get, ["models", provider] -> {
          let query = request.get_query(req) |> result.unwrap([])
          let endpoint = list.key_find(query, "endpoint") |> result.unwrap("")
          let host = actor.call(registry, 5000, Host)
          let efforts_at = session_provider.effort_endpoint(provider)
          let facts_at = case endpoint {
            "" -> efforts_at
            _ -> endpoint
          }
          case list.key_find(query, "details") {
            Ok(_) ->
              reply(
                200,
                json.array(
                  runtime.listed_models(
                    host,
                    provider,
                    endpoint,
                    facts_at:,
                    efforts_at:,
                  ),
                  listed_model_json,
                ),
              )
            Error(_) ->
              reply(
                200,
                json.array(
                  runtime.model_names(host, provider, endpoint),
                  json.string,
                ),
              )
          }
        }
        _, ["auth", ..rest] ->
          auth(config.home, actor.call(registry, 5000, Logins), req, rest)
        Post, ["sessions"] -> {
          let decoder = {
            use cwd <- decode.field("workspace", decode.string)
            use model <- decode.optional_field("model", "", decode.string)
            decode.success(#(cwd, model))
          }
          case
            body(req, decoder)
            |> result.try(fn(pair) {
              actor.call(registry, 15_000, Create(pair.0, pair.1, _))
            })
          {
            Ok(info) -> reply(201, info_json(info))
            Error(e) -> error(400, e)
          }
        }
        Post, ["shutdown"] -> {
          let _ = process.send_after(registry, 100, Shutdown)
          reply(200, json.object([#("ok", json.bool(True))]))
        }
        // A blank name hands the title back to the latest message.
        Patch, ["sessions", id] ->
          case
            body(req, decode.field("name", decode.string, decode.success))
            |> result.try(fn(name) {
              actor.call(registry, 5000, Rename(id, name, _))
            })
          {
            Ok(info) -> reply(200, info_json(info))
            Error(e) -> error(409, e)
          }
        // With ?tree=1, the session and every agent below it, deepest first.
        Delete, ["sessions", id] -> {
          let tree =
            request.get_query(req)
            |> result.unwrap([])
            |> list.key_find("tree")
            == Ok("1")
          case tree {
            False ->
              actor.call(registry, 40_000, DeleteSession(id, _))
              |> result.replace(1)
            True -> delete_tree(registry, id)
          }
          |> fn(deleted) {
            case deleted {
              Ok(count) ->
                reply(
                  200,
                  json.object([
                    #("ok", json.bool(True)),
                    #("deleted", json.int(count)),
                  ]),
                )
              Error(e) -> error(409, e)
            }
          }
        }
        Get, ["sessions", id, "tree"] -> {
          let query = request.get_query(req) |> result.unwrap([])
          let after =
            query
            |> list.key_find("after")
            |> result.try(int.parse)
            |> result.unwrap(0)
          let limit =
            query
            |> list.key_find("limit")
            |> result.try(int.parse)
            |> result.unwrap(50)
          case actor.call(registry, 10_000, ReadTree(id, after, limit, _)) {
            Ok(page) -> reply(200, tree_page_json(page))
            Error(e) -> error(400, e)
          }
        }
        Get, ["sessions", id, "preview"] -> {
          let limit =
            request.get_query(req)
            |> result.unwrap([])
            |> list.key_find("limit")
            |> result.try(int.parse)
            |> result.unwrap(12)
          case actor.call(registry, 10_000, ReadRecent(id, limit, _)) {
            Ok(recent) ->
              reply(
                200,
                json.object([
                  #("items", json.array(recent.items, tree_item_json)),
                  #("total", json.int(recent.total)),
                ]),
              )
            Error(e) -> error(400, e)
          }
        }
        // Older transcript as rendered events, for a client scrolled past what
        // its reset carried: `before` is the `before` of the page it holds.
        Get, ["sessions", id, "history"] -> {
          let query = request.get_query(req) |> result.unwrap([])
          let before =
            list.key_find(query, "before")
            |> result.try(int.parse)
            |> option.from_result
          let rows =
            list.key_find(query, "rows")
            |> result.try(int.parse)
            |> result.unwrap(history_page_rows)
            |> int.clamp(1, 400)
          case actor.call(registry, 10_000, ReadHistory(id, before, rows, _)) {
            Ok(body) ->
              response.new(200)
              |> response.set_header("content-type", "application/json")
              |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
            Error(e) -> error(400, e)
          }
        }
        Get, ["sessions", id, "context", section, page] ->
          case
            int.parse(page)
            |> result.replace_error("invalid context page")
            |> result.try(fn(page) {
              actor.call(registry, 5000, Lookup(id, _))
              |> result.try(session.context_page(_, section, page))
            })
          {
            Ok(content) -> reply(200, content)
            Error(e) -> error(404, e)
          }
        Post, ["sessions", id, "fork"] -> {
          let decoder = decode.field("checkpoint", decode.int, decode.success)
          case
            body(req, decoder)
            |> result.try(fn(checkpoint) {
              actor.call(registry, 15_000, Fork(id, checkpoint, _))
            })
          {
            Ok(info) -> reply(201, info_json(info))
            Error(e) -> error(409, e)
          }
        }
        // A child session the user starts by hand; agents use the same path.
        Post, ["sessions", id, "children"] -> {
          let decoder = {
            use name <- decode.field("name", decode.string)
            use task <- decode.field("task", decode.string)
            use model <- decode.optional_field("model", "", decode.string)
            decode.success(#(name, task, model))
          }
          case
            body(req, decoder)
            |> result.try(fn(fields) {
              let #(name, task, model) = fields
              actor.call(registry, 15_000, CreateChild(id, name, task, model, _))
            })
          {
            Ok(#(info, member)) ->
              reply(
                201,
                json.object([
                  #("session", info_json(info)),
                  #("member", member_json(member)),
                ]),
              )
            Error(e) -> error(409, e)
          }
        }
        Get, ["sessions", id, "children"] ->
          case
            family.children(
              runtime.ledger(actor.call(registry, 5000, Host)),
              id,
            )
          {
            Ok(members) -> reply(200, json.array(members, member_json))
            Error(e) -> error(400, e)
          }
        // Mail written as session `id`: the daemon token is the user's, who may
        // speak for any of their sessions.
        Post, ["sessions", id, "mail"] -> {
          let decoder = {
            use to <- decode.field("to", decode.string)
            use text <- decode.field("body", decode.string)
            decode.success(#(to, text))
          }
          case
            body(req, decoder)
            |> result.try(fn(fields) {
              mail.send(
                runtime.ledger(actor.call(registry, 5000, Host)),
                id,
                fields.0,
                fields.1,
              )
            })
          {
            Ok(receipt) ->
              reply(
                202,
                json.object([
                  #("id", json.string(receipt.id)),
                  #("to", json.string(receipt.recipient)),
                  #("name", json.string(receipt.name)),
                  #("status", json.string(receipt.status)),
                ]),
              )
            Error(e) -> error(409, e)
          }
        }
        _, ["sessions", id, operation] ->
          case actor.call(registry, 5000, Lookup(id, _)) {
            Error(e) -> error(404, e)
            Ok(worker) ->
              case req.method, operation {
                Get, "context" -> reply(200, session.context(worker))
                Get, "commands" ->
                  case session.commands(worker) {
                    Ok(#(commands, _)) ->
                      reply(200, command.catalog_json(commands))
                    Error(e) -> error(409, e)
                  }
                Get, "extensions" ->
                  case session.extensions(worker) {
                    Ok(summaries) ->
                      reply(200, json.array(summaries, extension_json))
                    Error(e) -> error(409, e)
                  }
                Post, "extensions" -> {
                  // `scope` "global" changes the default every session
                  // without its own choice follows; "inherit" drops this
                  // session's choice. Omitted, it is a session choice.
                  let decoder = {
                    use name <- decode.field("name", decode.string)
                    use scope <- decode.optional_field(
                      "scope",
                      "session",
                      decode.string,
                    )
                    use enabled <- decode.optional_field(
                      "enabled",
                      None,
                      decode.optional(decode.bool),
                    )
                    case scope, enabled {
                      "session", Some(value) ->
                        decode.success(extension.SetSession(name, value))
                      "global", Some(value) ->
                        decode.success(extension.SetGlobal(name, value))
                      "inherit", _ -> decode.success(extension.Inherit(name))
                      _, _ ->
                        decode.failure(
                          extension.Inherit(name),
                          "scope session or global with enabled, or inherit",
                        )
                    }
                  }
                  case
                    body(req, decoder)
                    |> result.try(session.set_extension(worker, _))
                  {
                    Ok(summaries) ->
                      reply(200, json.array(summaries, extension_json))
                    Error(e) -> error(409, e)
                  }
                }
                Get, "status" ->
                  response.new(200)
                  |> response.set_header("content-type", "application/json")
                  |> response.set_body(
                    mist.Bytes(bytes_tree.from_string(session.status(worker))),
                  )
                Post, "events" -> {
                  let decoder = {
                    use kind <- decode.optional_field(
                      "type",
                      "user",
                      decode.string,
                    )
                    case kind {
                      "continue" | "resume" -> {
                        use client_id <- decode.optional_field(
                          "clientId",
                          "",
                          decode.string,
                        )
                        decode.success(#(True, "", client_id, None))
                      }
                      _ -> {
                        use text <- decode.field("content", decode.string)
                        use client_id <- decode.optional_field(
                          "clientId",
                          "",
                          decode.string,
                        )
                        use submitted_image <- decode.optional_field(
                          "image",
                          None,
                          decode.optional(submitted_image_decoder()),
                        )
                        decode.success(#(
                          False,
                          text,
                          client_id,
                          submitted_image,
                        ))
                      }
                    }
                  }
                  case
                    body(req, decoder)
                    |> result.map_error(session.Rejected)
                    |> result.try(fn(submission) {
                      let #(is_continue, text, client_id, raw_image) =
                        submission
                      case is_continue {
                        True -> session.submit_continue(worker, client_id)
                        False -> {
                          use image <- result.try(
                            validate_submitted_image(raw_image)
                            |> result.map_error(session.Rejected),
                          )
                          session.submit(worker, text, client_id, image)
                        }
                      }
                    })
                  {
                    Ok(queued) ->
                      reply(
                        202,
                        json.object([
                          #("ok", json.bool(True)),
                          #("queued", json.bool(queued)),
                        ]),
                      )
                    Error(session.Rejected(e)) -> error(409, e)
                    Error(session.Busy) ->
                      error(409, "session is busy or message queue is full")
                    Error(session.WorkspaceMissing(path)) ->
                      reply(
                        409,
                        json.object([
                          #("code", json.string("workspace_missing")),
                          #("workspace", json.string(path)),
                          #(
                            "error",
                            json.string("workspace not found: " <> path),
                          ),
                        ]),
                      )
                  }
                }
                Post, "workspace" -> {
                  case
                    body(
                      req,
                      decode.field("workspace", decode.string, decode.success),
                    )
                    // The session answers here, off the registry.
                    |> result.try(session.set_workspace(worker, _))
                    |> result.try(fn(_) {
                      actor.call(registry, 5000, Remember(id, _))
                    })
                  {
                    Ok(info) -> reply(200, info_json(info))
                    Error(e) -> error(409, e)
                  }
                }
                Post, "commands" -> {
                  case
                    body(req, decode.dynamic)
                    |> result.try(fn(fields) {
                      use #(name, supplied, raw, client) <- result.try(
                        command.decode_run(
                          ["name", "args", "arguments", "clientId"],
                          fields,
                        ),
                      )
                      use #(commands, context) <- result.try(session.commands(
                        worker,
                      ))
                      command.call(
                        commands,
                        context,
                        command.UserCall,
                        client,
                        name,
                        supplied,
                        raw,
                      )
                    })
                  {
                    Ok(command.Data(value)) ->
                      reply(200, json.object([#("result", value)]))
                    Ok(command.Turn(_, _)) ->
                      reply(202, json.object([#("submitted", json.bool(True))]))
                    Error(e) -> error(409, e)
                  }
                }
                Post, "interrupt" ->
                  reply(
                    200,
                    json.object([
                      #("interrupted", json.bool(session.interrupt(worker))),
                    ]),
                  )
                Get, "stream" -> stream(req, worker)
                _, _ -> error(404, "unknown session operation")
              }
          }
        _, _ -> error(404, "not found")
      }
  }
}

fn when_running(
  worker: session.Session,
  continue_: fn() -> actor.Next(state, message),
) -> actor.Next(state, message) {
  case process.subject_owner(worker) {
    Ok(pid) ->
      case process.is_alive(pid) {
        True -> continue_()
        False -> actor.stop()
      }
    Error(_) -> actor.stop()
  }
}

/// Rows a client asks for per history page when it does not say.
const history_page_rows = 120

fn stream(req, worker) {
  let query = request.get_query(req) |> result.unwrap([])
  let after =
    list.key_find(query, "after_seq")
    |> result.try(int.parse)
    |> result.unwrap(-1)
  // With `tail`, a reset replays only the newest rows; older ones are paged
  // from /sessions/:id/history. Without it, the whole transcript as before.
  let tail =
    list.key_find(query, "tail")
    |> result.try(int.parse)
    |> option.from_result
    |> option.map(int.clamp(_, 1, 400))
  mist.server_sent_events(
    req,
    response.new(200),
    fn(self) {
      // The session wakes this stream per event; the tick is only a keepalive
      // and the way a dropped connection is noticed while nothing is streaming.
      case process.subject_owner(self) {
        Ok(owner) ->
          session.watch(worker, owner, fn() { process.send(self, Wake) })
        Error(_) -> Nil
      }
      process.send(self, Tick)
      #(self, after)
    },
    fn(state, message, connection) {
      // A closing daemon stops session workers while clients are still attached,
      // so a dead worker ends this stream instead of failing a call into it.
      use <- when_running(worker)
      let page = session.read(worker, state.1, tail)
      case message, page.events {
        Wake, [] -> actor.continue(state)
        _, _ -> {
          let events =
            string_tree.from_strings([
              "{\"cursor\":",
              int.to_string(page.cursor),
              ",\"events\":[",
            ])
            |> string_tree.append_tree(
              page.events
              |> list.map(string_tree.from_string)
              |> string_tree.join(","),
            )
            |> string_tree.append("]}")
          case mist.send_event(connection, mist.event(events)) {
            Error(_) -> actor.stop()
            Ok(_) -> {
              case message {
                Tick -> {
                  let _ = process.send_after(state.0, 1000, Tick)
                  Nil
                }
                Wake -> Nil
              }
              actor.continue(#(state.0, page.cursor))
            }
          }
        }
      }
    },
  )
}

pub fn main() -> Nil {
  let home = env("ALBEDO_HOME")
  let token = env("ALBEDO_TOKEN")
  let config =
    Config(
      home,
      token,
      setting("ALBEDO_IDLE_SECONDS", 31 * 60, 10, 604_800) * 1000,
      setting("ALBEDO_KERNEL_BUDGET_MB", 2048, 64, 1_048_576) * 1024,
    )
  let assert True = string.byte_size(token) >= 32 && home != ""
    as "start albedo through its CLI"
  let assert Ok(_) = claim_home(home)
    as "another albedo daemon is already running for this ALBEDO_HOME"
  // A fixed port gives services such as the proxy a stable base url.
  let assert Ok(port) = start(config, setting("ALBEDO_PORT", 0, 0, 65_535))
  let assert Ok(_) = ready(home, port, token)
  inspect(home)
  watch_parent(env("ALBEDO_PARENT_PID"))
  process.sleep_forever()
}

/// An operator's limit, clamped to a range this daemon can honour.
fn setting(name: String, fallback: Int, low: Int, high: Int) -> Int {
  case int.parse(string.trim(env(name))) {
    Ok(value) -> int.clamp(value, low, high)
    Error(_) -> fallback
  }
}

@external(erlang, "albedo_daemon", "env")
fn env(name: String) -> String

/// Takes an exclusive SQLite lock on `home` for the life of the calling
/// process. Startup resumes saved sessions, so a second daemon on the same home
/// would run every in-flight turn twice. The OS drops the lock when the process
/// exits, so a crashed daemon never leaves it stale.
pub fn claim_home(home: String) -> Result(Nil, Nil) {
  use connection <- result.try(
    sqlight.open(home <> "/daemon.lock") |> result.replace_error(Nil),
  )
  case
    // The transaction is never committed: holding it open keeps the exclusive
    // lock, and a refused BEGIN leaves no lock behind on its connection.
    sqlight.exec("BEGIN EXCLUSIVE;", connection)
  {
    Ok(_) -> Ok(hold(connection))
    Error(_) -> {
      let _ = sqlight.close(connection)
      Error(Nil)
    }
  }
}

@external(erlang, "albedo_daemon", "hold")
fn hold(connection: sqlight.Connection) -> Nil

@external(erlang, "albedo_daemon", "ready")
fn ready(home: String, port: Int, token: String) -> Result(Nil, String)

@external(erlang, "albedo_daemon", "directory")
fn directory(path: String) -> Bool

@external(erlang, "albedo_daemon", "shutdown")
fn shutdown() -> Nil

@external(erlang, "albedo_inspect", "start")
fn inspect(home: String) -> Nil

@external(erlang, "albedo_daemon", "watch_parent")
fn watch_parent(pid: String) -> Nil

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
