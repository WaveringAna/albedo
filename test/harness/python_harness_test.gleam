//// The Python-side harnesses run with the rest of the suite; they own no build lock.

import gleeunit/should

@external(erlang, "albedo_runtime_test_support", "run_python")
fn run_python(script: String, timeout_ms: Int) -> Result(String, String)

pub fn process_supervision_harness_test() {
  run_python("test/harness/process_supervision_test.py", 300_000)
  |> should.be_ok
}
