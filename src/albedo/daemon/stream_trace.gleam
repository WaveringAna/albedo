//// What a provider call streamed before it ended, counted as it arrives.
////
//// A call that times out or is cut off leaves no response, so the request
//// ledger could not say whether the provider answered nothing at all or kept
//// thinking while the connection was abandoned. The worker that streams the
//// call feeds each event through `observe`; the counters live in an atomics
//// array because the callback that sees the events cannot return state to the
//// code that records the row. Only the streaming process writes it. What the
//// response reported about itself (when its headers came, its ids, the usage
//// its latest chunk metered) is not a count: those events are sent to the
//// process that made the trace, whose mailbox holds them until `reported`
//// reads them once the call has ended.

import albedo/openai_api/types
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Subject}
import gleam/option.{type Option, None, Some}
import gleam/string

pub opaque type Trace {
  Trace(
    counters: Counters,
    started_ms: Int,
    notes: Subject(#(types.Event, Int)),
  )
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

/// What the response reported about itself before it ended: when its headers
/// came, its ids, and the usage its latest chunk metered, which is what a
/// call that fails midway cost so far.
pub type Reported {
  Reported(
    first_byte_ms: Option(Int),
    response_id: Option(String),
    model_version: Option(String),
    trace_id: Option(String),
    usage: Option(types.Usage),
    total_tokens: Option(Int),
  )
}

/// A response that reported nothing about itself.
pub const unreported = Reported(None, None, None, None, None, None)

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

/// A trace for a call that starts at `started_ms`, made by the process that
/// will read what it reported.
pub fn new(started_ms: Int) -> Trace {
  Trace(new_counters(4, []), started_ms, process.new_subject())
}

/// Counts one streamed event, arriving at `now_ms`. What the response
/// reports about itself is noted, not counted.
pub fn observe(trace: Trace, event: types.Event, now_ms: Int) -> Nil {
  let Trace(counters, started_ms, notes) = trace
  case event {
    types.Responded(_) | types.Metered(..) | types.Served(..) ->
      process.send(notes, #(event, now_ms))
    types.Started(_) -> {
      process.send(notes, #(event, now_ms))
      count(counters, started_ms, now_ms, None)
    }
    types.ThinkingDelta(text) ->
      count(counters, started_ms, now_ms, Some(#(thinking, text)))
    types.TextDelta(_, _, text) | types.ArgumentsDelta(_, _, text) ->
      count(counters, started_ms, now_ms, Some(#(output, text)))
  }
}

/// Counts an event, adding its text's bytes to the counter it names.
fn count(
  counters: Counters,
  started_ms: Int,
  now_ms: Int,
  text: Option(#(Int, String)),
) -> Nil {
  let _ = case get(counters, events) {
    0 -> put(counters, first_event, now_ms - started_ms)
    _ -> dynamic.nil()
  }
  let _ = add(counters, events, 1)
  let _ = case text {
    Some(#(counter, text)) -> add(counters, counter, string.byte_size(text))
    None -> dynamic.nil()
  }
  Nil
}

/// What the response reported about itself, read once by the process that
/// made the trace after the call has ended.
pub fn reported(trace: Trace) -> Reported {
  read_notes(trace, unreported)
}

fn read_notes(trace: Trace, reported: Reported) -> Reported {
  case process.receive(trace.notes, 0) {
    Error(Nil) -> reported
    Ok(#(event, now_ms)) ->
      read_notes(trace, note(reported, event, now_ms - trace.started_ms))
  }
}

fn note(reported: Reported, event: types.Event, at_ms: Int) -> Reported {
  case event {
    types.Responded(_) ->
      Reported(
        ..reported,
        first_byte_ms: option.or(reported.first_byte_ms, Some(at_ms)),
      )
    types.Metered(usage, total) ->
      Reported(..reported, usage: Some(usage), total_tokens: total)
    types.Served(model_version, trace_id) ->
      Reported(
        ..reported,
        model_version: option.or(model_version, reported.model_version),
        trace_id: option.or(trace_id, reported.trace_id),
      )
    types.Started(id) -> Reported(..reported, response_id: Some(id))
    types.ThinkingDelta(_) | types.TextDelta(..) | types.ArgumentsDelta(..) ->
      reported
  }
}

/// What the call has streamed so far.
pub fn streamed(trace: Trace) -> Streamed {
  let Trace(counters, _, _) = trace
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
