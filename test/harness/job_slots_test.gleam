//// Shared admission must cap grants, bound its queue, and retain owned slots.
//// Barriers force grant and owner-death interleavings that E2E cannot order.

import gleeunit/should

@external(erlang, "albedo_job_slots_test_support", "check")
fn check() -> Bool

pub fn shared_local_job_admission_test() -> Nil {
  check() |> should.be_true
}
