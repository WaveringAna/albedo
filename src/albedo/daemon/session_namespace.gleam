//// Persistence and user-visible lifecycle notices for a session's Python namespace.

import albedo/daemon/events as view
import albedo/daemon/session_state
import albedo/harness/extensions/python/kernel as python
import albedo/harness/location
import albedo/harness/runtime
import albedo/harness/ssh
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub const lost_notice = "<system-note>The python kernel got reset and all variables are lost</system-note>"

pub type KernelObservation {
  KernelObservation(
    instance_id: Option(String),
    build: Option(String),
    state: String,
    stage: Option(String),
    stale: Option(python.Stale),
    live_job_count: Option(Int),
  )
}

/// Capture the live kernel's facts without starting or replacing it.
pub fn observe_kernel(
  state: session_state.State(message),
) -> Result(KernelObservation, String) {
  case state.kernel {
    None -> {
      use loaded <- result.try(runtime.observe_loaded(state.host, state.info.id))
      let phase = case state.booting {
        Some(_) -> "booting"
        None -> loaded.phase
      }
      Ok(
        KernelObservation(
          option.map(loaded.kernel, fn(observed) { observed.instance_id })
            |> option.or(loaded.recorded_kernel_id),
          option.then(loaded.kernel, fn(observed) { observed.build }),
          phase,
          preparation_stage(state.info.cwd, phase == "booting"),
          option.then(loaded.kernel, fn(observed) { observed.stale }),
          case loaded.kernel, phase {
            Some(observed), _ -> Some(observed.live_job_count)
            None, "none" -> Some(0)
            _, _ -> None
          },
        ),
      )
    }
    Some(kernel) -> {
      let stage = preparation_stage(state.info.cwd, state.booting != None)
      case runtime.kernel_observation(kernel) {
        Ok(observed) ->
          Ok(KernelObservation(
            Some(observed.instance_id),
            observed.build,
            case state.booting, observed.linked {
              Some(_), _ -> "booting"
              None, True -> "attached"
              None, False -> "reattaching"
            },
            stage,
            observed.stale,
            Some(observed.live_job_count),
          ))
        Error(_) ->
          case runtime.alive(kernel) {
            True -> Error("kernel observation unavailable")
            False ->
              Ok(KernelObservation(None, None, "lost", stage, None, None))
          }
      }
    }
  }
}

fn preparation_stage(workspace: String, preparing: Bool) -> Option(String) {
  case preparing, location.parse(workspace) {
    True, Ok(location.Remote(..) as at) ->
      location.ssh_target(at)
      |> result.map(ssh.step)
      |> result.unwrap("")
      |> fn(step) {
        case step {
          "" -> None
          _ -> Some(step)
        }
      }
    _, _ -> None
  }
}

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

fn names(values: List(String)) -> String {
  string.join(list.take(values, 40), ", ")
}

fn human_size(bytes: Int) -> String {
  case bytes {
    bytes if bytes >= 1024 * 1024 -> int.to_string(bytes / 1_048_576) <> " MB"
    bytes -> int.to_string(bytes / 1024) <> " KB"
  }
}

fn largest(saved: python.Saved) -> String {
  saved.largest
  |> list.map(fn(entry) { entry.0 <> " (" <> human_size(entry.1) <> ")" })
  |> names
}

