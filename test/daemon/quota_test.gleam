/// A failing account's backoff grows over hours before its caps apply, far
/// past what an E2E poll can wait for.
import albedo/daemon/quota.{Settings}
import gleam/list
import gleeunit/should

fn waits(settings: quota.Settings, failures: List(Int)) -> List(Int) {
  list.map(failures, quota.wait_seconds(settings, _, False))
}

pub fn a_healthy_account_keeps_its_cadence_test() {
  let settings = Settings(600, 120, True)
  quota.wait_seconds(settings, 0, False) |> should.equal(600)
  quota.wait_seconds(settings, 0, True) |> should.equal(120)
}

pub fn failures_double_the_wait_whether_or_not_the_account_is_busy_test() {
  let settings = Settings(10, 5, True)
  waits(settings, [1, 2, 3]) |> should.equal([20, 40, 80])
  quota.wait_seconds(settings, 1, True) |> should.equal(20)
}

pub fn the_backoff_stops_doubling_after_six_failures_test() {
  waits(Settings(10, 5, True), [6, 7, 50]) |> should.equal([640, 640, 640])
}

pub fn the_backoff_never_waits_past_an_hour_test() {
  waits(Settings(600, 120, True), [1, 2, 3, 6])
  |> should.equal([1200, 2400, 3600, 3600])
}
