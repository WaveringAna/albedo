//// Swapping a session's stale kernel for a current one: queued for the
//// scheduler like a boot, carrying what the old namespace could, and settled
//// when the worker reports which kernel the session ends up with.

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

/// Queue the swap of a stale kernel for a current one, like a boot: whoever
/// opens the session meanwhile waits for it. A swap that cannot happen now
/// (a cell still running, a namespace that would not save) hands the old
/// kernel back, still stale, to try again at the next open.
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
      let generation = reference.new()
      let state =
        runtime_state.without_session(state, id)
        |> runtime_state.admit(id, generation, [answer])
      runtime_state.State(
        ..state,
        waiting: list.append(state.waiting, [
          runtime_state.SwapStale(id, generation, cached, session),
        ]),
      )
    }
  }
}

/// The swap itself, run by a scheduler worker: the session over its new
/// kernel, or over the old one when the swap must wait and it still lives.
pub fn swap_stale(
  owner: work.Store,
  id: String,
  cached: runtime_state.Cached,
  session: runtime_state.Session,
) -> Result(runtime_state.Session, python.Error) {
  case
    protect.attempt(fn() { kernels.upgrade(owner, id, cached, session.kernel) })
  {
    Ok(Ok(#(session, _))) -> Ok(session)
    Ok(Error(error)) -> {
      io.println_error("kernel upgrade waits: " <> string.inspect(error.reason))
      kept_unless_gone(session, error.reason)
    }
    Error(crash) -> {
      io.println_error("kernel upgrade failed: " <> crash)
      kept_unless_gone(session, python.Unavailable(crash))
    }
  }
}

/// The old kernel, still stale, when it survived the failed swap.
fn kept_unless_gone(
  session: runtime_state.Session,
  error: python.Error,
) -> Result(runtime_state.Session, python.Error) {
  case python.alive(session.kernel) {
    True -> Ok(runtime_state.Session(..session, origin: runtime_state.Kept))
    False -> Error(error)
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
              state: "unchanged",
              old: None,
              new: None,
              session: None,
              stopped_jobs: [],
              warnings: [],
              failure: None,
            )),
          )
          state
        }
        Ok(Some(#(cwd, cached))) -> {
          let generation = reference.new()
          let state =
            runtime_state.without_session(state, id)
            |> runtime_state.admit(id, generation, [])
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
        state: "failed",
        old: None,
        new: None,
        session: Some(current),
        stopped_jobs: [],
        warnings: [],
        failure: Some("the live kernel did not answer observation"),
      ))
    Ok(old) ->
      case old.stale {
        None ->
          Ok(runtime_state.KernelUpgrade(
            state: "unchanged",
            old: Some(old),
            new: Some(old),
            session: Some(current),
            stopped_jobs: [],
            warnings: [],
            failure: None,
          ))
        Some(_) -> {
          let outcome = kernels.upgrade(owner, id, cached, current.kernel)
          let #(session, failure, restored_warnings, stopped) = case outcome {
            Ok(#(session, carried)) -> #(
              Some(session),
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
              state: case failure, observed {
                None, Some(_) -> "upgraded"
                _, _ -> "failed"
              },
              old: Some(old),
              new: observed,
              session: session,
              stopped_jobs: stopped,
              warnings: warnings,
              failure: case failure, observed {
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
  case runtime_state.current_waiters(state, id, generation) {
    Error(Nil) -> {
      discard_upgrade(previous, outcome)
      answer(Error("the session closed during kernel upgrade"))
      state
    }
    Ok(waiters) -> {
      let current = case outcome {
        Ok(report) -> report.session
        Error(_) -> previous
      }
      let state = case current {
        Some(session) ->
          runtime_state.holding(state, id, runtime_state.handed_out(session))
        None -> runtime_state.without_session(state, id)
      }
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
      runtime_state.generation_over(state, id)
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
