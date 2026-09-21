//// Which idle kernels to release. Pure policy; the caller does the releasing.
////
//// A session that is attached or running is never a victim, though the memory
//// it holds still counts against the pool: the point is to reclaim what nobody
//// is waiting on, not to bound how many sessions a person may keep open.

import gleam/int
import gleam/list

pub type Candidate {
  Candidate(pid: Int, idle_ms: Int, running: Bool, kilobytes: Int)
}

pub type Limits {
  Limits(idle_ms: Int, budget_kb: Int, detached_ms: Int)
}

/// Kernels to release, in the order to release them: those idle past the limit,
/// then, while the pool is still over budget, the ones unattended longest.
pub fn victims(candidates: List(Candidate), limits: Limits) -> List(Candidate) {
  // A limit shorter than the detachment grace must still be honourable.
  let grace = int.min(limits.detached_ms, limits.idle_ms)
  let idle =
    list.filter(candidates, fn(one) { !one.running && one.idle_ms >= grace })
  let #(expired, resident) =
    list.partition(idle, fn(one) { one.idle_ms >= limits.idle_ms })
  let total = list.fold(candidates, 0, fn(sum, one) { sum + one.kilobytes })
  let freed = list.fold(expired, 0, fn(sum, one) { sum + one.kilobytes })
  let crowded =
    resident
    |> list.sort(fn(a, b) { int.compare(b.idle_ms, a.idle_ms) })
    |> trim(total - freed, limits.budget_kb)
  list.append(expired, crowded)
}

fn trim(
  candidates: List(Candidate),
  total: Int,
  budget: Int,
) -> List(Candidate) {
  case candidates, total > budget {
    [one, ..rest], True -> [one, ..trim(rest, total - one.kilobytes, budget)]
    _, _ -> []
  }
}
