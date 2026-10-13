//// What a provider call streamed before it ended, counted as it arrives.
////
//// A call that times out or is cut off leaves no response, so the request
//// ledger could not say whether the provider answered nothing at all or kept
//// thinking while the connection was abandoned. The worker that streams the
//// call feeds each event through `observe`; the counters live in an atomics
//// array because the callback that sees the events cannot return state to the
//// code that records the row. Only the streaming process writes it.

import albedo/openai_api/types
import gleam/dynamic.{type Dynamic}
import gleam/option.{type Option, None, Some}
import gleam/string

pub opaque type Trace {
  Trace(counters: Counters, started_ms: Int)
}

type Counters

/// What a call streamed: the delay before its first event, how many events
/// came, and how many bytes of thinking and of answer (text and call
/// arguments) they carried.
pub type Streamed {
  Streamed(
    first_event_ms: Option(Int),
    events: Int,
    thinking_bytes: Int,
    output_bytes: Int,
  )
}

@external(erlang, "atomics", "new")
fn new_counters(size: Int, options: List(Nil)) -> Counters

@external(erlang, "atomics", "put")
fn put(counters: Counters, index: Int, value: Int) -> Dynamic

@external(erlang, "atomics", "add")
fn add(counters: Counters, index: Int, value: Int) -> Dynamic

@external(erlang, "atomics", "get")
fn get(counters: Counters, index: Int) -> Int

const first_event = 1

const events = 2

const thinking = 3

const output = 4

/// A trace for a call that starts at `started_ms`.
pub fn new(started_ms: Int) -> Trace {
  Trace(new_counters(4, []), started_ms)
}

/// Counts one streamed event, arriving at `now_ms`.
pub fn observe(trace: Trace, event: types.Event, now_ms: Int) -> Nil {
  let Trace(counters, started_ms) = trace
  let _ = case get(counters, events) {
    0 -> put(counters, first_event, now_ms - started_ms)
    _ -> dynamic.nil()
  }
  let _ = add(counters, events, 1)
  let _ = case event {
    types.Started(_) -> dynamic.nil()
    types.ThinkingDelta(text) -> add(counters, thinking, string.byte_size(text))
    types.TextDelta(_, _, text) | types.ArgumentsDelta(_, _, text) ->
      add(counters, output, string.byte_size(text))
  }
  Nil
}

/// What the call has streamed so far.
pub fn streamed(trace: Trace) -> Streamed {
  let Trace(counters, _) = trace
  let count = get(counters, events)
  Streamed(
    first_event_ms: case count {
      0 -> None
      _ -> Some(get(counters, first_event))
    },
    events: count,
    thinking_bytes: get(counters, thinking),
    output_bytes: get(counters, output),
  )
}
