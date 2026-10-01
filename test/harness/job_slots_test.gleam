//// Shared admission enforces concurrent local job limits across sessions.

import gleeunit/should

@external(erlang, "albedo_job_slots_test_support", "check")
fn check() -> Bool

pub fn shared_local_job_admission_test() -> Nil {
  check() |> should.be_true
}
