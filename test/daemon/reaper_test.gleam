/// Memory-pressure ordering depends on nondeterministic RSS in E2E.
import albedo/daemon/reaper.{type Candidate, Candidate, Limits}
import gleam/list
import gleeunit/should

const limits = Limits(idle_ms: 60_000, budget_kb: 1000, detached_ms: 30_000)

fn pids(victims: List(Candidate)) -> List(Int) {
  list.map(victims, fn(victim: Candidate) { victim.pid })
}

pub fn attached_running_and_job_holding_kernels_are_never_released_test() {
  [
    // attached moments ago, however much it holds
    Candidate(1, 0, False, 0, 100_000),
    // detached but working
    Candidate(2, 600_000, True, 0, 100_000),
    // detached, idle past every limit, but a background job still runs
    Candidate(3, 600_000, False, 1, 100_000),
  ]
  |> reaper.victims(limits)
  |> should.equal([])
}

pub fn a_pool_over_budget_loses_the_longest_unattended_first_test() {
  let victims =
    [
      Candidate(1, 31_000, False, 0, 600),
      Candidate(2, 45_000, False, 0, 600),
      Candidate(3, 35_000, False, 0, 600),
    ]
    |> reaper.victims(limits)
  // 1800 held against a 1000 budget: the two quietest go, the freshest stays.
  victims |> pids |> should.equal([2, 3])
}

pub fn memory_freed_by_the_idle_rule_counts_against_the_budget_test() {
  let victims =
    [Candidate(1, 120_000, False, 0, 900), Candidate(2, 31_000, False, 0, 600)]
    |> reaper.victims(limits)
  // Releasing the expired kernel already brings the pool under budget.
  victims |> pids |> should.equal([1])
}
