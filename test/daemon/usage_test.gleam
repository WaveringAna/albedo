//// Catches a rate computed for a call that took no measurable time or that
//// reported no usage. E2E timing cannot make a local call take zero
//// milliseconds on demand, so the guard runs only here.

import albedo/daemon/usage
import gleam/option.{type Option, None, Some}
import gleeunit/should

fn tokens(completion: Int) -> Option(usage.Tokens) {
  Some(usage.Tokens(10, completion, None, None, None, None, None))
}

pub fn the_rate_is_output_tokens_over_the_call_span_test() -> Nil {
  usage.Metadata("model", 1, tokens(100), None, Some(2000))
  |> usage.tokens_per_second
  |> should.equal(Some(50.0))
}

pub fn a_call_without_a_measured_span_has_no_rate_test() -> Nil {
  usage.Metadata("model", 1, tokens(100), None, None)
  |> usage.tokens_per_second
  |> should.equal(None)
  usage.Metadata("model", 1, tokens(100), None, Some(0))
  |> usage.tokens_per_second
  |> should.equal(None)
}

pub fn a_record_without_usage_has_no_rate_test() -> Nil {
  usage.Metadata("model", 1, None, None, Some(2000))
  |> usage.tokens_per_second
  |> should.equal(None)
}
