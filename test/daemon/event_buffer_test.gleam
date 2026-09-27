/// Unicode eviction and replay gaps are impractical on the shared E2E event stream.
import albedo/daemon/event_buffer as buffer
import gleam/int
import gleam/list
import gleam/string
import gleeunit/should

pub fn replay_is_ordered_and_only_a_gap_requires_reset_test() {
  let events =
    int.range(1, 301, buffer.new(), fn(events, n) {
      buffer.push(events, n, int.to_string(n))
    })
  buffer.since(events, 42, 300) |> should.equal(Error(Nil))
  buffer.since(events, -1, 300) |> should.equal(Error(Nil))
  buffer.since(events, 301, 300) |> should.equal(Error(Nil))
  let assert Ok(retained) = buffer.since(events, 44, 300)
  list.length(retained) |> should.equal(256)
  list.first(retained) |> should.equal(Ok("45"))
  buffer.since(events, 298, 300) |> should.equal(Ok(["299", "300"]))
  buffer.since(events, 300, 300) |> should.equal(Ok([]))
  buffer.since(buffer.new(), 0, 0) |> should.equal(Ok([]))
}

pub fn byte_budget_evicts_oldest_without_splitting_unicode_test() {
  let large = string.repeat("é", 1_048_576)
  let events =
    buffer.new()
    |> buffer.push(1, large)
    |> buffer.push(2, large)
  buffer.since(events, 0, 2) |> should.equal(Ok([large, large]))
  let events = buffer.push(events, 3, "next")
  buffer.since(events, 0, 3) |> should.equal(Error(Nil))
  buffer.since(events, 1, 3) |> should.equal(Ok([large, "next"]))
}

pub fn oversized_event_leaves_a_replay_gap_until_the_client_resets_test() {
  let events = buffer.new() |> buffer.push(1, "before")
  let events = buffer.push(events, 2, string.repeat("x", 4_194_305))
  buffer.since(events, 1, 2) |> should.equal(Error(Nil))
  buffer.since(events, 2, 2) |> should.equal(Ok([]))
  let events = buffer.push(events, 3, "after")
  buffer.since(events, 1, 3) |> should.equal(Error(Nil))
  buffer.since(events, 2, 3) |> should.equal(Ok(["after"]))
}
