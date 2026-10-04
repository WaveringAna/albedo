//// One bounded maintenance worker per registry. Session owners decide releases.

import albedo/actor_call
import albedo/daemon/active_output
import albedo/daemon/conversation
import albedo/daemon/pastes
import albedo/daemon/reaper
import albedo/daemon/session
import albedo/daemon/state_expiry
import albedo/daemon/store
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/result

pub type Sweep {
  Sweep(
    home: String,
    ledger: store.Store,
    workers: List(#(String, session.Session)),
    idle_ms: Int,
    unload_ms: Int,
    budget_kb: Int,
    detached_ms: Int,
    state_expiry_seconds: Int,
    expire_states: Bool,
    now_seconds: Int,
  )
}

pub fn run(sweep: Sweep) -> Nil {
  active_output.maintenance(sweep.home)
  let reports =
    list.filter_map(sweep.workers, fn(entry) {
      actor_call.try_call(entry.1, waiting: 5000, sending: session.Idle)
      |> result.map(fn(report) { #(entry.0, entry.1, report) })
    })
  release_idle(reports, sweep)
  unload_quiet(reports, sweep)
  case sweep.expire_states {
    True -> {
      expire(reports, sweep)
      prune_pastes(sweep)
    }
    False -> Nil
  }
}

/// Saved pastes expire on the same schedule as kernel state.
fn prune_pastes(sweep: Sweep) -> Nil {
  case pastes.prune(sweep.home, sweep.state_expiry_seconds) {
    0 -> Nil
    count ->
      io.println("paste expiry: deleted " <> int.to_string(count) <> " files")
  }
}

fn release_idle(
  reports: List(#(String, session.Session, session.Report)),
  sweep: Sweep,
) -> Nil {
  let held =
    list.filter_map(reports, fn(entry) {
      case entry.2.kernel {
        Some(pid) -> Ok(#(pid, entry.1, entry.2))
        None -> Error(Nil)
      }
    })
  let usage = rss(list.map(held, fn(entry) { entry.0 }))
  let candidates =
    list.map(held, fn(entry) {
      let #(pid, _, report) = entry
      reaper.Candidate(
        pid: pid,
        idle_ms: report.idle_ms,
        running: report.running,
        jobs: report.jobs,
        kilobytes: list.key_find(usage, pid) |> result.unwrap(0),
      )
    })
  let workers = list.map(held, fn(entry) { #(entry.0, entry.1) })
  reaper.victims(
    candidates,
    reaper.Limits(sweep.idle_ms, sweep.budget_kb, sweep.detached_ms),
  )
  |> list.each(fn(victim) {
    case list.key_find(workers, victim.pid) {
      Ok(worker) -> {
        let _ =
          actor_call.try_call(worker, waiting: 40_000, sending: session.Release)
        Nil
      }
      Error(_) -> Nil
    }
  })
  list.each(reports, fn(entry) {
    let report = entry.2
    case
      report.history_loaded
      && !report.running
      && report.idle_ms >= sweep.detached_ms
    {
      True -> {
        let _ =
          actor_call.try_call(
            entry.1,
            waiting: 5000,
            sending: session.EvictHistory,
          )
        Nil
      }
      False -> Nil
    }
  })
}

/// Stop sessions whose last turn is older than the unload limit: their
/// provider cache has expired, so nothing is lost by loading them again. The
/// session refuses while a client watches it or work is queued.
fn unload_quiet(
  reports: List(#(String, session.Session, session.Report)),
  sweep: Sweep,
) -> Nil {
  case conversation.activity(sweep.ledger) {
    Error(_) -> Nil
    Ok(activity) ->
      list.each(reports, fn(entry) {
        let #(id, worker, report) = entry
        let last = list.key_find(activity, id) |> result.unwrap(0)
        case
          !report.running
          && report.jobs == 0
          && sweep.now_seconds * 1000 - last >= sweep.unload_ms
        {
          True -> {
            let _ =
              actor_call.try_call(
                worker,
                waiting: 40_000,
                sending: session.Unload,
              )
            Nil
          }
          False -> Nil
        }
      })
  }
}

fn expire(
  reports: List(#(String, session.Session, session.Report)),
  sweep: Sweep,
) -> Nil {
  case conversation.list(sweep.ledger) {
    Error(_) -> Nil
    Ok(infos) -> {
      // Missing replies do not establish that a captured owner is idle. Keep
      // its state files until a later sweep can obtain a real observation.
      let active = fn(id) {
        case list.find(reports, fn(entry) { entry.0 == id }) {
          Ok(entry) -> entry.2.kernel != None || entry.2.running
          Error(_) -> list.any(sweep.workers, fn(entry) { entry.0 == id })
        }
      }
      let protected =
        infos
        |> list.filter(fn(info) { active(info.id) })
        |> list.map(fn(info) { info.id })
      let candidates =
        list.map(infos, fn(info) {
          state_expiry.Candidate(
            info.id,
            info.last_assistant_at,
            active(info.id),
            info.stage != conversation.Idle,
          )
        })
      let expired =
        state_expiry.expired(
          candidates,
          sweep.now_seconds,
          sweep.state_expiry_seconds,
        )
      reclaim(
        sweep.home,
        expired,
        protected,
        list.map(infos, fn(info) { info.id }),
      )
    }
  }
}

@external(erlang, "albedo_daemon", "rss")
fn rss(pids: List(Int)) -> List(#(Int, Int))

pub fn reclaim(
  home: String,
  expired: List(String),
  protected: List(String),
  known: List(String),
) -> Nil {
  let #(count, bytes) = reclaim_native(home, expired, protected, known)
  case count > 0 {
    True ->
      io.println(
        "python state expiry: reclaimed "
        <> int.to_string(count)
        <> " files ("
        <> int.to_string(bytes)
        <> " bytes)",
      )
    False -> Nil
  }
}

@external(erlang, "albedo_state_expiry", "reclaim")
fn reclaim_native(
  home: String,
  expired: List(String),
  protected: List(String),
  known: List(String),
) -> #(Int, Int)
