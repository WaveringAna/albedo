//// The runtime's scheduler: admits waiting preparations, boots, attaches,
//// upgrades, and observations into a bounded set of workers, and reattaches
//// recorded kernels after a daemon restart.

import albedo/daemon/session_catalog
import albedo/harness/extension
import albedo/harness/extensions/python/kernel as python
import albedo/harness/protect
import albedo/harness/runtime/kernels
import albedo/harness/runtime/observation
import albedo/harness/runtime/preparation
import albedo/harness/runtime/reload
import albedo/harness/runtime/state as runtime_state
import albedo/harness/runtime/upgrade
import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/erlang/reference.{type Reference}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

/// Admit the oldest eligible request, preserving order within each class.
/// Kernels belong to the store and outlive the workers that prepare them.
pub fn boot_next(state: runtime_state.State) -> runtime_state.State {
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
                upgrade.upgrade_value(owner, id, cached, previous)
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
                upgrade.discard_upgrade(previous, outcome)
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
                reload.recompose_selected(
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
            reload.publish_reload(
              self,
              id,
              generation,
              previous,
              outcome,
              reply,
            )
          })
        }
      }
      boot_next(state)
    }
    [] -> state
  }
}

/// Start attaching to a session's recorded kernel, unless the session already
/// has its kernel or is getting one. It takes a boot slot while it runs.
pub fn reattach(
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
      let state = runtime_state.admit(state, id, generation)
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
pub fn reattached(
  state: runtime_state.State,
  id: String,
  generation: Reference,
  cached: runtime_state.Cached,
  outcome: Result(Option(runtime_state.Session), python.Error),
) -> runtime_state.State {
  case runtime_state.current_waiters(state, id, generation) {
    Ok(waiters) -> {
      let state = preparation.finish_commands(state, id, Ok(cached))
      case outcome, waiters {
        Ok(Some(session)), _ ->
          preparation.booted(state, id, generation, Ok(session))
        _, [] -> runtime_state.generation_over(state, id)
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
