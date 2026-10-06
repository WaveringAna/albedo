//// The runtime's scheduler: admits waiting preparations, boots, attaches,
//// upgrades, and observations into a bounded set of workers, and reattaches
//// recorded kernels after a daemon restart.

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
      start(state, request)
      boot_next(state)
    }
    [] -> state
  }
}

/// Runs `compute` off the actor, then `deliver`s its value to the actor, or
/// hands it to `orphaned` when the runtime stopped meanwhile.
fn work(
  self: Subject(runtime_state.Message),
  compute: fn() -> a,
  deliver: fn(a) -> Nil,
  orphaned: fn(a) -> Nil,
) -> Nil {
  process.spawn_unlinked(fn() {
    let value = compute()
    case runtime_state.owner_alive(self) {
      True -> deliver(value)
      False -> orphaned(value)
    }
  })
  Nil
}

/// One admitted request's worker. Each captures what it needs from the
/// state here; none holds the state itself.
fn start(
  state: runtime_state.State,
  request: runtime_state.BootRequest,
) -> Nil {
  let self = state.self
  let owner = state.work
  let inventory = observation.composition_inventory(state)
  case request {
    runtime_state.Observe(id, home, reply, retries) -> {
      let retained = observation.bases_for(state, id)
      let cached = dict.get(state.compositions, id) |> option.from_result
      work(
        self,
        fn() {
          observation.observe(inventory, retained, cached, home, id, reply)
        },
        fn(read) {
          let #(discovered, observed) = read
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
        },
        fn(_) { Nil },
      )
    }
    runtime_state.Compose(id, cwd, generation) -> {
      let retained = observation.retained_basis(state)
      work(
        self,
        fn() {
          protect.attempt(fn() {
            preparation.build_cached(inventory, id, cwd, None, [], retained)
          })
          |> result.flatten
        },
        fn(prepared) {
          process.send(self, runtime_state.Composed(id, generation, prepared))
        },
        fn(prepared) {
          case prepared {
            Ok(cached) -> extension.close(cached.composition)
            Error(_) -> Nil
          }
        },
      )
    }
    runtime_state.BootKernel(id, generation, cached) ->
      work(
        self,
        fn() {
          case
            protect.attempt(fn() { kernels.open_kernel(owner, id, cached) })
          {
            Ok(result) -> result
            Error(crash) ->
              Error(python.Unavailable("kernel boot failed: " <> crash))
          }
        },
        fn(outcome) {
          process.send(self, runtime_state.Booted(id, generation, outcome))
        },
        drop_if_booted("boot for a stopped runtime"),
      )
    runtime_state.SwapStale(id, generation, cached, session) ->
      work(
        self,
        fn() { upgrade.swap_stale(owner, id, cached, session) },
        fn(outcome) {
          process.send(self, runtime_state.Booted(id, generation, outcome))
        },
        drop_if_booted("upgrade for a stopped runtime"),
      )
    runtime_state.AttachKernel(id, generation, cached, reply) ->
      work(
        self,
        fn() {
          protect.attempt(fn() { kernels.resume_kernel(owner, id, cached) })
          |> result.map_error(fn(crash) {
            python.Unavailable("kernel reattach failed: " <> crash)
          })
        },
        fn(outcome) {
          process.send(
            self,
            runtime_state.Reattached(id, generation, cached, outcome),
          )
          process.send(reply, Nil)
        },
        fn(outcome) {
          case outcome {
            Ok(Some(session)) ->
              kernels.drop_kernel("reattach for a stopped runtime", session)
            _ -> Nil
          }
          process.send(reply, Nil)
        },
      )
    runtime_state.UpgradeKernel(id, generation, cached, previous, answer) ->
      work(
        self,
        fn() {
          protect.attempt(fn() {
            upgrade.upgrade_value(owner, id, cached, previous)
          })
          |> result.flatten
        },
        fn(outcome) {
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
        },
        fn(outcome) {
          upgrade.discard_upgrade(previous, outcome)
          answer(Error("runtime owner stopped during kernel upgrade"))
        },
      )
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
      let retained = observation.retained_basis(state)
      work(
        self,
        fn() {
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
        },
        deliver_reload(self, id, generation, previous, reply),
        reload.orphaned(previous, _, reply),
      )
    }
    runtime_state.RecomposeDesired(
      id,
      generation,
      cwd,
      previous,
      active_strategy,
      reply,
    ) -> {
      let retained = observation.retained_basis(state)
      work(
        self,
        fn() {
          protect.attempt(fn() {
            reload.recompose_desired(
              inventory,
              retained,
              id,
              cwd,
              previous,
              active_strategy,
            )
          })
          |> result.map_error(fn(crash) {
            "could not reload extensions: " <> crash
          })
          |> result.flatten
        },
        deliver_reload(self, id, generation, previous, reply),
        reload.orphaned(previous, _, reply),
      )
    }
  }
}

fn deliver_reload(
  self: Subject(runtime_state.Message),
  id: String,
  generation: Reference,
  previous: Option(runtime_state.Session),
  reply: Subject(Result(Option(runtime_state.Session), String)),
) -> fn(Result(#(runtime_state.Cached, Option(runtime_state.Session)), String)) ->
  Nil {
  fn(outcome) {
    process.send(
      self,
      runtime_state.Reloaded(id, generation, previous, outcome, reply),
    )
  }
}

/// A kernel that booted for a runtime that stopped has no one to hold it.
fn drop_if_booted(
  context: String,
) -> fn(Result(runtime_state.Session, python.Error)) -> Nil {
  fn(outcome) {
    case outcome {
      Ok(session) -> kernels.drop_kernel(context, session)
      Error(_) -> Nil
    }
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
    Ok(waiters) ->
      preparation.finish_commands(state, id, Ok(cached))
      |> preparation.settled(
        id,
        generation,
        cached,
        option.from_result(outcome) |> option.flatten,
        waiters,
      )
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
