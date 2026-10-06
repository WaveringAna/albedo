//// Reconfigure a session's extensions without losing its prompt or namespace.

import albedo/daemon/bus
import albedo/daemon/events as view
import albedo/daemon/session_namespace
import albedo/daemon/session_prompt
import albedo/daemon/session_state
import albedo/daemon/turn
import albedo/harness/extension
import albedo/harness/extension/selection
import albedo/harness/extensions/python/kernel as python
import albedo/harness/runtime
import gleam/list
import gleam/option.{type Option, None, Some}

/// The state once a fresh kernel replaces the old one: the next provider
/// request has not been prepared against it.
fn with_kernel(
  state: session_state.State(message),
  kernel: runtime.Session,
) -> session_state.State(message) {
  session_state.State(
    ..state,
    kernel: Some(kernel),
    released: None,
    context: session_state.unprepared(),
  )
}

pub fn change(
  state: session_state.State(message),
  change: selection.Change,
) -> #(session_state.State(message), Result(List(extension.Summary), String)) {
  case turn.running(state.activity) {
    Some(_) -> #(state, Error("session must be idle to reload extensions"))
    None -> {
      let previous = runtime.peek_prompt(state.host, state.info.id)
      let #(previous_tools, saved) = case state.kernel {
        Some(kernel) -> #(
          Some(runtime.tools(kernel)),
          session_namespace.save_state_within(
            state.home,
            state.info.id,
            kernel,
            session_namespace.close_state_timeout,
          ),
        )
        None -> #(None, Error("no active python namespace"))
      }
      case
        runtime.change_extension(
          state.host,
          state.info.id,
          state.info.cwd,
          change,
        )
      {
        Error(error) -> #(state, Error(error))
        // A recorded choice that did not change the running extension set.
        Ok(None) -> #(
          state,
          runtime.extension_summaries(state.host, state.info.id),
        )
        Ok(Some(kernel)) -> {
          let restored = case
            saved,
            session_namespace.state_path(state.home, state.info.id)
          {
            Ok(_), Some(path) ->
              runtime.load_state(kernel, path, session_namespace.state_timeout)
            _, _ -> Error(python.Invalid("namespace snapshot unavailable"))
          }
          let namespace = case state.kernel, restored {
            None, _ -> "new python namespace started"
            _, Ok(saved) -> session_namespace.restored_text(saved)
            _, Error(_) -> "python namespace reset; unsaved variables were lost"
          }
          let state = with_kernel(state, kernel)
          let state = case previous_tools == Some(runtime.tools(kernel)) {
            True ->
              case session_prompt.pin_changed_prompt(state, previous) {
                Ok(#(state, detail)) ->
                  session_state.emit(
                    state,
                    view.note(
                      "daemon",
                      "extensions reloaded; " <> namespace <> detail,
                    ),
                  )
                Error(error) ->
                  session_prompt.reset_prompt_cache(state, namespace)
                  |> session_state.emit(view.error(
                    "extensions reloaded but the capability notice could not be saved: "
                    <> error,
                  ))
              }
            False -> session_prompt.reset_prompt_cache(state, namespace)
          }
          #(
            session_prompt.remember_prompt(state),
            runtime.extension_summaries(state.host, state.info.id),
          )
        }
      }
    }
  }
}

pub type Reloaded {
  Reloaded(loaded_revision: Option(String), warnings: List(String))
}

/// Apply persisted choices and fresh file discovery. Kernel replacement is
/// complete before success; failures retain the previously loaded composition.
pub fn reload(
  state: session_state.State(message),
  reason: String,
) -> #(session_state.State(message), Result(Reloaded, String)) {
  case turn.running(state.activity) != None || state.booting != None {
    True -> #(state, Error("session must be idle to reload"))
    False -> {
      let previous = runtime.peek_prompt(state.host, state.info.id)
      let previous_tools = option.map(state.kernel, runtime.tools)
      case runtime.reload_desired(state.host, state.info.id, state.info.cwd) {
        Error(error) -> #(state, Error(error))
        Ok(kernel) -> {
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
          let warnings =
            list.append(warnings, case kernel {
              Some(kernel) -> runtime.warnings(kernel)
              None -> []
            })
          case
            runtime.observe_composition(state.host, state.home, state.info.id)
          {
            Error(error) -> #(state, Error(error))
            Ok(observed) -> #(
              reloaded(state),
              Ok(Reloaded(observed.loaded_revision, warnings)),
            )
          }
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
