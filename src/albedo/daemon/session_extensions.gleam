//// Reconfigure a session's extensions without losing its prompt or namespace.

import albedo/daemon/events as view
import albedo/daemon/session_namespace
import albedo/daemon/session_prompt
import albedo/daemon/session_state
import albedo/daemon/turn
import albedo/harness/extension
import albedo/harness/extensions/python/kernel as python
import albedo/harness/runtime
import gleam/json
import gleam/option.{None, Some}

pub fn change(
  state: session_state.State(message),
  change: extension.Change,
) -> #(session_state.State(message), Result(List(extension.Summary), String)) {
  case turn.running(state.activity) {
    Some(_) -> #(state, Error("session must be idle to reload extensions"))
    None -> {
      let previous = runtime.peek_prompt(state.host, state.info.id)
      let previous_tools = case state.kernel {
        Some(kernel) -> Some(runtime.tools(kernel))
        None -> None
      }
      let saved = case state.kernel {
        Some(kernel) ->
          session_namespace.save_state_within(
            state.home,
            state.info.id,
            kernel,
            session_namespace.close_state_timeout,
          )
        None -> Error("no active python namespace")
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
          let state =
            session_state.State(
              ..state,
              kernel: Some(kernel),
              context: session_state.unprepared(),
            )
          let state = case previous_tools == Some(runtime.tools(kernel)) {
            True ->
              case session_prompt.pin_changed_prompt(state, previous) {
                Ok(#(state, detail)) ->
                  session_state.emit(
                    state,
                    view.text(
                      "note",
                      "extensions reloaded; " <> namespace <> detail,
                    ),
                  )
                Error(error) ->
                  session_prompt.reset_prompt_cache(state, namespace)
                  |> session_state.emit(view.text(
                    "error",
                    "extensions reloaded but the capability notice could not be saved: "
                      <> error,
                  ))
              }
            False -> session_prompt.reset_prompt_cache(state, namespace)
          }
          #(state, runtime.extension_summaries(state.host, state.info.id))
        }
      }
    }
  }
}

pub fn refresh(
  state: session_state.State(message),
) -> #(session_state.State(message), Result(json.Json, String)) {
  case turn.running(state.activity) {
    Some(_) -> #(state, Error("session must be idle to reload"))
    None -> {
      let previous = runtime.peek_prompt(state.host, state.info.id)
      case runtime.refresh_session(state.host, state.info.id) {
        Error(error) -> #(state, Error(error))
        Ok(update) -> {
          let state = case update {
            Some(kernel) ->
              session_state.State(
                ..state,
                kernel: Some(kernel),
                context: session_state.unprepared(),
              )
            None -> state
          }
          case session_prompt.pin_changed_prompt(state, previous) {
            Ok(#(state, detail)) -> #(
              session_state.emit(
                state,
                view.text("note", "session data reloaded from disk" <> detail),
              ),
              Ok(
                json.object([
                  #("reloaded", json.string("session")),
                  #(
                    "message",
                    json.string(
                      "Extension context, skills catalog, and session commands rescanned from disk."
                      <> detail,
                    ),
                  ),
                ]),
              ),
            )
            Error(error) -> #(
              session_prompt.reset_prompt_cache(
                state,
                "session data reloaded from disk",
              ),
              Error(
                "session data reloaded, but its capability notice could not be saved: "
                <> error,
              ),
            )
          }
        }
      }
    }
  }
}
