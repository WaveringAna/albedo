//// Actor-owned session data and its bounded event stream.

import albedo/daemon/bus
import albedo/daemon/context_snapshot
import albedo/daemon/conversation
import albedo/daemon/transcript
import albedo/daemon/turn.{type Submission}
import albedo/daemon/usage
import albedo/harness/loop
import albedo/harness/runtime
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option}
import gleam/string

pub type State(message) {
  State(
    info: conversation.Info,
    host: runtime.Runtime,
    kernel: Option(runtime.Session),
    home: String,
    self: Subject(message),
    history: Option(List(transcript.Entry)),
    latest_usage: Option(usage.Metadata),
    activity: turn.Activity,
    steering: List(Submission),
    sequence: Int,
    events: List(#(Int, String)),
    watchers: List(#(process.Pid, fn() -> Nil)),
    notice: Option(String),
    context: context_snapshot.Snapshot,
    pin: loop.Pin,
    last_touch: Int,
    /// While the kernel boots: boot attempts so far, and the work waiting for
    /// it, re-sent to the actor once the kernel is ready.
    booting: Option(#(Int, List(message))),
  )
}

/// Streaming clients are woken as each event is published, so a model delta
/// reaches a terminal without waiting for a polling interval.
pub fn emit(state: State(message), event: String) -> State(message) {
  let seq = state.sequence + 1
  let events = trim([#(seq, event), ..state.events], 256, 4_194_304)
  let watchers =
    list.filter(state.watchers, fn(watcher) { process.is_alive(watcher.0) })
  list.each(watchers, fn(watcher) { watcher.1() })
  bus.activity(state.info.id, event)
  State(..state, sequence: seq, events: events, watchers: watchers)
}

fn trim(
  events: List(#(Int, String)),
  count: Int,
  bytes: Int,
) -> List(#(Int, String)) {
  case events {
    [] -> []
    [event, ..rest] -> {
      let size = string.byte_size(event.1)
      case count > 0 && size <= bytes {
        True -> [event, ..trim(rest, count - 1, bytes - size)]
        False -> []
      }
    }
  }
}

pub fn unprepared() -> context_snapshot.Snapshot {
  context_snapshot.pending(
    "runtime session has not prepared a provider request",
  )
}
