//// Actor-owned session data and its bounded event stream.

import albedo/clock
import albedo/daemon/active_output
import albedo/daemon/bus
import albedo/daemon/context_snapshot
import albedo/daemon/conversation
import albedo/daemon/event_buffer
import albedo/daemon/events as view
import albedo/daemon/mail
import albedo/daemon/operations
import albedo/daemon/session_activity
import albedo/daemon/store
import albedo/daemon/tool_progress
import albedo/daemon/transcript
import albedo/daemon/turn.{type Submission}
import albedo/daemon/usage
import albedo/harness/loop
import albedo/harness/runtime
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub type Watcher {
  Watcher(owner: process.Pid, notify: fn() -> Nil, notified: Bool)
}

pub type State(message) {
  State(
    active_output: active_output.Projection,
    info: conversation.Info,
    host: runtime.Runtime,
    kernel: Option(runtime.Session),
    /// The kernel the idle sweep released, whose composition stays prepared
    /// for the next open: its extensions keep hearing the session meanwhile.
    released: Option(runtime.Session),
    home: String,
    self: Subject(message),
    history: Option(List(transcript.Entry)),
    latest_usage: Option(usage.Metadata),
    activity: turn.Activity,
    steering: List(Submission),
    active_submissions: List(Submission),
    sequence: Int,
    events: event_buffer.Buffer,
    watchers: List(Watcher),
    notice: Option(String),
    context: context_snapshot.Snapshot,
    pin: loop.Pin,
    /// Inputs evicted by the last prepared projection; the next live reload
    /// starts its pin at this baseline, even if its first turn compacts.
    prepared_head: Option(Int),
    last_touch: Int,
    /// While the kernel boots: boot attempts so far, and the work waiting for
    /// it, re-sent to the actor once the kernel is ready.
    booting: Option(#(Int, List(message))),
    blocked_until: Int,
    generation: String,
    tool_progress: tool_progress.Projection,
    progress_timer_token: Int,
    progress_timer: Option(process.Timer),
    live_activity: session_activity.Projection,
    announced_status: Option(session_activity.Status),
    /// Text and thinking deltas held for the end of the frame, newest first,
    /// the timer that publishes them, when output was last published, and
    /// the actor's own message that publishes them.
    pending_output: List(view.Event),
    output_timer: Option(process.Timer),
    output_published_at: Int,
    publish_output: message,
  )
}

/// Deltas reach a client at most once a frame; a terminal draws no faster.
const frame_ms = 16

/// Streaming clients are woken as each event is published. A text or thinking
/// delta after a quiet frame goes out at once; later ones wait for the frame
/// to end and go out merged. Every other event publishes the waiting deltas
/// first, so the stream keeps its order.
pub fn emit(state: State(message), event: view.Event) -> State(message) {
  case event {
    // Internal worker signals never receive public SSE sequence numbers.
    view.Checkpoint | view.ProviderStarted -> state
    view.Text(..) | view.Thinking(..) -> hold(state, event)
    view.Status(status) ->
      publish(
        State(..flush_output(state), announced_status: Some(status)),
        event,
      )
    _ -> publish(announce(state), event)
  }
}

fn hold(state: State(message), event: view.Event) -> State(message) {
  let event = case event {
    view.Text(run_id, message_id, text) ->
      view.Text(
        run_id,
        active_output.namespace(state.active_output, message_id),
        text,
      )
    view.Thinking(run_id, message_id, text, elapsed) ->
      view.Thinking(
        run_id,
        active_output.namespace(state.active_output, message_id),
        text,
        elapsed,
      )
    _ -> event
  }
  let now = clock.monotonic_ms()
  case state.pending_output, now - state.output_published_at >= frame_ms {
    [], True -> publish_output(State(..state, output_published_at: now), event)
    pending, _ -> {
      let timer = case state.output_timer {
        Some(timer) -> timer
        None ->
          process.send_after(
            state.self,
            int.max(0, state.output_published_at + frame_ms - now),
            state.publish_output,
          )
      }
      State(
        ..state,
        pending_output: [event, ..pending],
        output_timer: Some(timer),
      )
    }
  }
}

/// Publish the deltas held for the frame, consecutive ones of the same kind
/// and message merged. Call it before anything that reads or retires the
/// active output.
pub fn flush_output(state: State(message)) -> State(message) {
  case state.pending_output {
    [] -> state
    pending -> {
      let _ = option.map(state.output_timer, process.cancel_timer)
      let state =
        State(
          ..state,
          pending_output: [],
          output_timer: None,
          output_published_at: clock.monotonic_ms(),
        )
      list.fold(merge(pending, []), state, publish_output)
    }
  }
}

/// Newest-first deltas, oldest first with neighbours of one message merged.
fn merge(
  newest: List(view.Event),
  merged: List(view.Event),
) -> List(view.Event) {
  case newest, merged {
    [], _ -> merged
    [view.Text(run, id, text), ..rest], [view.Text(r, i, later), ..others]
      if r == run && i == id
    -> merge(rest, [view.Text(run, id, text <> later), ..others])
    [view.Thinking(run, id, text, elapsed), ..rest],
      [view.Thinking(r, i, later, closed), ..others]
      if r == run && i == id
    ->
      merge(rest, [
        view.Thinking(run, id, text <> later, option.or(closed, elapsed)),
        ..others
      ])
    [event, ..rest], _ -> merge(rest, [event, ..merged])
  }
}

fn publish_output(state: State(message), event: view.Event) -> State(message) {
  case event {
    view.Text(run_id, message_id, text) -> {
      let output =
        active_output.observe(
          state.active_output,
          run_id,
          message_id,
          "text",
          text,
          None,
        )
      list.fold(
        chunks(text),
        announce_status(State(..state, active_output: output)),
        fn(state, text) { publish(state, view.Text(run_id, message_id, text)) },
      )
    }
    view.Thinking(run_id, message_id, text, elapsed) -> {
      let output =
        active_output.observe(
          state.active_output,
          run_id,
          message_id,
          "thinking",
          text,
          elapsed,
        )
      let pieces = chunks(text)
      let last = list.length(pieces) - 1
      pieces
      |> list.index_map(fn(text, index) { #(index, text) })
      |> list.fold(
        announce_status(State(..state, active_output: output)),
        fn(state, piece) {
          let #(index, text) = piece
          publish(
            state,
            view.Thinking(run_id, message_id, text, case index == last {
              True -> elapsed
              False -> None
            }),
          )
        },
      )
    }
    _ -> publish(state, event)
  }
}

/// Text in pieces of at most 32768 scalars; one piece when it has no more
/// bytes than that.
fn chunks(text: String) -> List(String) {
  case string.byte_size(text) <= 32_768 {
    True -> [text]
    False -> scalar_chunks(string.to_utf_codepoints(text), []) |> list.reverse
  }
}

fn scalar_chunks(
  scalars: List(UtfCodepoint),
  acc: List(String),
) -> List(String) {
  case scalars {
    [] -> acc
    _ ->
      scalar_chunks(list.drop(scalars, 32_768), [
        string.from_utf_codepoints(list.take(scalars, 32_768)),
        ..acc
      ])
  }
}

/// A status transition is observed at the same owner boundary as the event
/// that caused it. Repeated deltas do not allocate repeated status events.
pub fn announce(state: State(message)) -> State(message) {
  announce_status(flush_output(state))
}

fn announce_status(state: State(message)) -> State(message) {
  let status = current_status(state)
  case state.announced_status {
    Some(previous) if previous == status -> state
    _ ->
      publish(
        State(..state, announced_status: Some(status)),
        view.Status(status),
      )
  }
}

pub fn current_status(state: State(message)) -> session_activity.Status {
  let blocking = case state.blocked_until > usage.now(), state.steering {
    True, [first, ..] ->
      option.then(first.operation_id, fn(id) {
        operations.input_outcome(runtime.ledger(state.host), id)
        |> result.unwrap(None)
        |> option.then(fn(outcome) { outcome.receipt.blocking_reason })
      })
    _, _ -> None
  }
  session_activity.status(state.activity, state.booting != None, blocking)
}

fn publish(state: State(message), event: view.Event) -> State(message) {
  let seq = state.sequence + 1
  let encoded = view.encode(state.info.id, seq, event)
  let events = event_buffer.push(state.events, seq, encoded)
  let watchers =
    list.map(state.watchers, fn(watcher) {
      case watcher.notified {
        True -> watcher
        False -> {
          watcher.notify()
          Watcher(..watcher, notified: True)
        }
      }
    })
  let observed = view.observe(state.live_activity, event, usage.now())
  let committed_mail = case event {
    view.Input(outcome, _) -> outcome.receipt.delivery == Some("committed")
    view.Message(entry) -> entry.letter != None
    _ -> False
  }
  let observed = case committed_mail {
    True -> {
      let request =
        store.query(runtime.ledger(state.host), fn(db) {
          mail.parent_request_in(db, state.info.id)
        })
      case request {
        Ok(request) -> session_activity.request(observed, request)
        Error(_) -> observed
      }
    }
    False -> observed
  }
  bus.activity(state.info.id, fn() {
    json.object([
      #("type", json.string("activity")),
      #(
        "data",
        json.object([
          #("session_id", json.string(state.info.id)),
          #(
            "cursor",
            json.object([
              #("generation", json.string(state.generation)),
              #("sequence", json.int(seq)),
            ]),
          ),
          #("status", view.status(current_status(state))),
          #(
            "current_progress",
            json.array(
              tool_progress.snapshots(state.tool_progress),
              view.progress,
            ),
          ),
          #("activity", view.activity(observed)),
        ]),
      ),
    ])
    |> json.to_string
  })
  State(
    ..state,
    sequence: seq,
    events: events,
    watchers: watchers,
    live_activity: observed,
  )
}

pub fn invalidate(
  state: State(message),
  kind: String,
  url: String,
) -> State(message) {
  emit(state, view.Invalidate(kind, url))
}

pub fn unprepared() -> context_snapshot.Snapshot {
  context_snapshot.pending(
    "runtime session has not prepared a provider request",
  )
}
