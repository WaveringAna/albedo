//// An embeddable extension runtime with durable work and session-owned Python kernels.

import albedo/actor_call
import albedo/daemon/configuration
import albedo/daemon/session_catalog
import albedo/daemon/store
import albedo/harness/command
import albedo/harness/compaction
import albedo/harness/extension
import albedo/harness/extensions
import albedo/harness/extensions/python/cells as journal
import albedo/harness/extensions/python/kernel as python
import albedo/harness/extensions/python/link
import albedo/harness/extensions/work/ledger as work
import albedo/harness/oauth
import albedo/harness/protect
import albedo/harness/runtime/kernels
import albedo/harness/runtime/observation
import albedo/harness/runtime/preparation
import albedo/harness/runtime/state as runtime_state
import albedo/openai_api/types
import albedo/shared
import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/erlang/reference.{type Reference}
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string

/// The handle every caller holds; see `runtime/state`.
pub type Runtime =
  runtime_state.Runtime

/// One session's kernel and prepared composition; see `runtime/state`.
pub type Session =
  runtime_state.Session

pub type Origin =
  runtime_state.Origin

pub type KernelUpgrade =
  runtime_state.KernelUpgrade

pub type CompositionObservation =
  runtime_state.CompositionObservation

pub type LoadedObservation =
  runtime_state.LoadedObservation

pub type CatalogObservation =
  runtime_state.CatalogObservation

pub fn upgrade_async(
  runtime: runtime_state.Runtime,
  id: String,
  answer: fn(Result(runtime_state.KernelUpgrade, String)) -> Nil,
) -> Nil {
  case process.subject_owner(runtime.subject) {
    Error(_) -> answer(Error("runtime owner is unavailable"))
    Ok(owner) -> {
      process.spawn_unlinked(fn() {
        let monitor = process.monitor(owner)
        let reply = process.new_subject()
        process.send(
          runtime.subject,
          runtime_state.Upgrade(id, fn(outcome) { process.send(reply, outcome) }),
        )
        let selector =
          process.new_selector()
          |> process.select(reply)
          |> process.select_specific_monitor(monitor, fn(_) {
            Error("runtime owner stopped during kernel upgrade")
          })
        let outcome = await_upgrade(selector)
        process.demonitor_process(monitor)
        answer(outcome)
      })
      Nil
    }
  }
}

// The HTTP caller can time out while the actual action remains in flight.
// Keep its one completion waiter until ownership settles or the owner dies.
fn await_upgrade(
  selector: process.Selector(Result(runtime_state.KernelUpgrade, String)),
) -> Result(runtime_state.KernelUpgrade, String) {
  case process.selector_receive(selector, 185_000) {
    Ok(outcome) -> outcome
    Error(_) -> await_upgrade(selector)
  }
}

pub fn observe_composition(
  runtime: runtime_state.Runtime,
  home: String,
  id: String,
) -> Result(runtime_state.CompositionObservation, String) {
  use _owner <- result.try(
    process.subject_owner(runtime.subject)
    |> result.replace_error("runtime owner is unavailable"),
  )
  actor_call.try_call(
    runtime.subject,
    runtime_state.observe_call_ms,
    runtime_state.ObserveComposition(home, id, _),
  )
  |> result.map_error(fn(error) {
    case error {
      actor_call.CalleeDown ->
        "runtime owner stopped during composition observation"
      actor_call.TimedOut -> "runtime composition observation is unavailable"
    }
  })
  |> result.flatten
}

/// Sessions with an actual prepared composition; observing this set does not
/// prepare another session or attach its kernel.
pub fn loaded_sessions(runtime: runtime_state.Runtime) -> List(String) {
  actor.call(runtime.subject, 5000, runtime_state.LoadedIDs)
}

/// Every kernel the runtime holds, by session, whether or not a session actor
/// has claimed it.
pub fn held_kernels(
  runtime: runtime_state.Runtime,
) -> List(#(String, runtime_state.Session)) {
  actor.call(runtime.subject, 5000, runtime_state.HeldKernels)
}

/// Desired discovery and retained commands are independent observations. A
/// failed desired read cannot erase the composition the owner actually loaded.
pub fn observe_catalog(
  runtime: runtime_state.Runtime,
  home: String,
  id: String,
) -> Result(runtime_state.CatalogObservation, String) {
  use _owner <- result.try(
    process.subject_owner(runtime.subject)
    |> result.replace_error("runtime owner is unavailable"),
  )
  actor_call.try_call(runtime.subject, 15_000, runtime_state.ObserveCatalog(
    home,
    id,
    _,
  ))
  |> result.map_error(fn(error) {
    case error {
      actor_call.CalleeDown ->
        "runtime owner stopped during catalog observation"
      actor_call.TimedOut -> "runtime catalog observation is unavailable"
    }
  })
  |> result.flatten
}

/// Observe retained loaded state even when desired discovery is unreadable.
pub fn observe_loaded(
  runtime: runtime_state.Runtime,
  id: String,
) -> Result(runtime_state.LoadedObservation, String) {
  use _owner <- result.try(
    process.subject_owner(runtime.subject)
    |> result.replace_error("runtime owner is unavailable"),
  )
  actor_call.try_call(runtime.subject, 5000, runtime_state.ObserveLoaded(id, _))
  |> result.map_error(fn(error) {
    case error {
      actor_call.CalleeDown -> "runtime owner stopped during observation"
      actor_call.TimedOut -> "loaded runtime observation is unavailable"
    }
  })
  |> result.flatten
}

pub fn start(
  database: String,
) -> Result(runtime_state.Runtime, actor.StartError) {
  start_with_config(database, extensions.defaults())
}

pub fn start_with_extensions(
  database: String,
  installed: List(extension.Extension),
) -> Result(runtime_state.Runtime, actor.StartError) {
  start_with_config(
    database,
    extensions.Config(
      installed,
      list.map(installed, fn(extension) { extension.name }),
    ),
  )
}

pub fn start_with_config(
  database: String,
  config: extensions.Config,
) -> Result(runtime_state.Runtime, actor.StartError) {
  let installed = config.extensions
  let default_enabled = config.default_enabled
  actor.new_with_initialiser(10_000, fn(subject) {
    runtime_state.label("albedo_runtime", database)
    use ledger <- result.try(
      store.start(
        database,
        "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=3000;",
      )
      |> result.replace_error("could not open storage"),
    )
    // A failed install still owns the ledger: close it before the error escapes.
    use installation <- result.try(
      extension.install(installed, default_enabled, ledger)
      |> result.map_error(fn(error) {
        work.close(ledger)
        error
      }),
    )
    let #(installed, quarantined) = installation
    list.each(quarantined, fn(failure) {
      io.println_error(
        "extension " <> failure.name <> " is quarantined: " <> failure.reason,
      )
    })
    let installed =
      shared.publish(runtime_state.Installed(
        installed,
        default_enabled,
        quarantined,
      ))
    Ok(
      actor.initialised(runtime_state.State(
        work: ledger,
        sessions: dict.new(),
        compositions: dict.new(),
        desired: dict.new(),
        installed: installed,
        self: subject,
        booting: dict.new(),
        waiting: [],
        observing: 0,
        preparing: dict.new(),
        commands: dict.new(),
        detaching: False,
        deferred: dict.new(),
      ))
      |> actor.returning(runtime_state.Runtime(subject, ledger, installed)),
    )
  })
  |> actor.on_message(handle)
  |> actor.start
  |> result.map(fn(started) { started.data })
}

pub fn ledger(runtime: runtime_state.Runtime) -> work.Store {
  runtime.work
}

