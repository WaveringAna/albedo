//// Swapping a session's stale kernel for a current one: started off the actor
//// like a boot, carrying what the old namespace could, and settled when the
//// worker reports which kernel the session ends up with.

import albedo/harness/extension
import albedo/harness/extensions/python/kernel as python
import albedo/harness/extensions/python/link
import albedo/harness/extensions/work/ledger as work
import albedo/harness/protect
import albedo/harness/runtime/kernels
import albedo/harness/runtime/preparation
import albedo/harness/runtime/state as runtime_state
import gleam/dict
import gleam/erlang/process
import gleam/erlang/reference.{type Reference}
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

// The HTTP caller can time out while the actual action remains in flight.
// Keep its one completion waiter until ownership settles or the owner dies.
pub fn await_upgrade(
  selector: process.Selector(Result(runtime_state.KernelUpgrade, String)),
) -> Result(runtime_state.KernelUpgrade, String) {
  case process.selector_receive(selector, 185_000) {
    Ok(outcome) -> outcome
    Error(_) -> await_upgrade(selector)
  }
}

/// Swap a stale kernel for a current one off the actor, the way a boot runs:
/// whoever opens the session meanwhile waits for it. A swap that cannot
/// happen now (a cell still running, a namespace that would not save) hands
/// the old kernel back, still stale, to try again at the next open.
pub fn start_upgrade(
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

pub fn start_kernel_upgrade(
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

pub fn upgrade_value(
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

pub fn kernel_upgraded(
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

pub fn discard_upgrade(
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
