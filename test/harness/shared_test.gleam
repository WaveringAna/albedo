//// A shared value must cost nothing to capture or send, and a released
//// handle must fail loudly rather than answer a stale value; neither shows
//// through the daemon's behaviour until memory or a wrong catalog does.

import albedo/harness/protect
import albedo/shared
import gleam/int
import gleam/list
import gleam/string
import gleeunit/should

@external(erlang, "albedo_copy_test_support", "captured_words")
fn captured_words(term: a) -> Int

pub fn read_answers_the_published_value_test() -> Nil {
  let handle = shared.publish(#("catalog", [1, 2, 3]))
  shared.read(handle) |> should.equal(#("catalog", [1, 2, 3]))
  shared.release(handle)
}

pub fn captured_shared_value_copies_nothing_test() -> Nil {
  let baseline = captured_words(Nil)
  // Built at runtime: a string literal would already be one.
  let value =
    list.repeat(Nil, 20_000) |> list.index_map(fn(_, n) { int.to_string(n) })
  should.be_true(captured_words(value) > baseline + 60_000)
  let handle = shared.publish(value)
  let read = shared.read(handle)
  captured_words(read) |> should.equal(baseline)
  // A selection over a shared list copies its cells, never its elements.
  should.be_true(captured_words(list.take(read, 10_000)) < baseline + 30_000)
  shared.release(handle)
}

pub fn reading_a_released_handle_panics_test() -> Nil {
  let handle = shared.publish("gone")
  shared.release(handle)
  let assert Error(reason) = protect.attempt(fn() { shared.read(handle) })
  should.be_true(string.contains(reason, "shared value was released"))
}
