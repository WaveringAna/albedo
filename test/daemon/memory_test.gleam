//// Kernel memory is read from the operating system, once per sweep.

import gleeunit/should

@external(erlang, "albedo_runtime_test_support", "own_rss")
fn own_rss() -> List(#(Int, Int))

@external(erlang, "albedo_runtime_test_support", "missing_rss")
fn missing_rss() -> List(#(Int, Int))

pub fn resident_memory_is_reported_per_process_test() {
  let assert [#(pid, kilobytes)] = own_rss()
  { pid > 1 } |> should.be_true
  // This runtime is holding more than a megabyte; the units are kibibytes.
  { kilobytes > 1024 } |> should.be_true
}

pub fn a_process_that_is_gone_is_simply_absent_test() {
  missing_rss() |> should.equal([])
}
