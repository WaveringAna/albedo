//// Reloading a session's extensions: a proposed change or a changed desired
//// selection is recomposed beside the running one, and the loser's kernel and
//// composition are released only once the new ones are in place.

import albedo/daemon/session_catalog
import albedo/harness/extension
import albedo/harness/extension/composition
import albedo/harness/extension/selection
import albedo/harness/extensions/python/kernel as python
import albedo/harness/extensions/python/link
import albedo/harness/protect
import albedo/harness/runtime/kernels
import albedo/harness/runtime/preparation
import albedo/harness/runtime/state as runtime_state
import albedo/shared
import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/erlang/reference.{type Reference}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// A recompose whose runtime stopped meanwhile: release whatever kernel the
/// session would have had and tell the caller.
pub fn orphaned(
  previous: Option(runtime_state.Session),
  outcome: Result(
    #(runtime_state.Cached, Option(runtime_state.Session)),
    String,
  ),
  reply: Subject(Result(Option(runtime_state.Session), String)),
) -> Nil {
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
      composition.close(fresh.composition)
    }
  }
  process.send(reply, Error("runtime owner stopped during reload"))
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
fn demanded(change: selection.Change) -> Option(String) {
  case change {
    selection.SetSession(name, True) | selection.SetGlobal(name, True) ->
      Some(name)
    _ -> None
  }
}

/// Reload one session's extension selection. The choice is persisted before
/// the live session is touched; a change that alters the running set opens a
/// replacement kernel alongside the old one first.
pub fn reload(
  state: runtime_state.State,
  id: String,
  cwd: String,
  change: selection.Change,
  reply: Subject(Result(Option(runtime_state.Session), String)),
) -> runtime_state.State {
  let installed = shared.read(state.installed)
  let proposed = case quarantine(state, selection.change_name(change)) {
    Some(error) -> Error(error)
    None ->
      selection.propose(
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
    selection.record_selected(
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
  let state =
    runtime_state.without_session(state, id)
    |> runtime_state.admit(id, generation, [])
  runtime_state.State(
    ..state,
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

pub fn recompose_selected(
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
  case kernels.stage(inventory.ledger, id, cached) {
    Error(error) -> {
      composition.close(cached.composition)
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
          composition.close(cached.composition)
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

pub fn start_desired_reload(
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
      extension.compaction(composition.extensions(cached.composition))
    })
    |> option.map(fn(strategy) { strategy.name })
  let state =
    runtime_state.without_session(state, id)
    |> runtime_state.admit(id, generation, [])
  runtime_state.State(
    ..state,
    waiting: list.append(state.waiting, [
      runtime_state.RecomposeDesired(
        id,
        generation,
        cwd,
        previous,
        active_strategy,
        reply,
      ),
    ]),
  )
}

/// Builds the composition the saved selection asks for and keeps, rebinds,
/// swaps, or drops the live kernel to match it; run by a scheduler worker.
pub fn recompose_desired(
  inventory: session_catalog.Inventory,
  retained: List(runtime_state.Desired),
  id: String,
  cwd: String,
  previous: Option(runtime_state.Session),
  active_strategy: Option(String),
) -> Result(#(runtime_state.Cached, Option(runtime_state.Session)), String) {
  use selected <- result.try(selection.enabled(
    inventory.ledger,
    inventory.installed,
    inventory.defaults,
    id,
  ))
  use _ <- result.try(case active_strategy, extension.compaction(selected) {
    Some(name), None ->
      Error("select another compaction strategy to replace " <> name)
    _, _ -> Ok(Nil)
  })
  use fresh <- result.try(preparation.build_cached(
    inventory,
    id,
    cwd,
    Some(selected),
    list.map(selected, fn(item) { item.name }),
    retained,
  ))
  let rebound =
    protect.attempt(fn() { rebound(inventory, id, cwd, previous, fresh) })
    |> result.map_error(fn(crash) { python.Unavailable(crash) })
    |> result.flatten
  case rebound {
    Ok(session) -> Ok(#(fresh, session))
    Error(error) -> {
      composition.close(fresh.composition)
      Error("could not reload extensions: " <> string.inspect(error))
    }
  }
}

/// The live kernel over the fresh composition: rebound when its modules are
/// unchanged, swapped when they changed and it can go, and `None` when there
/// is no live kernel, so the next open boots one.
fn rebound(
  inventory: session_catalog.Inventory,
  id: String,
  cwd: String,
  previous: Option(runtime_state.Session),
  fresh: runtime_state.Cached,
) -> Result(Option(runtime_state.Session), python.Error) {
  case previous {
    None -> Ok(None)
    Some(session) ->
      case python.alive(session.kernel) {
        False -> Ok(None)
        True ->
          case
            session.cwd == cwd
            && composition.python_modules(session.composition)
            == composition.python_modules(fresh.composition)
          {
            True ->
              python.rebind(
                session.kernel,
                kernels.kernel_routes(inventory.ledger, id, fresh.composition),
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
                  kernels.upgrade(inventory.ledger, id, fresh, session.kernel)
                  |> result.map_error(fn(failure) { failure.reason })
                  |> result.map(fn(upgraded) { Some(upgraded.0) })
              }
            }
          }
      }
  }
}

pub fn reloaded(
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
  case runtime_state.current_waiters(state, id, generation) {
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
          composition.close(fresh.composition)
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
          runtime_state.generation_over(state, id)
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
          preparation.settled(
            state,
            id,
            generation,
            fresh,
            replacement,
            waiters,
          )
        }
      }
  }
}
