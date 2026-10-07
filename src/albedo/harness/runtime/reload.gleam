//// Apply saved extension choices beside the loaded composition. Kernel
//// shutdown is irreversible; every outcome reports the surviving handle.

import albedo/harness/extension
import albedo/harness/extension/composition
import albedo/harness/extension/selection
import albedo/harness/extensions/python/kernel as python
import albedo/harness/protect
import albedo/harness/runtime/catalog as session_catalog
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
  reply: Subject(runtime_state.Application),
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
  process.send(
    reply,
    runtime_state.ApplyFailed(None, "runtime owner stopped during reload"),
  )
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

/// Save the desired choice, then apply it through the same path as reload.
/// A failed application leaves the preference available for a later retry.
pub fn reload(
  state: runtime_state.State,
  id: String,
  cwd: String,
  change: selection.Change,
  reply: Subject(runtime_state.Application),
) -> runtime_state.State {
  let installed = shared.read(state.installed)
  let recorded = {
    use _ <- result.try(case quarantine(state, selection.change_name(change)) {
      Some(error) -> Error(error)
      None -> Ok(Nil)
    })
    use selected <- result.try(selection.propose(
      state.ledger,
      installed.extensions,
      installed.default_enabled,
      id,
      change,
    ))
    use previous <- result.try(selection.enabled(
      state.ledger,
      installed.extensions,
      installed.default_enabled,
      id,
    ))
    selection.record_selected(
      state.ledger,
      id,
      change,
      previous,
      selected,
      installed.extensions,
    )
  }
  case recorded {
    Error(reason) -> {
      process.send(
        reply,
        runtime_state.ApplyFailed(
          surviving(dict.get(state.sessions, id) |> option.from_result),
          reason,
        ),
      )
      state
    }
    Ok(_) -> start_desired_reload(state, id, cwd, reply)
  }
}

/// Never restore a handle after its kernel has stopped during replacement.
fn surviving(
  previous: Option(runtime_state.Session),
) -> Option(runtime_state.Session) {
  option.then(previous, fn(session) {
    case python.alive(session.kernel) {
      True -> Some(session)
      False -> None
    }
  })
}

pub fn start_desired_reload(
  state: runtime_state.State,
  id: String,
  cwd: String,
  reply: Subject(runtime_state.Application),
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
  reply: Subject(runtime_state.Application),
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
      process.send(
        reply,
        runtime_state.ApplyFailed(None, "the session closed during reload"),
      )
      state
    }
    Ok(waiters) ->
      case outcome {
        Error(reason) -> {
          let retained = surviving(previous)
          let state = case retained, previous {
            Some(session), _ -> runtime_state.holding(state, id, session)
            None, Some(_) -> {
              kernels.close_cached_at(state, id)
              runtime_state.State(
                ..state,
                compositions: dict.delete(state.compositions, id),
                desired: dict.delete(state.desired, id),
              )
            }
            None, None -> state
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
          process.send(reply, runtime_state.ApplyFailed(retained, reason))
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
          let carried_warnings = case replacement {
            Some(runtime_state.Session(
              origin: runtime_state.Upgraded(carried),
              ..,
            )) ->
              list.map(carried.saved.missed, fn(item) {
                item.0 <> ": " <> item.1
              })
            _ -> []
          }
          process.send(
            reply,
            runtime_state.Applied(
              replacement,
              fresh.loaded_revision,
              list.append(
                composition.warnings(fresh.composition),
                carried_warnings,
              ),
            ),
          )
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
