//// Reconfigure a session's extensions without losing its prompt or namespace.

import albedo/daemon/bus
import albedo/daemon/events as view
import albedo/daemon/session_namespace
import albedo/daemon/session_prompt
import albedo/daemon/session_state
import albedo/daemon/turn
import albedo/harness/extension
import albedo/harness/extension/selection
import albedo/harness/runtime
import albedo/harness/runtime/state as runtime_state
import gleam/list
import gleam/option.{type Option, None, Some}

pub fn change(
  state: session_state.State(message),
  change: selection.Change,
) -> #(session_state.State(message), Result(List(extension.Summary), String)) {
  let #(state, outcome) =
    apply(state, "extensions reloaded", fn() {
      runtime.apply_change(state.host, state.info.id, state.info.cwd, change)
    })
  case outcome {
    Error(reason) -> #(state, Error(reason))
    Ok(_) -> #(state, runtime.extension_summaries(state.host, state.info.id))
  }
}

pub type Reloaded {
  Reloaded(loaded_revision: Option(String), warnings: List(String))
}

/// Apply saved choices. The runtime reports the actual surviving kernel even
/// when replacement failed after shutting down the previous namespace.
pub fn reload(
  state: session_state.State(message),
  reason: String,
) -> #(session_state.State(message), Result(Reloaded, String)) {
  apply(state, reason, fn() {
    runtime.apply_desired(state.host, state.info.id, state.info.cwd)
  })
}

fn apply(
  state: session_state.State(message),
  reason: String,
  run: fn() -> runtime_state.Application,
) -> #(session_state.State(message), Result(Reloaded, String)) {
  case turn.running(state.activity) != None || state.booting != None {
    True -> #(state, Error("session must be idle to reload"))
    False -> {
      let previous = runtime.peek_prompt(state.host, state.info.id)
      let previous_tools = option.map(state.kernel, runtime.tools)
      case run() {
        runtime_state.ApplyFailed(kernel, error) -> {
          let state =
            session_state.State(
              ..state,
              kernel: kernel,
              context: session_state.unprepared(),
            )
          #(reloaded(state), Error(error))
        }
        runtime_state.Applied(kernel, loaded_revision, runtime_warnings) -> {
          let state = case kernel {
            Some(kernel) -> session_namespace.adopt(state, kernel)
            None -> state
          }
          let state =
            session_state.State(
              ..state,
              kernel: kernel,
              context: session_state.unprepared(),
            )
          let #(state, warnings) = case
            previous_tools == option.map(kernel, runtime.tools)
          {
            False -> {
              let state = session_prompt.reset_prompt_cache(state, reason)
              case previous_tools, kernel {
                Some(_), Some(_) ->
                  case session_prompt.record_capability_change(state, reason) {
                    Ok(state) -> #(state, [])
                    Error(error) -> #(state, [
                      "reloaded, but the capability notice could not be saved: "
                      <> error,
                    ])
                  }
                _, _ -> #(state, [])
              }
            }
            True ->
              case session_prompt.pin_changed_prompt(state, previous) {
                Ok(#(state, detail)) -> #(
                  session_state.emit(
                    state,
                    view.note("daemon", reason <> detail),
                  ),
                  [],
                )
                Error(error) -> #(
                  session_prompt.reset_prompt_cache(state, reason),
                  [
                    "reloaded, but the capability notice could not be saved: "
                    <> error,
                  ],
                )
              }
          }
          let state = session_prompt.remember_prompt(state)
          #(
            reloaded(state),
            Ok(Reloaded(
              loaded_revision,
              list.append(warnings, runtime_warnings),
            )),
          )
        }
      }
    }
  }
}

pub fn refresh_requested(
  state: session_state.State(message),
  reason: String,
) -> session_state.State(message) {
  case reload(state, reason) {
    #(state, Ok(_)) -> state
    #(state, Error(error)) ->
      session_state.emit(
        state,
        view.error(reason <> ", but the reload failed: " <> error),
      )
  }
}

fn reloaded(
  state: session_state.State(message),
) -> session_state.State(message) {
  let base = "/sessions/" <> state.info.id
  bus.invalidate(
    [
      base,
      base <> "?view=configuration",
      base <> "/catalog",
      base <> "/context",
    ],
    [state.info.id],
    False,
  )
  state
  |> session_state.invalidate("session", base)
  |> session_state.invalidate("settings", base <> "?view=configuration")
  |> session_state.invalidate("catalog", base <> "/catalog")
  |> session_state.invalidate("context", base <> "/context")
}
