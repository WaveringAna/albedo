//// Which idle kernels to release. Pure policy; the caller does the releasing.
////
//// A session that is attached, running, or holding live background jobs is
//// never a victim, though the memory it holds still counts against the pool:
//// the point is to reclaim what nobody is waiting on, not to bound how many
//// sessions a person may keep open. Live jobs pin the kernel because releasing
//// it kills the process groups those jobs still own and the wake they owe.

import gleam/int
import gleam/list

pub type Candidate {
  Candidate(pid: Int, idle_ms: Int, running: Bool, jobs: Int, kilobytes: Int)
}

pub type Limits {
  Limits(idle_ms: Int, budget_kb: Int, detached_ms: Int)
}

fn sum_kb(candidates: List(Candidate)) -> Int {
  list.fold(candidates, 0, fn(sum, one) { sum + one.kilobytes })
}

/// Kernels to release, in the order to release them: those idle past the limit,
/// then, while the pool is still over budget, the ones unattended longest.
pub fn victims(candidates: List(Candidate), limits: Limits) -> List(Candidate) {
  // A limit shorter than the detachment grace must still be honourable.
  let grace = int.min(limits.detached_ms, limits.idle_ms)
  let #(expired, resident) =
    candidates
    |> list.filter(fn(one) {
      !one.running && one.jobs == 0 && one.idle_ms >= grace
    })
    |> list.partition(fn(one) { one.idle_ms >= limits.idle_ms })
  let over = sum_kb(candidates) - sum_kb(expired) - limits.budget_kb
  let crowded =
    resident
    |> list.sort(fn(a, b) { int.compare(b.idle_ms, a.idle_ms) })
    |> trim(over)
  list.append(expired, crowded)
}

fn trim(candidates: List(Candidate), over: Int) -> List(Candidate) {
  case candidates {
    [one, ..rest] if over > 0 -> [one, ..trim(rest, over - one.kilobytes)]
    _ -> []
  }
}
