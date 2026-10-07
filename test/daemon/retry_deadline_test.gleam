//// Retry deadlines use monotonic time, which may be negative on the BEAM.
//// Exact deadline boundaries and the zero sentinel cannot be ordered by E2E.

import albedo/daemon/session_state
import gleeunit/should

pub fn retry_wait_uses_the_same_deadline_boundary_with_negative_time_test() -> Nil {
  session_state.retry_pending(-100, -101) |> should.be_true
  session_state.retry_pending(-100, -100) |> should.be_false
  session_state.retry_pending(-100, -99) |> should.be_false
  session_state.retry_pending(100, 99) |> should.be_true
  session_state.retry_pending(100, 100) |> should.be_false
  session_state.retry_pending(0, -100) |> should.be_false
  session_state.retry_pending(0, 100) |> should.be_false
}