fn missed_names(missed: List(#(String, String))) -> String {
  list.take(missed, 20)
  |> list.map(fn(entry) { entry.0 <> " (" <> entry.1 <> ")" })
  |> string.join(", ")
}

fn restored_notice(saved: python.Saved) -> String {
  "<system-note>The python kernel restarted. These variables were restored from disk: "
  <> names(saved.names)
  <> case saved.defs {
    [] -> ""
    defs ->
      ". Functions, classes, and imports re-run from source: " <> names(defs)
  }
  <> case saved.missed {
    [] -> ""
    missed -> ". These were not restored: " <> missed_names(missed)
  }
  <> case saved.largest {
    [] -> ""
    _ -> ". Largest saved variables: " <> largest(saved)
  }
  <> ". Other imports and definitions from earlier cells are gone.</system-note>"
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
    Ok(python.Saved([_, ..] as names, missed, engine, _defs, _largest)) ->
      prefix
      <> int.to_string(list.length(names))
      <> " variables saved to disk"
      <> case missed, engine {
        [], _ -> ""
        _, "pickle" ->
          ", "
          <> int.to_string(list.length(missed))
          <> " skipped (source definitions are restored when available)"
        _, _ -> ", " <> int.to_string(list.length(missed)) <> " skipped"
      }
    _ -> prefix <> "variables are gone, the transcript is intact"
  }
}

/// The session's kernel when it has a live, current one. A dead one is
/// dropped, so the caller asks the runtime for a replacement; so is a stale
/// one nothing keeps, and the runtime swaps it before handing it back.
pub fn ready(
  state: session_state.State(message),
) -> #(session_state.State(message), Option(runtime.Session)) {
  case state.kernel {
    Some(kernel) ->
      case runtime.alive(kernel) && !runtime.upgradable(kernel) {
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
  |> session_state.emit(view.note("daemon", text))
}

/// Take a kernel the runtime just opened. A session with history had a
/// namespace the model still believes in, so its saved variables are revived
/// and the gap named.
pub fn adopt(
  state: session_state.State(message),
  kernel: runtime.Session,
) -> session_state.State(message) {
  case runtime.origin(kernel) {
    runtime.Resumed ->
      session_state.State(..state, kernel: Some(kernel))
      |> session_state.emit(view.note("daemon", resumed_text))
    runtime.Upgraded(carried) ->
      adopted(state, kernel, upgraded_notice(carried), upgraded_text(carried))
    runtime.Kept -> session_state.State(..state, kernel: Some(kernel))
    runtime.Fresh -> revive(state, kernel)
  }
}

/// What the swap replaced the kernel for, as the notice and note say it.
fn upgraded_to(reason: python.Stale) -> String {
  case reason {
    python.Bundle -> "the new python bundle"
    python.Modules -> "the session's new extension modules"
    python.Protocol -> "the current kernel protocol"
  }
}

fn upgraded_notice(carried: python.Carried) -> String {
  let saved = carried.saved
  "<system-note>The python kernel was upgraded to "
  <> upgraded_to(carried.reason)
  <> ". "
  <> case saved.names {
    [] -> "No variables were restored"
    _ -> "Restored: " <> names(saved.names)
  }
  <> case saved.defs {
    [] -> ""
    defs ->
      ". Functions, classes, and imports re-run from source: " <> names(defs)
  }
  <> case saved.missed {
    [] -> "."
    missed -> ". Not carried: " <> missed_names(missed) <> "."
  }
  <> " Imports and definitions from earlier cells are gone unless named here.</system-note>"
}

fn upgraded_text(carried: python.Carried) -> String {
  "python kernel upgraded to "
  <> upgraded_to(carried.reason)
  <> "; restored "
  <> int.to_string(list.length(carried.saved.names))
  <> " variables"
  <> case carried.saved.missed {
    [] -> ""
    missed -> ", " <> int.to_string(list.length(missed)) <> " not carried"
  }
}

/// Adopt only the actual settled runtime handle carried by the completion.
pub fn upgrade(
  state: session_state.State(message),
  report: runtime.KernelUpgrade,
) -> session_state.State(message) {
  case report.session {
    Some(kernel) -> adopt(state, kernel)
    None -> session_state.State(..state, kernel: None)
  }
}

const resumed_text = "python kernel reattached; its variables and jobs carried on"

fn revive(
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
        Ok(python.Saved([_, ..], _, _, _, _) as saved) ->
          adopted(state, kernel, restored_notice(saved), restored_text(saved))
        _ -> adopted(state, kernel, lost_notice, lost_text)
      }
    }
  }
}
