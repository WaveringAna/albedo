//// Regression for payloads hidden inside snapshot closure environments.
//// HTTP inspection cannot observe BEAM reachability or stored-reader closures.

import gleeunit/should

@external(erlang, "albedo_context_snapshot_probe", "retention")
fn retention() -> #(Bool, Bool, Bool, Bool)

pub fn discarded_payloads_are_not_retained_test() -> Nil {
  retention() |> should.equal(#(True, False, False, False))
}
