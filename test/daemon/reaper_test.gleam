import albedo/daemon/reaper.{type Candidate, Candidate, Limits}
import gleam/list
import gleeunit/should

const limits = Limits(idle_ms: 60_000, budget_kb: 1000, detached_ms: 30_000)

fn pids(victims: List(Candidate)) -> List(Int) {
  list.map(victims, fn(victim: Candidate) { victim.pid })
}

pub fn attached_and_running_kernels_are_never_released_test() {
  [
    // attached moments ago, however much it holds
    Candidate(1, 0, False, 100_000),
    // detached but working
    Candidate(2, 600_000, True, 100_000),
  ]
  |> reaper.victims(limits)
  |> should.equal([])
}

pub fn kernels_idle_past_the_limit_are_released_test() {
  [Candidate(1, 61_000, False, 10), Candidate(2, 40_000, False, 10)]
  |> reaper.victims(limits)
  |> pids
  |> should.equal([1])
}

pub fn a_pool_over_budget_loses_the_longest_unattended_first_test() {
  let victims =
    [
      Candidate(1, 31_000, False, 600),
      Candidate(2, 45_000, False, 600),
      Candidate(3, 35_000, False, 600),
    ]
    |> reaper.victims(limits)
  // 1800 held against a 1000 budget: the two quietest go, the freshest stays.
  victims |> pids |> should.equal([2, 3])
}

pub fn memory_freed_by_the_idle_rule_counts_against_the_budget_test() {
  let victims =
    [Candidate(1, 120_000, False, 900), Candidate(2, 31_000, False, 600)]
    |> reaper.victims(limits)
  // Releasing the expired kernel already brings the pool under budget.
  victims |> pids |> should.equal([1])
}

pub fn a_short_limit_still_releases_test() {
  let brief = Limits(idle_ms: 5000, budget_kb: 1000, detached_ms: 30_000)
  [Candidate(1, 6000, False, 10)]
  |> reaper.victims(brief)
  |> pids
  |> should.equal([1])
}

pub fn a_session_attached_moments_ago_is_spared_even_over_budget_test() {
  [Candidate(1, 1000, False, 5000)]
  |> reaper.victims(limits)
  |> should.equal([])
}
