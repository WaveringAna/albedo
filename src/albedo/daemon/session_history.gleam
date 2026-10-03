//// Transcript projection, provider attribution, and interrupted tool recovery.

import albedo/daemon/conversation
import albedo/daemon/events as view
import albedo/daemon/http_history
import albedo/daemon/image_fit
import albedo/daemon/message_content
import albedo/daemon/projection
import albedo/daemon/session_state
import albedo/daemon/transcript
import albedo/harness/runtime
import albedo/openai_api/types
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

fn raw_inputs(entries: List(transcript.Entry)) -> List(types.Input) {
  list.map(entries, fn(entry) { entry.input })
}

pub fn projected_for(
  history: Option(List(transcript.Entry)),
  provider: String,
  protocol: types.Protocol,
) -> Result(List(types.Input), String) {
  case history {
    None -> Error("transcript is not loaded")
    Some(history) -> projection.for_model(history, provider, protocol)
  }
}

pub fn tag_unknown_provider(
  entries: List(transcript.Entry),
  provider: String,
) -> List(transcript.Entry) {
  case provider {
    "" -> entries
    provider ->
      list.map(entries, fn(entry) {
        case entry.provider {
          Some(_) -> entry
          None -> transcript.Entry(..entry, provider: Some(provider))
        }
      })
  }
}

pub fn recover_pending(
  host: runtime.Runtime,
  history: Option(List(transcript.Entry)),
  kernel: runtime.Session,
  images: types.ImageLimits,
) -> List(types.Input) {
  let inputs = case history {
    Some(history) -> history |> list.reverse |> raw_inputs
    None -> []
  }
  let completed =
    list.filter_map(inputs, fn(input) {
      case input {
        types.ToolOutput(id, _, _) -> Ok(id)
        _ -> Error(Nil)
      }
    })
  let pending =
    list.flat_map(inputs, message_content.calls)
    |> list.filter(fn(call) { !list.contains(completed, call.id) })
  list.map(pending, runtime.recover(host, kernel, _, images))
}

pub fn ensure_history(
  state: session_state.State(message),
) -> Result(session_state.State(message), String) {
  case state.history {
    Some(_) -> Ok(state)
    None ->
      conversation.load_entries(runtime.ledger(state.host), state.info.id)
      |> result.map(fn(entries) {
        session_state.State(
          ..state,
          history: Some(
            entries
            |> tag_unknown_provider(state.info.provider)
            |> list.reverse,
          ),
        )
      })
  }
}

pub fn remember(
  state: session_state.State(message),
  inputs: List(types.Input),
  timestamp: Int,
) -> session_state.State(message) {
  remember_response(state, inputs, timestamp, None)
}

/// Remembers image fits as `conversation.commit_fits` wrote them: the copies
/// stand in for every earlier image, and each note follows.
pub fn remember_fits(
  state: session_state.State(message),
  fits: List(transcript.ImageFit),
  timestamp: Int,
) -> session_state.State(message) {
  let history =
    option.map(state.history, fn(history) {
      list.map(history, fn(entry) {
        transcript.Entry(
          ..entry,
          input: list.fold(fits, entry.input, image_fit.apply),
        )
      })
    })
  session_state.State(..state, history:)
  |> remember(list.map(fits, fn(fit) { types.User(fit.note) }), timestamp)
}

/// Remembers committed inputs as `conversation.commit_response` wrote them.
pub fn remember_response(
  state: session_state.State(message),
  inputs: List(types.Input),
  timestamp: Int,
  thought_ms: Option(Int),
) -> session_state.State(message) {
  let entries =
    conversation.entries(
      inputs,
      Some(timestamp),
      Some(state.info.provider),
      thought_ms,
    )
  // Committed rows keep their identities in the live cache too, so reconnects
  // recover the same admission metadata before any eviction or restart.
  let entries = case timestamp, inputs {
    0, _ | _, [] -> entries
    _, _ ->
      case conversation.last_seq(runtime.ledger(state.host), state.info.id) {
        Error(_) -> entries
        Ok(last) -> {
          let first = last - list.length(entries) + 1
          let #(_, entries) =
            list.map_fold(entries, first, fn(seq, entry) {
              #(
                seq + 1,
                transcript.Entry(
                  ..entry,
                  source: Some(transcript.SourceRef(state.info.id, seq)),
                ),
              )
            })
          entries
        }
      }
  }
  // An unloaded transcript stays unloaded: the entries are already durable and
  // the next load reads them. Starting a list here would pass a transcript of
  // only these entries off as the whole conversation.
  let state = case state.history {
    Some(history) ->
      session_state.State(
        ..state,
        history: Some(list.append(list.reverse(entries), history)),
      )
    None -> state
  }
  // A zero timestamp is a candidate projection, not a commit.
  case timestamp, inputs {
    0, _ | _, [] -> state
    _, _ ->
      publish_committed(
        state,
        list.length(entries),
        list.any(inputs, fn(input) {
          case input {
            types.ToolOutput(_, _, _) -> False
            _ -> True
          }
        }),
      )
  }
}

/// Project committed rows through the same native history projection as GET.
/// Only the newly durable range is read; a loaded transcript is never required.
fn publish_committed(
  state: session_state.State(message),
  count: Int,
  publish_rows: Bool,
) -> session_state.State(message) {
  case conversation.snapshot(runtime.ledger(state.host), state.info.id) {
    Error(_) -> state
    Ok(snapshot) -> {
      let state = case publish_rows {
        True -> publish_range(state, snapshot, snapshot.upper - count, 0, True)
        False -> state
      }
      session_state.emit(state, view.Committed(snapshot.upper))
    }
  }
}

fn publish_range(
  state: session_state.State(message),
  snapshot: conversation.Snapshot,
  after: Int,
  continuation_after: Int,
  include_rows: Bool,
) -> session_state.State(message) {
  case
    conversation.read_range(
      runtime.ledger(state.host),
      conversation.Range(
        snapshot,
        conversation.After(after),
        200,
        continuation_after,
      ),
    )
  {
    Error(error) ->
      session_state.emit(
        state,
        view.Failure(None, "history_publication_failed", error),
      )
    Ok(page) -> {
      let state =
        list.fold(http_history.project(page), state, fn(state, entry) {
          case include_rows || entry.kind == "continuation" {
            False -> state
            True -> publish_entry(state, entry)
          }
        })
      let marker =
        list.fold(page.continuations, continuation_after, fn(acc, marker) {
          int.max(acc, marker.order)
        })
      case page.more_continuations, page.has_more {
        True, _ ->
          case marker > continuation_after {
            True -> publish_range(state, snapshot, after, marker, False)
            False ->
              session_state.emit(
                state,
                view.Failure(
                  None,
                  "history_publication_failed",
                  "continuation page made no progress",
                ),
              )
          }
        False, True -> {
          let position =
            list.last(page.entries)
            |> result.map(fn(row) { row.source.seq })
            |> result.unwrap(after)
          case position > after {
            True -> publish_range(state, snapshot, position, marker, True)
            False -> state
          }
        }
        False, False -> state
      }
    }
  }
}

fn publish_entry(
  state: session_state.State(message),
  entry: http_history.Entry,
) -> session_state.State(message) {
  case entry.kind {
    "thinking" ->
      case entry.turn_id, entry.thinking_ms {
        Some(run_id), Some(elapsed) ->
          session_state.emit(
            state,
            view.Thinking(run_id, entry.id, "", Some(elapsed)),
          )
        _, _ -> state
      }
    "tool_call" | "tool_result" -> state
    _ -> session_state.emit(state, view.Message(entry))
  }
}