/// Apply installed extensions' data upgrades after core storage is ready, before
/// opening sessions. Embedding hosts supply their own pre-upgrade backup path.
pub fn migrate(
  runtime: runtime_state.Runtime,
  backup: String,
) -> Result(List(#(String, Int)), String) {
  extension.migrate(installed(runtime), runtime.work, backup)
}

/// Every installed extension's cleanup for a deleted session.
pub fn cleaners(runtime: runtime_state.Runtime) -> List(extension.Cleaner) {
  extension.cleaners(installed(runtime))
}

pub fn open_session(
  runtime: runtime_state.Runtime,
  id: String,
  cwd: String,
) -> Result(runtime_state.Session, python.Error) {
  use id <- result.try(kernels.checked_id(id))
  let reply = process.new_subject()
  open_session_async(runtime, id, cwd, process.send(reply, _))
  process.receive(reply, 180_000)
  |> result.replace_error(python.Unavailable(
    "the kernel did not start in time; other sessions may be starting theirs",
  ))
  |> result.flatten
}

/// Ask for a session's kernel; `answer` runs once it is ready or has failed.
/// Kernels boot a few at a time outside this actor, so asking never blocks.
pub fn open_session_async(
  runtime: runtime_state.Runtime,
  id: String,
  cwd: String,
  answer: fn(Result(runtime_state.Session, python.Error)) -> Nil,
) -> Nil {
  case kernels.checked_id(id) {
    Ok(id) -> process.send(runtime.subject, runtime_state.Open(id, cwd, answer))
    Error(invalid) -> answer(Error(invalid))
  }
}

/// Reload an idle daemon session with a proposed extension composition. A replacement
/// kernel and all context/modules are prepared before the persisted selection changes.
pub fn reload_extension(
  runtime: runtime_state.Runtime,
  id: String,
  cwd: String,
  name: String,
  enabled: Bool,
) -> Result(runtime_state.Session, String) {
  use replaced <- result.try(change_extension(
    runtime,
    id,
    cwd,
    extension.SetSession(name, enabled),
  ))
  case replaced {
    Some(session) -> Ok(session)
    None ->
      open_session(runtime, id, cwd)
      |> result.map_error(string.inspect)
  }
}

/// Applies an extension change for one session. A change that leaves this
/// session's selection as it was is only recorded and answers `None`;
/// otherwise the session gets a replacement kernel prepared and swapped in.
pub fn change_extension(
  runtime: runtime_state.Runtime,
  id: String,
  cwd: String,
  change: extension.Change,
) -> Result(Option(runtime_state.Session), String) {
  actor.call(runtime.subject, 30_000, runtime_state.Reload(id, cwd, change, _))
}

/// Prepare the saved composition before replacing the running one. A live
/// kernel keeps its namespace through a route rebind or native state carry;
/// a parked session remains parked. Preparation and kernel work run outside
/// the runtime owner, while opens and further reloads wait for this decision.
pub fn reload_desired(
  runtime: runtime_state.Runtime,
  id: String,
  cwd: String,
) -> Result(Option(runtime_state.Session), String) {
  actor.call(runtime.subject, 180_000, runtime_state.ReloadDesired(id, cwd, _))
}

/// Save and reload in the composition owner. No caller holds a settings lock
/// while waiting for this actor, whose extension operations also persist choices.
pub fn peek_prompt(
  runtime: runtime_state.Runtime,
  id: String,
) -> Option(#(String, List(types.Input))) {
  actor.call(runtime.subject, 10_000, runtime_state.PeekPrompt(id, _))
}

/// Extension context blocks included in this session's system instructions.
pub fn context(session: runtime_state.Session) -> List(types.Input) {
  session.context
}

pub fn extension_summaries(
  runtime: runtime_state.Runtime,
  id: String,
) -> Result(List(extension.Summary), String) {
  actor.call(runtime.subject, 10_000, runtime_state.Summaries(id, _))
}

/// Drop the session's kernel but keep its prepared composition. Catalog reads
/// and command runs keep working without booting Python again.
pub fn reset_session(runtime: runtime_state.Runtime, id: String) -> Nil {
  actor.call(runtime.subject, 10_000, runtime_state.Reset(id, _))
}

/// Drop the session's kernel and its prepared composition together.
pub fn forget_session(runtime: runtime_state.Runtime, id: String) -> Nil {
  actor.call(runtime.subject, 10_000, runtime_state.Forget(id, _))
}

/// Remove runtime state only after supervising the actual recorded processes.
pub fn delete_session(
  runtime: runtime_state.Runtime,
  id: String,
) -> Result(Nil, String) {
  use _owner <- result.try(
    process.subject_owner(runtime.subject)
    |> result.replace_error("runtime owner is unavailable"),
  )
  actor_call.try_call(runtime.subject, 30_000, runtime_state.Delete(id, _))
  |> result.map_error(fn(error) {
    case error {
      actor_call.CalleeDown -> "runtime owner stopped during deletion"
      actor_call.TimedOut ->
        "runtime did not confirm deletion before its deadline"
    }
  })
  |> result.flatten
}

/// This session's materialized commands and their state context, served from
/// the prepared composition without opening a kernel.
pub fn peek_commands(
  runtime: runtime_state.Runtime,
  id: String,
  cwd: String,
) -> Result(#(List(command.Command), command.Context), String) {
  actor.call(runtime.subject, 15_000, runtime_state.Peek(id, cwd, _))
}

pub fn stop(runtime: runtime_state.Runtime) -> Nil {
  actor.call(runtime.subject, 10_000, runtime_state.Stop)
  shared.release(runtime.installed)
}

/// From now on, closing a session or stopping the runtime lets its kernel go
/// instead of ending it: a daemon shutting down calls this first, so the
/// kernels keep their namespaces and jobs for the next daemon.
pub fn detach_kernels(runtime: runtime_state.Runtime) -> Nil {
  actor.call(runtime.subject, 10_000, runtime_state.Detach)
}

/// Attach every recorded kernel again, one at a time in the background, so
/// a restarted daemon hears their late results and job wakes without waiting
/// for each session to need its kernel. A kernel that is gone is forgotten.
/// `awaited` hears each session whose kernel came back running a job that
/// will wake it, one not started as a service.
pub fn resume_kernels(
  runtime: runtime_state.Runtime,
  awaited: fn(String) -> Nil,
) -> Nil {
  let subject = runtime.subject
  let work = runtime.work
  process.spawn_unlinked(fn() {
    list.each(python.recorded(work), fn(entry) {
      let #(id, cwd) = entry
      let reply = process.new_subject()
      process.send(subject, runtime_state.Reattach(id, cwd, reply))
      let _ = process.receive(reply, 60_000)
      let awaiting = case observe_loaded(runtime, id) {
        Ok(runtime_state.LoadedObservation(kernel: Some(observed), ..)) ->
          list.any(observed.running_jobs, fn(job) { !job.service })
        _ -> False
      }
      case awaiting {
        True -> awaited(id)
        False -> Nil
      }
    })
  })
  Nil
}

pub fn origin(session: runtime_state.Session) -> runtime_state.Origin {
  session.origin
}

pub fn kernel_observation(
  session: runtime_state.Session,
) -> Result(python.Observation, Nil) {
  python.observation(session.kernel)
}

pub fn alive(session: runtime_state.Session) -> Bool {
  python.alive(session.kernel)
}

pub fn interrupt(session: runtime_state.Session) -> Nil {
  python.interrupt(session.kernel)
}

pub fn warnings(session: runtime_state.Session) -> List(String) {
  extension.warnings(session.composition)
}

pub fn kernel_pid(session: runtime_state.Session) -> Result(Int, Nil) {
  python.os_pid(session.kernel)
}

/// Background jobs whose groups the kernel still owns, local or remote. A
/// released kernel would kill them, so the idle sweep keeps kernels with
/// live jobs alive.
pub fn job_count(session: runtime_state.Session) -> Int {
  python.job_count(session.kernel)
}

/// Stop one background job by id.
pub fn stop_job(
  session: runtime_state.Session,
  id: String,
) -> Result(Nil, String) {
  python.stop_job(session.kernel, id)
}

pub fn save_state(
  session: runtime_state.Session,
  path: String,
  timeout_ms: Int,
) -> Result(python.Saved, python.Error) {
  python.snapshot(session.kernel, path, timeout_ms)
}

pub fn load_state(
  session: runtime_state.Session,
  path: String,
  timeout_ms: Int,
) -> Result(python.Saved, python.Error) {
  python.restore(session.kernel, path, timeout_ms)
}

pub type Execution {
  Execution(cell_id: String, result: Result(python.Outcome, python.Error))
}

pub fn execute(
  runtime: runtime_state.Runtime,
  session: runtime_state.Session,
  code: String,
  timeout_ms: Int,
) -> Result(Execution, String) {
  use _ <- result.try(owned_by(runtime, session))
  use id <- result.try(journal.begin(runtime.work, session.id, code))
  let outcome =
    python.execute_saved(session.kernel, id, code, timeout_ms, types.any_images)
  use _ <- result.try(journal.settle(runtime.work, id, outcome))
  Ok(Execution(id, outcome))
}

pub fn cell(
  runtime: runtime_state.Runtime,
  id: String,
) -> Result(journal.Cell, String) {
  journal.get(runtime.work, id)
}

fn owned_by(
  runtime: runtime_state.Runtime,
  session: runtime_state.Session,
) -> Result(Nil, String) {
  case session.owner == runtime.work {
    True -> Ok(Nil)
    False -> Error("session belongs to another runtime")
  }
}

/// Swap a stale kernel for a current one off the actor, the way a boot runs:
/// whoever opens the session meanwhile waits for it. A swap that cannot
/// happen now (a cell still running, a namespace that would not save) hands
/// the old kernel back, still stale, to try again at the next open.
fn start_upgrade(
  state: runtime_state.State,
  id: String,
  session: runtime_state.Session,
  answer: fn(Result(runtime_state.Session, python.Error)) -> Nil,
) -> runtime_state.State {
  case dict.get(state.compositions, id) {
    Error(_) -> {
      answer(Ok(runtime_state.Session(..session, origin: runtime_state.Kept)))
      state
    }
    Ok(cached) -> {
      let self = state.self
      let owner = state.work
      let generation = reference.new()
      process.spawn_unlinked(fn() {
        let upgraded =
          protect.attempt(fn() {
            python.upgrade(
              owner,
              id,
              cached.cwd,
              kernels.kernel_routes(owner, id, cached.composition),
              extension.python_modules(cached.composition),
              session.kernel,
            )
          })
        let result = case upgraded {
          Ok(Ok(#(kernel, carried))) ->
            Ok(kernels.session_over(
              owner,
              id,
              cached,
              kernel,
              runtime_state.Upgraded(carried),
            ))
          Ok(Error(error)) -> {
            io.println_error(
              "kernel upgrade waits: " <> string.inspect(error.reason),
            )
            case python.alive(session.kernel) {
              True ->
                Ok(runtime_state.Session(..session, origin: runtime_state.Kept))
              False -> Error(error.reason)
            }
          }
          Error(crash) -> {
            io.println_error("kernel upgrade failed: " <> crash)
            case python.alive(session.kernel) {
              True ->
                Ok(runtime_state.Session(..session, origin: runtime_state.Kept))
              False -> Error(python.Unavailable(crash))
            }
          }
        }
        case runtime_state.owner_alive(self) {
          True ->
            process.send(self, runtime_state.Booted(id, generation, result))
          False -> {
            case result {
              Ok(session) ->
                kernels.drop_kernel("upgrade for a stopped runtime", session)
              Error(_) -> Nil
            }
          }
        }
      })
      runtime_state.State(
        ..runtime_state.without_session(state, id),
        booting: dict.insert(
          state.booting,
          id,
          runtime_state.Booting(generation, [answer]),
        ),
      )
    }
  }
}

fn start_kernel_upgrade(
  state: runtime_state.State,
  id: String,
  answer: fn(Result(runtime_state.KernelUpgrade, String)) -> Nil,
) -> runtime_state.State {
  case dict.has_key(state.booting, id) {
    True -> runtime_state.defer(state, id, runtime_state.Upgrade(id, answer))
    False -> {
      let previous = dict.get(state.sessions, id) |> option.from_result
      let prepared = case previous {
        Some(_) ->
          dict.get(state.compositions, id)
          |> result.map(fn(cached) { Some(#(cached.cwd, Some(cached))) })
          |> result.replace_error("prepared composition missing")
        None -> {
          use recorded <- result.try(link.lookup(state.work, id))
          Ok(
            option.map(recorded, fn(record) {
              #(
                record.cwd,
                dict.get(state.compositions, id) |> option.from_result,
              )
            }),
          )
        }
      }
      case prepared {
        Error(reason) -> {
          answer(Error(reason))
          state
        }
        Ok(None) -> {
          answer(
            Ok(runtime_state.KernelUpgrade(
              "unchanged",
              None,
              None,
              None,
              [],
              [],
              None,
            )),
          )
          state
        }
        Ok(Some(#(cwd, cached))) -> {
          let generation = reference.new()
          let state =
            runtime_state.State(
              ..runtime_state.without_session(state, id),
              booting: dict.insert(
                state.booting,
                id,
                runtime_state.Booting(generation, []),
              ),
            )
          case cached {
            Some(cached) if cached.cwd == cwd ->
              runtime_state.State(
                ..state,
                waiting: list.append(state.waiting, [
                  runtime_state.UpgradeKernel(
                    id,
                    generation,
                    cached,
                    previous,
                    answer,
                  ),
                ]),
              )
            _ ->
              preparation.prepare(
                state,
                id,
                cwd,
                generation,
                runtime_state.UpgradeRecorded(answer),
              )
          }
        }
      }
    }
  }
}

fn upgrade_value(
  owner: work.Store,
  id: String,
  cached: runtime_state.Cached,
  previous: Option(runtime_state.Session),
) -> Result(runtime_state.KernelUpgrade, String) {
  use current <- result.try(case previous {
    Some(session) -> Ok(session)
    None ->
      kernels.resume_kernel(owner, id, cached)
      |> option.to_result("recorded kernel could not be attached")
  })
  case python.observation(current.kernel) {
    Error(_) ->
      Ok(runtime_state.KernelUpgrade(
        "failed",
        None,
        None,
        Some(current),
        [],
        [],
        Some("the live kernel did not answer observation"),
      ))
    Ok(old) ->
      case old.stale {
        None ->
          Ok(runtime_state.KernelUpgrade(
            "unchanged",
            Some(old),
            Some(old),
            Some(current),
            [],
            [],
            None,
          ))
        Some(_) -> {
          let outcome =
            python.upgrade(
              owner,
              id,
              cached.cwd,
              kernels.kernel_routes(owner, id, cached.composition),
              extension.python_modules(cached.composition),
              current.kernel,
            )
          let #(session, failure, restored_warnings, stopped) = case outcome {
            Ok(#(kernel, carried)) -> #(
              Some(kernels.session_over(
                owner,
                id,
                cached,
                kernel,
                runtime_state.Upgraded(carried),
              )),
              None,
              list.map(carried.saved.missed, fn(item) {
                item.0 <> ": " <> item.1
              }),
              carried.stopped_jobs,
            )
            Error(error) -> #(
              case python.alive(current.kernel) {
                True -> Some(current)
                False -> None
              },
              Some(string.inspect(error.reason)),
              [],
              error.stopped_jobs,
            )
          }
          let observed =
            option.then(session, fn(value) {
              python.observation(value.kernel) |> option.from_result
            })
          let warnings =
            list.append(
              restored_warnings,
              case
                old.live_job_count > list.length(stopped)
                && { failure == None || stopped != [] }
              {
                True -> [
                  "some jobs observed before upgrade have no individually reported stop identity",
                ]
                False -> []
              },
            )
          Ok(
            runtime_state.KernelUpgrade(
              case failure, observed {
                None, Some(_) -> "upgraded"
                _, _ -> "failed"
              },
              Some(old),
              observed,
              session,
              stopped,
              warnings,
              case failure, observed {
                None, None -> Some("replacement observation unavailable")
                _, _ -> failure
              },
            ),
          )
        }
      }
  }
}

fn kernel_upgraded(
  state: runtime_state.State,
  id: String,
  generation: Reference,
  previous: Option(runtime_state.Session),
  outcome: Result(runtime_state.KernelUpgrade, String),
  answer: fn(Result(runtime_state.KernelUpgrade, String)) -> Nil,
) -> runtime_state.State {
  case runtime_state.current_work(state, id, generation) {
    False -> {
      discard_upgrade(previous, outcome)
      answer(Error("the session closed during kernel upgrade"))
      state
    }
    True -> {
      let current = case outcome {
        Ok(report) -> report.session
        Error(_) -> previous
      }
      let state = case current {
        Some(session) ->
          runtime_state.holding(state, id, runtime_state.handed_out(session))
        None -> runtime_state.without_session(state, id)
      }
      let waiters =
        dict.get(state.booting, id)
        |> result.map(fn(booting) { booting.waiters })
        |> result.unwrap([])
      let state =
        runtime_state.State(..state, booting: dict.delete(state.booting, id))
      let state =
        preparation.finish_commands(
          state,
          id,
          dict.get(state.compositions, id)
            |> result.replace_error("prepared composition is unavailable"),
        )
      answer(outcome)
      list.each(list.reverse(waiters), fn(waiter) {
        waiter(case current {
          Some(session) -> Ok(session)
          None ->
            Error(python.Unavailable(
              "kernel upgrade left no attached namespace",
            ))
        })
      })
      runtime_state.replay(state, id)
    }
  }
}

/// Admit the oldest eligible request, preserving order within each class.
/// Kernels belong to the store and outlive the workers that prepare them.
fn boot_next(state: runtime_state.State) -> runtime_state.State {
  let running = runtime_state.active(state)
  let preparations = running - state.observing
  let #(skipped, eligible) = case running < runtime_state.boot_slots {
    True ->
      list.split_while(state.waiting, fn(request) {
        case request {
          runtime_state.Observe(..) ->
            state.observing >= runtime_state.boot_slots - 1
          _ -> preparations >= runtime_state.boot_slots - 1
        }
      })
    False -> #([], [])
  }
  case eligible {
    [request, ..rest] -> {
      let state =
        runtime_state.State(
          ..state,
          waiting: list.append(skipped, rest),
          observing: state.observing
            + case request {
              runtime_state.Observe(..) -> 1
              _ -> 0
            },
        )
      let self = state.self
      let owner = state.work
      case request {
        runtime_state.Observe(id, home, reply, retries) -> {
          let inventory = observation.composition_inventory(state)
          // A read captures only this session's bases, never the runtime cache.
          let retained =
            list.filter_map(
              [
                dict.get(state.desired, id) |> option.from_result,
                dict.get(state.compositions, id)
                  |> option.from_result
                  |> option.then(fn(value) { value.basis }),
              ],
              option.to_result(_, Nil),
            )
          let cached = dict.get(state.compositions, id) |> option.from_result
          process.spawn_unlinked(fn() {
            let discovered =
              protect.attempt(fn() {
                case reply {
                  runtime_state.CompositionReply(_) ->
                    observation.retained_desired(inventory, retained, home, id)
                  runtime_state.CatalogReply(_) ->
                    observation.desired(inventory, retained, home, id)
                }
              })
              |> result.flatten
            let observed = case reply {
              runtime_state.CompositionReply(_) ->
                runtime_state.CompositionResult({
                  use value <- result.try(discovered)
                  protect.attempt(fn() {
                    observation.observe_composition_value(
                      inventory,
                      cached,
                      value.snapshot,
                      id,
                    )
                  })
                  |> result.flatten
                })
              runtime_state.CatalogReply(_) ->
                runtime_state.CatalogResult({
                  use _ <- result.try(case discovered {
                    Error("session not found") -> Error("session not found")
                    _ -> Ok(Nil)
                  })
                  Ok(runtime_state.CatalogObservation(
                    result.map(discovered, fn(value) { value.snapshot }),
                    option.then(cached, fn(value) { value.loaded_revision }),
                    option.map(cached, fn(value) {
                      extension.command_entries(value.composition)
                    })
                      |> option.unwrap([]),
                    option.map(cached, fn(value) {
                      extension.client_commands(value.composition)
                    })
                      |> option.unwrap([]),
                  ))
                })
            }
            // Recheck after plugin observation, not just after file discovery.
            let discovered =
              protect.attempt(fn() {
                use value <- result.try(discovered)
                use unchanged <- result.try(case reply {
                  runtime_state.CompositionReply(_) ->
                    session_catalog.saved_key(home, inventory, id)
                    |> result.map(fn(saved) { saved == value.saved })
                  runtime_state.CatalogReply(_) ->
                    session_catalog.inputs(home, inventory, id)
                    |> result.map(fn(after) { after.key == value.inputs })
                })
                case unchanged {
                  True -> Ok(value)
                  False ->
                    Error("composition inputs changed during observation")
                }
              })
              |> result.flatten
            process.send(
              self,
              runtime_state.Observed(
                id,
                home,
                retries,
                cached,
                discovered,
                reply,
                observed,
              ),
            )
          })
        }
        runtime_state.Compose(id, cwd, generation) -> {
          let inventory = observation.composition_inventory(state)
          let retained = observation.retained_basis(state)
          process.spawn_unlinked(fn() {
            let prepared =
              protect.attempt(fn() {
                preparation.build_cached(inventory, id, cwd, None, [], retained)
              })
              |> result.flatten
            case runtime_state.owner_alive(self) {
              True ->
                process.send(
                  self,
                  runtime_state.Composed(id, generation, prepared),
                )
              False -> {
                case prepared {
                  Ok(cached) -> extension.close(cached.composition)
                  Error(_) -> Nil
                }
              }
            }
          })
        }
        runtime_state.BootKernel(id, generation, cached) ->
          process.spawn_unlinked(fn() {
            let outcome = case
              protect.attempt(fn() { kernels.open_kernel(owner, id, cached) })
            {
              Ok(result) -> result
              Error(crash) ->
                Error(python.Unavailable("kernel boot failed: " <> crash))
            }
            case runtime_state.owner_alive(self) {
              True ->
                process.send(
                  self,
                  runtime_state.Booted(id, generation, outcome),
                )
              False -> {
                case outcome {
                  Ok(session) ->
                    kernels.drop_kernel("boot for a stopped runtime", session)
                  Error(_) -> Nil
                }
              }
            }
          })
        runtime_state.AttachKernel(id, generation, cached, reply) ->
          process.spawn_unlinked(fn() {
            let outcome =
              protect.attempt(fn() { kernels.resume_kernel(owner, id, cached) })
              |> result.map_error(fn(crash) {
                python.Unavailable("kernel reattach failed: " <> crash)
              })
            case runtime_state.owner_alive(self) {
              True ->
                process.send(
                  self,
                  runtime_state.Reattached(id, generation, cached, outcome),
                )
              False -> {
                case outcome {
                  Ok(Some(session)) ->
                    kernels.drop_kernel(
                      "reattach for a stopped runtime",
                      session,
                    )
                  _ -> Nil
                }
              }
            }
            process.send(reply, Nil)
          })
        runtime_state.UpgradeKernel(id, generation, cached, previous, answer) ->
          process.spawn_unlinked(fn() {
            let outcome =
              protect.attempt(fn() {
                upgrade_value(owner, id, cached, previous)
              })
              |> result.flatten
            case runtime_state.owner_alive(self) {
              True ->
                process.send(
                  self,
                  runtime_state.UpgradedKernel(
                    id,
                    generation,
                    previous,
                    outcome,
                    answer,
                  ),
                )
              False -> {
                discard_upgrade(previous, outcome)
                answer(Error("runtime owner stopped during kernel upgrade"))
              }
            }
          })
        runtime_state.RecomposeSelected(
          id,
          generation,
          cwd,
          selected,
          demanded,
          persist,
          previous,
          reply,
        ) -> {
          let inventory = observation.composition_inventory(state)
          let retained = observation.retained_basis(state)
          process.spawn_unlinked(fn() {
            let outcome =
              protect.attempt(fn() {
                recompose_selected(
                  inventory,
                  retained,
                  id,
                  cwd,
                  selected,
                  demanded,
                  persist,
                  previous,
                )
              })
              |> result.flatten
            publish_reload(self, id, generation, previous, outcome, reply)
          })
        }
      }
      boot_next(state)
    }
    [] -> state
  }
}

fn discard_upgrade(
  previous: Option(runtime_state.Session),
  outcome: Result(runtime_state.KernelUpgrade, String),
) -> Nil {
  let session = case outcome {
    Ok(report) -> report.session
    Error(_) -> previous
  }
  case session {
    Some(session) ->
      kernels.drop_kernel("upgrade for a forgotten session", session)
    None -> Nil
  }
}

fn publish_reload(
  subject: Subject(runtime_state.Message),
  id: String,
  generation: Reference,
  previous: Option(runtime_state.Session),
  outcome: Result(
    #(runtime_state.Cached, Option(runtime_state.Session)),
    String,
  ),
  reply: Subject(Result(Option(runtime_state.Session), String)),
) -> Nil {
  case runtime_state.owner_alive(subject) {
    True ->
      process.send(
        subject,
        runtime_state.Reloaded(id, generation, previous, outcome, reply),
      )
    False -> {
      case outcome {
        Error(_) -> {
          case previous {
            Some(session) ->
              kernels.drop_kernel("reload for a stopped runtime", session)
            None -> Nil
          }
        }
        Ok(#(fresh, replacement)) -> {
          case replacement {
            Some(session) ->
              kernels.drop_kernel("reload for a stopped runtime", session)
            None -> Nil
          }
          extension.close(fresh.composition)
        }
      }
      process.send(reply, Error("runtime owner stopped during reload"))
    }
  }
}

/// Why the daemon will not run this extension at all, if it quarantined it.
fn quarantine(state: runtime_state.State, name: String) -> Option(String) {
  list.find(shared.read(state.installed).quarantined, fn(failure) {
    failure.name == name
  })
  |> option.from_result
  |> option.map(fn(failure) {
    "extension " <> name <> " is quarantined: " <> failure.reason
  })
}

/// The extension this change enables, if it enables one.
fn demanded(change: extension.Change) -> Option(String) {
  case change {
    extension.SetSession(name, True) | extension.SetGlobal(name, True) ->
      Some(name)
    _ -> None
  }
}

/// Reload one session's extension selection. The choice is persisted before
/// the live session is touched; a change that alters the running set opens a
/// replacement kernel alongside the old one first.
fn reload(
  state: runtime_state.State,
  id: String,
  cwd: String,
  change: extension.Change,
  reply: Subject(Result(Option(runtime_state.Session), String)),
) -> runtime_state.State {
  let installed = shared.read(state.installed)
  let proposed = case quarantine(state, extension.change_name(change)) {
    Some(error) -> Error(error)
    None ->
      extension.propose(
        state.work,
        installed.extensions,
        installed.default_enabled,
        id,
        change,
      )
  }
  let current = runtime_state.enabled(state.work, installed, id)
  // Extensions carry function fields, so the running set compares by name.
  let names = fn(selected: List(extension.Extension)) {
    list.map(selected, fn(extension) { extension.name })
  }
  let unchanged = case proposed, current {
    Ok(selected), Ok(running) -> names(selected) == names(running)
    _, _ -> False
  }
  let ledger = state.work
  let persist = fn(selected) {
    use previous <- result.try(current)
    extension.record_selected(
      ledger,
      id,
      change,
      previous,
      selected,
      installed.extensions,
    )
  }
  case proposed, unchanged {
    // Nothing this session runs changes: record the choice and keep the
    // live kernel, its namespace, and its prompt cache.
    Ok(selected), True -> {
      process.send(reply, persist(selected) |> result.replace(None))
      state
    }
    Error(error), _ -> {
      process.send(reply, Error(error))
      state
    }
    Ok(selected), False ->
      reopen(state, id, cwd, selected, demanded(change), persist, reply)
  }
}

/// The change alters the running set: the new composition and kernel are
/// prepared alongside the old one; only the loser's resources are released,
/// and only after the selection is persisted, so a rollback leaves the live
/// session untouched.
fn reopen(
  state: runtime_state.State,
  id: String,
  cwd: String,
  selected: List(extension.Extension),
  demanded: Option(String),
  persist: fn(List(extension.Extension)) -> Result(Nil, String),
  reply: Subject(Result(Option(runtime_state.Session), String)),
) -> runtime_state.State {
  let previous = dict.get(state.sessions, id) |> option.from_result
  let workspace =
    option.map(previous, fn(session) { session.cwd }) |> option.unwrap(cwd)
  let generation = reference.new()
  runtime_state.State(
    ..runtime_state.without_session(state, id),
    booting: dict.insert(
      state.booting,
      id,
      runtime_state.Booting(generation, []),
    ),
    waiting: list.append(state.waiting, [
      runtime_state.RecomposeSelected(
        id,
        generation,
        workspace,
        selected,
        demanded,
        persist,
        previous,
        reply,
      ),
    ]),
  )
}

fn recompose_selected(
  inventory: session_catalog.Inventory,
  retained: List(runtime_state.Desired),
  id: String,
  workspace: String,
  selected: List(extension.Extension),
  demanded: Option(String),
  persist: fn(List(extension.Extension)) -> Result(Nil, String),
  previous: Option(runtime_state.Session),
) -> Result(#(runtime_state.Cached, Option(runtime_state.Session)), String) {
  use recorded <- result.try(link.lookup(inventory.ledger, id))
  use cached <- result.try(preparation.build_cached(
    inventory,
    id,
    workspace,
    Some(selected),
    option.values([demanded]),
    retained,
  ))
  let staged =
    python.stage(
      inventory.ledger,
      id,
      workspace,
      kernels.kernel_routes(inventory.ledger, id, cached.composition),
      extension.python_modules(cached.composition),
    )
  case staged {
    Error(error) -> {
      extension.close(cached.composition)
      Error("could not prepare replacement: " <> string.inspect(error))
    }
    Ok(#(kernel, record)) -> {
      let replacement =
        kernels.session_over(
          inventory.ledger,
          id,
          cached,
          kernel,
          runtime_state.Fresh,
        )
      let published = {
        use observed <- result.try(
          python.observation(replacement.kernel)
          |> result.replace_error("replacement observation unavailable"),
        )
        use _ <- result.try(case observed.linked && observed.stale == None {
          True -> Ok(Nil)
          False -> Error("replacement is not current and attached")
        })
        use _ <- result.try(persist(selected))
        use _ <- result.try(link.ready(inventory.ledger, record))
        use _ <- result.try(case previous, recorded {
          Some(session), _ -> python.stop(session.kernel)
          None, Some(record) ->
            python.stop_recorded_instance(inventory.ledger, record)
          None, None -> Ok(Nil)
        })
        link.publish(inventory.ledger, record)
      }
      case published {
        Error(reason) -> {
          let cleanup = python.stop(replacement.kernel)
          extension.close(cached.composition)
          Error(case cleanup {
            Ok(_) -> reason
            Error(failure) ->
              reason <> "; replacement cleanup failed: " <> failure
          })
        }
        Ok(_) -> Ok(#(cached, Some(replacement)))
      }
    }
  }
}

fn start_desired_reload(
  state: runtime_state.State,
  id: String,
  cwd: String,
  reply: Subject(Result(Option(runtime_state.Session), String)),
) -> runtime_state.State {
  let generation = reference.new()
  let previous = dict.get(state.sessions, id) |> option.from_result
  let active_strategy =
    dict.get(state.compositions, id)
    |> option.from_result
    |> option.then(fn(cached) {
      extension.compaction(extension.extensions(cached.composition))
    })
    |> option.map(fn(strategy) { strategy.name })
  let inventory = observation.composition_inventory(state)
  let self = state.self
  let retained = observation.retained_basis(state)
  process.spawn_unlinked(fn() {
    let outcome =
      protect.attempt(fn() {
        use selected <- result.try(extension.enabled(
          inventory.ledger,
          inventory.installed,
          inventory.defaults,
          id,
        ))
        use _ <- result.try(
          case active_strategy, extension.compaction(selected) {
            Some(name), None ->
              Error("select another compaction strategy to replace " <> name)
            _, _ -> Ok(Nil)
          },
        )
        use fresh <- result.try(preparation.build_cached(
          inventory,
          id,
          cwd,
          Some(selected),
          list.map(selected, fn(item) { item.name }),
          retained,
        ))
        let rebound =
          protect.attempt(fn() {
            case previous {
              None -> Ok(None)
              Some(session) ->
                case python.alive(session.kernel) {
                  False -> Ok(None)
                  True ->
                    case
                      session.cwd == cwd
                      && extension.python_modules(session.composition)
                      == extension.python_modules(fresh.composition)
                    {
                      True ->
                        python.rebind(
                          session.kernel,
                          kernels.kernel_routes(
                            inventory.ledger,
                            id,
                            fresh.composition,
                          ),
                        )
                        |> result.map(fn(_) {
                          Some(kernels.session_over(
                            inventory.ledger,
                            id,
                            fresh,
                            session.kernel,
                            runtime_state.Kept,
                          ))
                        })
                      False -> {
                        python.mark_stale(session.kernel, python.Modules)
                        case runtime_state.upgradable(session) {
                          False -> Error(python.Busy)
                          True ->
                            python.upgrade(
                              inventory.ledger,
                              id,
                              cwd,
                              kernels.kernel_routes(
                                inventory.ledger,
                                id,
                                fresh.composition,
                              ),
                              extension.python_modules(fresh.composition),
                              session.kernel,
                            )
                            |> result.map_error(fn(failure) { failure.reason })
                            |> result.map(fn(upgraded) {
                              Some(kernels.session_over(
                                inventory.ledger,
                                id,
                                fresh,
                                upgraded.0,
                                runtime_state.Upgraded(upgraded.1),
                              ))
                            })
                        }
                      }
                    }
                }
            }
          })
          |> result.map_error(fn(crash) { python.Unavailable(crash) })
          |> result.flatten
        case rebound {
          Ok(session) -> Ok(#(fresh, session))
          Error(error) -> {
            extension.close(fresh.composition)
            Error("could not reload extensions: " <> string.inspect(error))
          }
        }
      })
      |> result.map_error(fn(crash) { "could not reload extensions: " <> crash })
      |> result.flatten
    publish_reload(self, id, generation, previous, outcome, reply)
  })
  runtime_state.State(
    ..runtime_state.without_session(state, id),
    booting: dict.insert(
      state.booting,
      id,
      runtime_state.Booting(generation, []),
    ),
  )
}

fn reloaded(
  state: runtime_state.State,
  id: String,
  generation: Reference,
  previous: Option(runtime_state.Session),
  outcome: Result(
    #(runtime_state.Cached, Option(runtime_state.Session)),
    String,
  ),
  reply: Subject(Result(Option(runtime_state.Session), String)),
) -> runtime_state.State {
  let waiting = case dict.get(state.booting, id) {
    Ok(runtime_state.Booting(current, waiters)) if current == generation ->
      Ok(waiters)
    _ -> Error(Nil)
  }
  case waiting {
    Error(_) -> {
      case outcome {
        Error(_) ->
          case previous {
            Some(session) ->
              kernels.drop_kernel(
                "failed reload for a forgotten session",
                session,
              )
            None -> Nil
          }
        Ok(#(fresh, replacement)) -> {
          case replacement {
            Some(session) ->
              kernels.drop_kernel("reload for a forgotten session", session)
            None -> Nil
          }
          extension.close(fresh.composition)
        }
      }
      process.send(reply, Error("the session closed during reload"))
      state
    }
    Ok(waiters) ->
      case outcome {
        Error(reason) -> {
          let state = case previous {
            Some(session) -> runtime_state.holding(state, id, session)
            None -> state
          }
          list.each(list.reverse(waiters), fn(answer) {
            answer(Error(python.Invalid(reason)))
          })
          let state =
            preparation.finish_commands(
              state,
              id,
              dict.get(state.compositions, id) |> result.replace_error(reason),
            )
          process.send(reply, Error(reason))
          runtime_state.State(..state, booting: dict.delete(state.booting, id))
          |> runtime_state.replay(id)
        }
        Ok(#(fresh, replacement)) -> {
          kernels.close_cached_at(state, id)
          // The reload's own discovery supersedes any retained observation.
          let state =
            runtime_state.State(
              ..state,
              compositions: dict.insert(state.compositions, id, fresh),
              desired: dict.delete(state.desired, id),
            )
            |> preparation.finish_commands(id, Ok(fresh))
          process.send(reply, Ok(replacement))
          case replacement, waiters {
            Some(session), _ ->
              preparation.booted(state, id, generation, Ok(session))
            None, [] ->
              runtime_state.State(
                ..state,
                booting: dict.delete(state.booting, id),
              )
              |> runtime_state.replay(id)
            None, _ ->
              runtime_state.State(
                ..state,
                waiting: list.append(state.waiting, [
                  runtime_state.BootKernel(id, generation, fresh),
                ]),
              )
          }
        }
      }
  }
}

fn handle(
  state: runtime_state.State,
  message: runtime_state.Message,
) -> actor.Next(runtime_state.State, a) {
  case settling(state, message) {
    Some(id) -> actor.continue(runtime_state.defer(state, id, message))
    None -> serve(state, message)
  }
}

/// The session a composition change targets while its kernel is booting,
/// attaching, or being swapped: the change waits for it (see `deferred`).
fn settling(
  state: runtime_state.State,
  message: runtime_state.Message,
) -> Option(String) {
  case message {
    runtime_state.Reload(id, ..) | runtime_state.ReloadDesired(id, ..) ->
      case dict.has_key(state.booting, id) {
        True -> Some(id)
        False -> None
      }
    _ -> None
  }
}

fn serve(
  state: runtime_state.State,
  message: runtime_state.Message,
) -> actor.Next(runtime_state.State, a) {
  case message {
    runtime_state.Open(id, cwd, answer) ->
      case dict.get(state.sessions, id), dict.get(state.booting, id) {
        Ok(session), _ ->
          case session.cwd == cwd, python.alive(session.kernel) {
            False, _ -> {
              answer(
                Error(python.Invalid(
                  "session workspace differs; reset explicitly to change it",
                )),
              )
              actor.continue(state)
            }
            _, False -> {
              answer(Error(python.Lost))
              actor.continue(state)
            }
            True, True ->
              case runtime_state.upgradable(session) {
                True ->
                  actor.continue(start_upgrade(state, id, session, answer))
                False -> {
                  answer(Ok(session))
                  actor.continue(runtime_state.holding(
                    state,
                    id,
                    runtime_state.handed_out(session),
                  ))
                }
              }
          }
        // Already on its way: wait with everyone else.
        Error(_), Ok(runtime_state.Booting(generation, waiters)) ->
          actor.continue(
            runtime_state.State(
              ..state,
              booting: dict.insert(
                state.booting,
                id,
                runtime_state.Booting(generation, [answer, ..waiters]),
              ),
            ),
          )
        Error(_), Error(_) -> {
          let generation = reference.new()
          let state =
            runtime_state.State(
              ..state,
              booting: dict.insert(
                state.booting,
                id,
                runtime_state.Booting(generation, [answer]),
              ),
            )
          let state = case dict.get(state.compositions, id) {
            Ok(cached) if cached.cwd == cwd ->
              runtime_state.State(
                ..state,
                waiting: list.append(state.waiting, [
                  runtime_state.BootKernel(id, generation, cached),
                ]),
              )
            _ ->
              preparation.prepare(
                state,
                id,
                cwd,
                generation,
                runtime_state.CommandsOrOpen,
              )
          }
          actor.continue(boot_next(state))
        }
      }
    runtime_state.Composed(id, generation, prepared) ->
      actor.continue(
        preparation.composed(state, id, generation, prepared) |> boot_next,
      )
    runtime_state.Booted(id, generation, result) ->
      actor.continue(
        preparation.booted(state, id, generation, result) |> boot_next,
      )
    runtime_state.Upgrade(id, answer) ->
      actor.continue(start_kernel_upgrade(state, id, answer) |> boot_next)
    runtime_state.UpgradedKernel(id, generation, previous, outcome, answer) ->
      actor.continue(
        kernel_upgraded(state, id, generation, previous, outcome, answer)
        |> boot_next,
      )
    runtime_state.Reload(id, cwd, change, reply) ->
      actor.continue(reload(state, id, cwd, change, reply) |> boot_next)
    runtime_state.ReloadDesired(id, cwd, reply) ->
      actor.continue(start_desired_reload(state, id, cwd, reply))
    runtime_state.Reloaded(id, generation, previous, outcome, reply) ->
      actor.continue(
        reloaded(state, id, generation, previous, outcome, reply) |> boot_next,
      )
    runtime_state.ObserveComposition(home, id, reply) ->
      actor.continue(
        runtime_state.State(
          ..state,
          waiting: list.append(state.waiting, [
            runtime_state.Observe(
              id,
              home,
              runtime_state.CompositionReply(reply),
              2,
            ),
          ]),
        )
        |> boot_next,
      )
    runtime_state.ObserveCatalog(home, id, reply) ->
      actor.continue(
        runtime_state.State(
          ..state,
          waiting: list.append(state.waiting, [
            runtime_state.Observe(
              id,
              home,
              runtime_state.CatalogReply(reply),
              2,
            ),
          ]),
        )
        |> boot_next,
      )
    runtime_state.Observed(
      id,
      home,
      retries,
      captured,
      discovered,
      reply,
      observed,
    ) -> {
      let failure = case
        dict.get(state.compositions, id) |> option.from_result
      {
        current if current != captured ->
          Some("loaded composition changed during observation")
        _ ->
          case discovered {
            Error(reason) -> Some(reason)
            Ok(_) -> None
          }
      }
      let state = runtime_state.State(..state, observing: state.observing - 1)
      // An ordinary reload may settle between capture and completion. Retry
      // fresh work through admission; never publish the superseded result.
      let stale = case failure {
        Some("loaded composition changed during observation")
        | Some("composition inputs changed during discovery")
        | Some("composition inputs changed during observation") -> True
        _ -> False
      }
      case stale && retries > 0 {
        True ->
          actor.continue(
            runtime_state.State(
              ..state,
              waiting: list.append(state.waiting, [
                runtime_state.Observe(id, home, reply, retries - 1),
              ]),
            )
            |> boot_next,
          )
        False -> {
          let state = case failure, discovered {
            None, Ok(value) ->
              runtime_state.State(
                ..state,
                desired: dict.insert(state.desired, id, value),
              )
            _, _ -> state
          }
          case reply, observed {
            runtime_state.CompositionReply(reply),
              runtime_state.CompositionResult(value)
            ->
              process.send(reply, case failure {
                Some(reason) -> Error(reason)
                None -> value
              })
            runtime_state.CatalogReply(reply),
              runtime_state.CatalogResult(value)
            ->
              process.send(reply, case failure {
                Some("loaded composition changed during observation") ->
                  Error("loaded composition changed during observation")
                Some("session not found") -> Error("session not found")
                // A desired-read failure must retain available loaded commands.
                Some(reason) ->
                  case value {
                    Ok(value) ->
                      Ok(
                        runtime_state.CatalogObservation(
                          ..value,
                          discovery: Error(reason),
                        ),
                      )
                    Error(_) -> Error(reason)
                  }
                None -> value
              })
            _, _ -> Nil
          }
          actor.continue(boot_next(state))
        }
      }
    }
    runtime_state.ObserveLoaded(id, reply) -> {
      let observed = {
        let revision =
          dict.get(state.compositions, id)
          |> option.from_result
          |> option.then(fn(cached) { cached.loaded_revision })
        use #(kernel, lost) <- result.try(case dict.get(state.sessions, id) {
          Error(_) -> Ok(#(None, False))
          Ok(current) ->
            case python.observation(current.kernel) {
              Ok(observed) -> Ok(#(Some(observed), False))
              Error(_) ->
                case python.alive(current.kernel) {
                  False -> Ok(#(None, True))
                  True -> Error("loaded kernel observation is unavailable")
                }
            }
        })
        use recorded <- result.try(case kernel {
          Some(_) -> Ok(None)
          None -> link.lookup(state.work, id)
        })
        let phase = case
          dict.has_key(state.booting, id),
          kernel,
          lost,
          recorded
        {
          True, _, _, _ -> "booting"
          False, Some(observed), _, _ ->
            case observed.linked {
              True -> "attached"
              False -> "reattaching"
            }
          False, None, True, _ -> "lost"
          False, None, False, Some(_) -> "lost"
          False, None, False, None -> "none"
        }
        Ok(runtime_state.LoadedObservation(
          revision,
          kernel,
          phase,
          option.map(recorded, fn(record) { record.kernel }),
        ))
      }
      process.send(reply, observed)
      actor.continue(state)
    }
    runtime_state.LoadedIDs(reply) -> {
      process.send(reply, dict.keys(state.compositions))
      actor.continue(state)
    }
    runtime_state.HeldKernels(reply) -> {
      process.send(reply, dict.to_list(state.sessions))
      actor.continue(state)
    }
    runtime_state.PeekPrompt(id, reply) -> {
      process.send(
        reply,
        dict.get(state.compositions, id)
          |> result.map(fn(cached) {
            Some(#(cached.instructions, cached.context))
          })
          |> result.unwrap(None),
      )
      actor.continue(state)
    }
    runtime_state.Summaries(id, reply) -> {
      let installed = shared.read(state.installed)
      let composition = case
        dict.get(state.sessions, id),
        dict.get(state.compositions, id)
      {
        Ok(session), _ -> Some(session.composition)
        _, Ok(cached) -> Some(cached.composition)
        _, _ -> None
      }
      process.send(
        reply,
        extension.summaries(
          state.work,
          installed.extensions,
          installed.quarantined,
          installed.default_enabled,
          id,
          composition,
        ),
      )
      actor.continue(state)
    }
    runtime_state.Peek(id, cwd, reply) ->
      actor.continue(preparation.peek(state, id, cwd, reply) |> boot_next)
    runtime_state.Reset(id, reply) -> {
      kernels.drop_kernel_at(state, id, "session reset")
      process.send(reply, Nil)
      actor.continue(runtime_state.without_session(
        preparation.abandon(state, id),
        id,
      ))
    }
    runtime_state.Forget(id, reply) -> {
      let state = preparation.abandon(state, id)
      kernels.release_kernel(state, id, "session forgotten")
      kernels.close_cached_at(state, id)
      process.send(reply, Nil)
      actor.continue(
        runtime_state.State(
          ..runtime_state.without_session(state, id),
          compositions: dict.delete(state.compositions, id),
          desired: dict.delete(state.desired, id),
        ),
      )
    }
    runtime_state.Delete(id, reply) -> {
      let stopped = case dict.has_key(state.booting, id) {
        True -> Error("runtime preparation is still in progress")
        False ->
          case dict.get(state.sessions, id) {
            Ok(session) ->
              case python.alive(session.kernel) {
                True -> python.stop(session.kernel)
                False -> python.stop_recorded(state.work, id)
              }
            Error(_) -> python.stop_recorded(state.work, id)
          }
      }
      case stopped {
        Error(reason) -> {
          process.send(reply, Error(reason))
          actor.continue(state)
        }
        Ok(_) -> {
          kernels.close_cached_at(state, id)
          process.send(reply, Ok(Nil))
          actor.continue(
            runtime_state.State(
              ..runtime_state.without_session(state, id),
              compositions: dict.delete(state.compositions, id),
              desired: dict.delete(state.desired, id),
            ),
          )
        }
      }
    }
    runtime_state.Stop(reply) -> {
      let state =
        list.fold(dict.keys(state.booting), state, fn(state, id) {
          preparation.abandon(state, id)
        })
      dict.each(state.sessions, fn(id, _) {
        kernels.release_kernel(state, id, "runtime stop")
      })
      dict.each(state.compositions, fn(_, cached) {
        extension.close(cached.composition)
      })
      work.close(state.work)
      process.send(reply, Nil)
      actor.stop()
    }
    runtime_state.Detach(reply) -> {
      process.send(reply, Nil)
      actor.continue(runtime_state.State(..state, detaching: True))
    }
    runtime_state.Reattach(id, cwd, reply) ->
      actor.continue(reattach(state, id, cwd, reply) |> boot_next)
    runtime_state.Reattached(id, generation, cached, result) ->
      actor.continue(
        reattached(state, id, generation, cached, result) |> boot_next,
      )
  }
}

/// Start attaching to a session's recorded kernel, unless the session already
/// has its kernel or is getting one. It takes a boot slot while it runs.
fn reattach(
  state: runtime_state.State,
  id: String,
  cwd: String,
  reply: Subject(Nil),
) -> runtime_state.State {
  case dict.has_key(state.preparing, id) {
    True ->
      runtime_state.defer(state, id, runtime_state.Reattach(id, cwd, reply))
    False -> reattach_prepared(state, id, cwd, reply)
  }
}

fn reattach_prepared(
  state: runtime_state.State,
  id: String,
  cwd: String,
  reply: Subject(Nil),
) -> runtime_state.State {
  let busy =
    dict.has_key(state.sessions, id)
    || dict.has_key(state.booting, id)
    || state.detaching
  case busy {
    True -> {
      process.send(reply, Nil)
      state
    }
    False -> {
      let generation = reference.new()
      let state =
        runtime_state.State(
          ..state,
          booting: dict.insert(
            state.booting,
            id,
            runtime_state.Booting(generation, []),
          ),
        )
      case dict.get(state.compositions, id) {
        Ok(cached) if cached.cwd == cwd ->
          runtime_state.State(
            ..state,
            waiting: list.append(state.waiting, [
              runtime_state.AttachKernel(id, generation, cached, reply),
            ]),
          )
        _ ->
          preparation.prepare(
            state,
            id,
            cwd,
            generation,
            runtime_state.AttachRecorded(reply),
          )
      }
    }
  }
}

/// An attach finished. Whoever asked for the kernel meanwhile gets it; when
/// there was nothing to attach to, they get a fresh boot instead.
fn reattached(
  state: runtime_state.State,
  id: String,
  generation: Reference,
  cached: runtime_state.Cached,
  outcome: Result(Option(runtime_state.Session), python.Error),
) -> runtime_state.State {
  case dict.get(state.booting, id) {
    Ok(runtime_state.Booting(current, waiters)) if current == generation -> {
      let state = preparation.finish_commands(state, id, Ok(cached))
      case outcome, waiters {
        Ok(Some(session)), _ ->
          preparation.booted(state, id, generation, Ok(session))
        _, [] ->
          runtime_state.State(..state, booting: dict.delete(state.booting, id))
          |> runtime_state.replay(id)
        _, _ ->
          runtime_state.State(
            ..state,
            waiting: list.append(state.waiting, [
              runtime_state.BootKernel(id, generation, cached),
            ]),
          )
      }
    }
    _ -> {
      case outcome {
        Ok(Some(session)) ->
          kernels.drop_kernel("reattach for a forgotten session", session)
        _ -> Nil
      }
      state
    }
  }
}

pub fn tools(session: runtime_state.Session) -> List(types.Tool) {
  extension.tools(session.composition)
  |> list.map(fn(tool) { tool.definition })
}

fn tool_call(
  runtime: runtime_state.Runtime,
  session: runtime_state.Session,
  call: types.ToolCall,
  images: types.ImageLimits,
) -> Result(#(extension.Tool, extension.Context), Nil) {
  extension.tools(session.composition)
  |> list.find(fn(tool) { tool.definition.name == call.name })
  |> result.map(fn(tool) {
    #(
      tool,
      extension.Context(
        runtime.work,
        session.id,
        session.kernel,
        call.id,
        session.cwd,
        images,
      ),
    )
  })
}

/// Runs `call`; `images` are what the provider its result goes to accepts.
pub fn invoke(
  runtime: runtime_state.Runtime,
  session: runtime_state.Session,
  call: types.ToolCall,
  images: types.ImageLimits,
) -> Result(types.Input, String) {
  use _ <- result.try(owned_by(runtime, session))
  case tool_call(runtime, session, call, images) {
    Error(_) -> Ok(refusal(call, "tool is not installed"))
    Ok(#(tool, context)) ->
      case extension.invoke(tool, context, call.arguments) {
        Ok(output) -> Ok(types.ToolOutput(call.id, output.text, output.images))
        // A refusal is this call's answer; only `Fatal` ends the turn.
        Error(extension.Refused(message)) -> Ok(refusal(call, message))
        Error(extension.Fatal(message)) -> Error(message)
      }
  }
}

/// One refused call's answer, in the JSON shape tools report errors in.
fn refusal(call: types.ToolCall, message: String) -> types.Input {
  types.ToolOutput(
    call.id,
    json.to_string(json.object([#("error", json.string(message))])),
    [],
  )
}

pub fn recover(
  runtime: runtime_state.Runtime,
  session: runtime_state.Session,
  call: types.ToolCall,
  images: types.ImageLimits,
) -> types.Input {
  let saved = case tool_call(runtime, session, call, images) {
    Ok(#(tool, context)) -> extension.recover(tool, context)
    Error(_) -> None
  }
  case saved {
    Some(output) -> types.ToolOutput(call.id, output.text, output.images)
    None ->
      types.ToolOutput(
        call.id,
        "execution interrupted; outcome unknown. Inspect effects before any retry.",
        [],
      )
  }
}

pub fn instructions(session: runtime_state.Session) -> String {
  session.instructions
}

/// Tells every extension this session composed about one of its events.
pub fn observe(
  session: runtime_state.Session,
  handle: extension.Session,
  event: extension.SessionEvent,
) -> Nil {
  list.each(extension.observers(session.composition), fn(observe) {
    observe(handle, event)
  })
}

pub fn compaction_name(session: runtime_state.Session) -> Option(String) {
  extension.compaction(extension.extensions(session.composition))
  |> option.map(fn(strategy) { strategy.name })
}

/// Compaction sees only durable conversation. Extension context belongs to the
/// system instructions, not the request history or durable transcript.
pub fn prepare_history_with(
  runtime: runtime_state.Runtime,
  session: runtime_state.Session,
  model: String,
  instructions: String,
  summarize: fn(compaction.SummaryRequest) -> Result(String, String),
  history: List(types.Input),
) -> Result(List(types.Input), String) {
  prepare_view_scoped(
    runtime,
    session,
    model,
    model,
    None,
    instructions,
    summarize,
    history,
    False,
    types.any_images,
  )
  |> result.map(fn(prepared) { prepared.inputs })
}

/// Only a catalog answer becomes a capacity; an unknown model stays unknown.
fn model_info(
  session: runtime_state.Session,
  model: String,
  endpoint: Option(String),
) -> Option(extension.ModelInfo) {
  extension.model_info(
    extension.extensions(session.composition),
    model,
    endpoint,
  )
}

/// The extensions enabled with no session override: what services run with.
pub fn global(
  runtime: runtime_state.Runtime,
) -> Result(List(extension.Extension), String) {
  runtime_state.enabled(runtime.work, shared.read(runtime.installed), "")
}

/// Immutable declarations are safe to inspect under a settings owner lock;
/// they do not call the composition actor or read mutable configuration.
pub fn installed(runtime: runtime_state.Runtime) -> List(extension.Extension) {
  shared.read(runtime.installed).extensions
}

pub fn quarantined(
  runtime: runtime_state.Runtime,
) -> List(extension.Quarantined) {
  shared.read(runtime.installed).quarantined
}

pub fn base_defaults(runtime: runtime_state.Runtime) -> List(String) {
  shared.read(runtime.installed).default_enabled
}

/// Refetch the model catalogs this session enables, on the caller's process.
pub fn reload_catalogs(
  runtime: runtime_state.Runtime,
  id: String,
) -> Result(List(#(String, Result(Nil, String))), String) {
  runtime_state.enabled(runtime.work, shared.read(runtime.installed), id)
  |> result.map(extension.reload_catalogs)
}

pub fn logins(runtime: runtime_state.Runtime) -> List(oauth.Login) {
  extension.logins(installed(runtime))
}

pub fn model_names(
  runtime: runtime_state.Runtime,
  provider: String,
  endpoint: Option(String),
) -> List(String) {
  extension.provider_model_names(installed(runtime), provider, endpoint)
}

/// One model a provider lists, with what the catalog knows about it.
pub type ListedModel {
  ListedModel(
    id: String,
    info: Option(extension.ModelInfo),
    efforts: List(String),
  )
}

pub fn listed_models(
  runtime: runtime_state.Runtime,
  provider: String,
  endpoint: Option(String),
) -> List(ListedModel) {
  let enabled = global(runtime) |> result.unwrap([])
  model_names(runtime, provider, endpoint)
  |> list.map(fn(id) {
    let info = extension.model_info(enabled, id, endpoint)
    let efforts =
      info
      |> option.map(fn(i) { i.efforts })
      |> option.unwrap([])
    ListedModel(id, info, efforts)
  })
}

/// The reasoning efforts the catalog publishes for a model at `endpoint`.
pub fn model_efforts(
  runtime: runtime_state.Runtime,
  model: String,
  endpoint: Option(String),
) -> List(String) {
  efforts_in(global(runtime) |> result.unwrap([]), model, endpoint)
}

fn efforts_in(
  enabled: List(extension.Extension),
  model: String,
  endpoint: Option(String),
) -> List(String) {
  extension.model_info(enabled, model, endpoint)
  |> option.map(fn(info) { info.efforts })
  |> option.unwrap([])
}

pub fn upstream(
  runtime: runtime_state.Runtime,
  session: String,
  home: String,
  profile: String,
  provider: String,
  model: String,
  protocol: types.Protocol,
  effort: Option(String),
) -> Result(extension.Upstream, String) {
  use edge <- result.try(case profile {
    "" -> Ok(None)
    _ ->
      configuration.named(home, profile)
      |> result.map(fn(profile) { profile.image_edge })
  })
  use selected <- result.try(runtime_state.enabled(
    runtime.work,
    shared.read(runtime.installed),
    session,
  ))
  use upstream <- result.map(extension.upstream(
    selected,
    extension.ModelContext(
      home,
      session,
      profile,
      provider,
      model,
      protocol,
      effort,
    ),
  ))
  case edge {
    None -> upstream
    Some(edge) ->
      extension.Upstream(
        ..upstream,
        images: types.ImageLimits(
          ..upstream.images,
          max_edge: int.min(edge, upstream.images.max_edge),
        ),
      )
  }
}

fn capacity(info: Option(extension.ModelInfo)) -> Option(compaction.Capacity) {
  use info <- option.then(info)
  use tokens <- option.map(extension.window(info))
  let source = case info.provider {
    "" -> info.source
    provider -> provider <> " " <> info.source
  }
  let source = case Some(tokens) == info.context_tokens {
    True -> source
    False -> source <> "; cap raised"
  }
  compaction.Capacity(tokens, source)
}

fn reader(info: Option(extension.ModelInfo)) -> Option(compaction.Reader) {
  option.map(info, fn(info) {
    compaction.Reader(info.provider, info.input_modalities)
  })
}

/// Run the active strategy now, independent of its automatic threshold.
pub fn compact_history_scoped(
  runtime: runtime_state.Runtime,
  session: runtime_state.Session,
  model: String,
  source: String,
  endpoint: Option(String),
  instructions: String,
  summarize: fn(compaction.SummaryRequest) -> Result(String, String),
  history: List(types.Input),
) -> Result(List(types.Input), String) {
  prepare_view_scoped(
    runtime,
    session,
    model,
    source,
    endpoint,
    instructions,
    summarize,
    history,
    True,
    types.any_images,
  )
  |> result.map(fn(prepared) { prepared.inputs })
}

/// Prepare one provider request and its strategy-neutral inspection facts.
pub fn prepare_view_scoped(
  runtime: runtime_state.Runtime,
  session: runtime_state.Session,
  model: String,
  source: String,
  endpoint: Option(String),
  instructions: String,
  summarize: fn(compaction.SummaryRequest) -> Result(String, String),
  history: List(types.Input),
  force: Bool,
  images: types.ImageLimits,
) -> Result(compaction.Prepared, String) {
  view_scoped(
    runtime,
    session,
    model,
    source,
    endpoint,
    instructions,
    summarize,
    history,
    force,
    images,
    compaction.prepare,
  )
}

/// The request the active strategy's saved state makes of `history`, the
/// way `prepare_view_scoped` would send it, except that it never compacts:
/// it writes nothing and calls no model.
pub fn project_view_scoped(
  runtime: runtime_state.Runtime,
  session: runtime_state.Session,
  model: String,
  source: String,
  endpoint: Option(String),
  instructions: String,
  history: List(types.Input),
  images: types.ImageLimits,
) -> Result(compaction.Prepared, String) {
  view_scoped(
    runtime,
    session,
    model,
    source,
    endpoint,
    instructions,
    fn(_) { Error("a projection never summarizes") },
    history,
    False,
    images,
    compaction.project,
  )
}

fn view_scoped(
  runtime: runtime_state.Runtime,
  session: runtime_state.Session,
  model: String,
  source: String,
  endpoint: Option(String),
  instructions: String,
  summarize: fn(compaction.SummaryRequest) -> Result(String, String),
  history: List(types.Input),
  force: Bool,
  images: types.ImageLimits,
  view: fn(compaction.Strategy, compaction.Context, List(types.Input)) ->
    Result(compaction.Prepared, String),
) -> Result(compaction.Prepared, String) {
  use _ <- result.try(owned_by(runtime, session))
  let pinned_tokens = compaction.estimate_pinned(instructions, tools(session))
  let enabled = extension.extensions(session.composition)
  let info = model_info(session, model, endpoint)
  case extension.compaction(enabled) {
    None if force -> Error("no compaction strategy is enabled")
    None -> Ok(compaction.Prepared(history, None, False))
    Some(strategy) -> {
      let context =
        compaction.Context(
          runtime.work,
          session.id,
          session.kernel,
          model,
          source,
          pinned_tokens,
          capacity(info),
          force,
          summarize,
          compaction.compose_prior(
            list.filter(extension.folds(enabled), fn(folds) {
              folds.owner != strategy.name
            }),
            runtime.work,
            session.id,
          ),
          reader(info),
          images,
        )
      // A strategy that raises fails the turn the way one returning an error
      // does, naming itself, rather than killing the turn's process.
      protect.guarded(fn() {
        use prepared <- result.try(view(strategy, context, history))
        list.try_fold(extension.notes(enabled), prepared, fn(prepared, layer) {
          case prepared.compacted {
            True -> layer.compact(context, history, prepared)
            False -> layer.project(context, history, prepared)
          }
        })
      })
      |> result.map_error(fn(error) {
        "compaction " <> strategy.name <> ": " <> error
      })
    }
  }
}

pub fn inventory(host: runtime_state.Runtime) -> session_catalog.Inventory {
  session_catalog.Inventory(
    ledger(host),
    installed(host),
    quarantined(host),
    base_defaults(host),
  )
}

/// Loaded sessions whose composition is behind their desired one. They are
/// observed a few at a time: observation runs on the owner's worker slots, so
/// a wider window would only queue calls until their timeouts ran out.
pub fn needs_reload(
  host: runtime_state.Runtime,
  home: String,
) -> Result(List(String), String) {
  loaded_sessions(host)
  |> list.sized_chunk(runtime_state.boot_slots - 1)
  |> list.try_fold([], fn(ids, window) {
    use observed <- result.try(observe_window(host, home, window))
    Ok(list.append(observed, ids))
  })
}

/// The ids in `window` that need a reload, observed concurrently.
fn observe_window(
  host: runtime_state.Runtime,
  home: String,
  window: List(String),
) -> Result(List(String), String) {
  let answers = process.new_subject()
  list.each(window, fn(id) {
    process.spawn_unlinked(fn() {
      process.send(answers, #(id, observe_composition(host, home, id)))
    })
  })
  list.try_fold(window, [], fn(ids, _) {
    case process.receive(answers, runtime_state.observe_timeout_ms) {
      Error(Nil) -> Error("runtime composition observation is unavailable")
      Ok(#(_, Error("session not found"))) -> Ok(ids)
      Ok(#(_, Error(reason))) -> Error(reason)
      Ok(#(id, Ok(observed))) ->
        Ok(case observed.needs_reload {
          True -> [id, ..ids]
          False -> ids
        })
    }
  })
}
