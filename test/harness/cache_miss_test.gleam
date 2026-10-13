// A cache miss is told from the rounding a provider's cache does and from
// losses albedo caused or expected, by comparing two rows of the request
// ledger. An end-to-end run cannot wait out a cache's lifetime or change a
// head between two calls on demand, so the cases that must stay quiet live
// here: an expired cache, a rewritten history, a loss inside the block the
// provider rounds to, and a loss too small for a big prompt to notice.
import albedo/daemon/requests.{type Row, Row}
import gleam/option.{None, Some}
import gleeunit/should

const whole = 600_000

fn row(id: Int, input: Int, cached: Int) -> Row {
  Row(
    id: id,
    session: "session",
    seq: None,
    kind: "turn",
    profile: "profile",
    provider: "provider",
    account: None,
    model: "model",
    started_ms: id * 10_000,
    finished_ms: id * 10_000 + 5000,
    outcome: "ok",
    status: None,
    error: None,
    input_tokens: Some(input),
    cached_input_tokens: Some(cached),
    cache_creation_tokens: None,
    cache_write_5m_tokens: None,
    cache_write_1h_tokens: None,
    output_tokens: Some(100),
    reasoning_tokens: None,
    head_hash: "head",
    inputs: id * 2,
    replaced: Some(0),
    projection_hash: None,
    strategy: None,
    cache_marks: [],
    run_id: None,
    input_chain: None,
    streamed: None,
    first_byte_ms: None,
    total_tokens: None,
    response_id: None,
    model_version: None,
    trace_id: None,
  )
}

pub fn a_call_that_reads_what_was_left_cached_has_no_miss_test() -> Nil {
  requests.miss_between(
    row(1, 100_000, 90_000),
    row(2, 101_000, 100_000),
    whole,
  )
  |> should.equal(None)
}

pub fn a_big_loss_is_a_miss_test() -> Nil {
  // The previous call left its whole prompt cached; this one read 70k of it.
  requests.miss_between(row(1, 102_000, 94_000), row(2, 103_000, 70_000), whole)
  |> should.equal(Some(32_000))
}

pub fn a_loss_inside_the_providers_rounding_is_not_test() -> Nil {
  requests.miss_between(row(1, 102_000, 94_000), row(2, 103_000, 96_000), whole)
  |> should.equal(None)
}

pub fn a_loss_under_a_twentieth_of_a_big_prompt_is_not_test() -> Nil {
  // 9k lost clears the floor but is under 5% of 400k.
  requests.miss_between(
    row(1, 400_000, 390_000),
    row(2, 401_000, 391_000),
    whole,
  )
  |> should.equal(None)
}

pub fn a_cache_past_its_lifetime_is_expected_to_be_gone_test() -> Nil {
  let late = Row(..row(2, 101_000, 0), started_ms: 15_000 + whole)
  requests.miss_between(row(1, 100_000, 90_000), late, whole)
  |> should.equal(None)
}

pub fn a_changed_head_or_rewritten_history_is_expected_test() -> Nil {
  let previous = row(1, 100_000, 90_000)
  requests.miss_between(
    previous,
    Row(..row(2, 101_000, 0), head_hash: "other head"),
    whole,
  )
  |> should.equal(None)
  requests.miss_between(
    previous,
    Row(..row(2, 101_000, 0), projection_hash: Some("compacted")),
    whole,
  )
  |> should.equal(None)
  requests.miss_between(
    previous,
    Row(..row(2, 101_000, 0), model: "other model"),
    whole,
  )
  |> should.equal(None)
}

pub fn a_shorter_history_is_a_rewind_not_a_miss_test() -> Nil {
  requests.miss_between(
    row(3, 100_000, 90_000),
    Row(..row(4, 60_000, 0), inputs: 4),
    whole,
  )
  |> should.equal(None)
}

pub fn a_provider_that_never_cached_has_nothing_to_lose_test() -> Nil {
  requests.miss_between(row(1, 100_000, 0), row(2, 101_000, 0), whole)
  |> should.equal(None)
}

pub fn a_marked_cache_counts_what_the_last_call_wrote_test() -> Nil {
  // Claude: the previous call read 80k and wrote 20k under its marks, so 100k
  // was left; a call that reads only 20k of it lost 80k.
  let previous =
    Row(..row(1, 101_000, 80_000), cache_creation_tokens: Some(20_000))
  requests.miss_between(previous, row(2, 102_000, 20_000), whole)
  |> should.equal(Some(80_000))
}
