//// Persistence and user-visible lifecycle notices for a session's Python namespace.

import albedo/daemon/events as view
import albedo/daemon/session_state
import albedo/harness/extensions/python/kernel as python
import albedo/harness/runtime
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub const lost_notice = "<system-note>The python kernel got reset and all variables are lost</system-note>"

const lost_text = "python kernel restarted; earlier variables are gone, the transcript is intact"

/// An idle release can use the full budget; shutdown must not wait on a large namespace.
pub const state_timeout = 30_000

pub const close_state_timeout = 5000

/// Saved state lives beside the transcript, one file per session.
pub fn state_path(home: String, id: String) -> Option(String) {
  case id == "" || string.contains(id, "/") || string.contains(id, "..") {
    True -> None
    False -> Some(home <> "/kernels/" <> id <> ".state")
  }
}

pub fn save_state(
  home: String,
  id: String,
  kernel: runtime.Session,
) -> Result(python.Saved, String) {
  save_state_within(home, id, kernel, state_timeout)
}

pub fn save_state_within(
  home: String,
  id: String,
  kernel: runtime.Session,
  timeout_ms: Int,
) -> Result(python.Saved, String) {
  case state_path(home, id) {
    None -> Error("session has no state file")
    Some(path) ->
      runtime.save_state(kernel, path, timeout_ms)
      |> result.replace_error("the kernel could not write its variables")
  }
}

fn names(saved: python.Saved) -> String {
  string.join(list.take(saved.names, 40), ", ")
}

pub fn restored_notice(saved: python.Saved) -> String {
  "<system-note>The python kernel restarted. These variables were restored from disk: "
  <> names(saved)
  <> case saved.missed {
    [] -> "."
    missed ->
      ". These were not: "
      <> string.join(
        list.map(list.take(missed, 20), fn(entry) {
          entry.0 <> " (" <> entry.1 <> ")"
        }),
        ", ",
      )
      <> "."
  }
  <> " Imports and definitions from earlier cells are gone unless named here.</system-note>"
}

pub fn restored_text(saved: python.Saved) -> String {
  "python kernel restarted; restored "
  <> int.to_string(list.length(saved.names))
  <> " variables from disk"
  <> case saved.missed {
    [] -> ""
    missed -> ", " <> int.to_string(list.length(missed)) <> " could not be read"
  }
}

pub fn released_text(
  saved: Result(python.Saved, String),
  reason: String,
) -> String {
  let prefix = "python kernel released: " <> reason <> "; "
  case saved {
    Ok(python.Saved([_, ..] as names, missed, engine)) ->
      prefix
      <> int.to_string(list.length(names))
      <> " variables saved to disk"
      <> case missed, engine {
        [], _ -> ""
        _, "pickle" ->
          ", "
          <> int.to_string(list.length(missed))
          <> " skipped (install dill to also save functions and classes)"
        _, _ -> ", " <> int.to_string(list.length(missed)) <> " skipped"
      }
    _ -> prefix <> "variables are gone, the transcript is intact"
  }
}

/// The session's kernel when it has a live one. A dead one is dropped, so the
/// caller asks the runtime for a replacement.
pub fn ready(
  state: session_state.State(message),
) -> #(session_state.State(message), Option(runtime.Session)) {
  case state.kernel {
    Some(kernel) ->
      case runtime.alive(kernel) {
        True -> #(state, Some(kernel))
        False -> #(session_state.State(..state, kernel: None), None)
      }
    None -> #(state, None)
  }
}

/// The kernel now owned, its notice recorded for the next message and the
/// restart reported to the stream.
fn adopted(
  state: session_state.State(message),
  kernel: runtime.Session,
  notice: String,
  text: String,
) -> session_state.State(message) {
  session_state.State(..state, kernel: Some(kernel), notice: Some(notice))
  |> session_state.emit(view.text("note", text))
}

/// Take a kernel the runtime just opened. A session with history had a
/// namespace the model still believes in, so its saved variables are revived
/// and the gap named.
pub fn adopt(
  state: session_state.State(message),
  kernel: runtime.Session,
) -> session_state.State(message) {
  case state.notice, state.history {
    Some(notice), _ if notice == lost_notice ->
      session_state.State(..state, kernel: Some(kernel))
    _, None | _, Some([]) -> session_state.State(..state, kernel: Some(kernel))
    _, Some(_) -> {
      let revived = case state_path(state.home, state.info.id) {
        Some(path) -> runtime.load_state(kernel, path, state_timeout)
        None -> Error(python.Invalid("session has no state file"))
      }
      case revived {
        Ok(python.Saved([_, ..], _, _) as saved) ->
          adopted(state, kernel, restored_notice(saved), restored_text(saved))
        _ -> adopted(state, kernel, lost_notice, lost_text)
      }
    }
  }
}
