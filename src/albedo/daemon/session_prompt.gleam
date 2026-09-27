//// Cache accounting when a session prompt changes.

import albedo/daemon/conversation
import albedo/daemon/events as view
import albedo/daemon/note
import albedo/daemon/session_history
import albedo/daemon/session_state
import albedo/harness/loop
import albedo/harness/runtime
import albedo/openai_api/types
import gleam/option.{type Option, None, Some}
import gleam/result

/// A changed prompt invalidates the provider's cached prefix, so the next
/// request uses the current prompt: any pin is released and cached-usage
/// metadata, which described the old prefix, is cleared.
pub fn reset_prompt_cache(
  state: session_state.State(message),
  namespace: String,
) -> session_state.State(message) {
  let ledger = runtime.ledger(state.host)
  let released = case state.pin {
    loop.Pinned(..) -> conversation.clear_prompt_pin(ledger, state.info.id)
    loop.Unpinned -> Ok(Nil)
  }
  let state = case released {
    Ok(_) ->
      session_state.State(
        ..state,
        pin: loop.Unpinned,
        prepared_head: None,
        latest_usage: None,
      )
    Error(_) ->
      session_state.State(..state, prepared_head: None, latest_usage: None)
  }
  let state =
    session_state.emit(
      state,
      view.text(
        "note",
        "extensions reloaded; prompt cache usage reset; " <> namespace,
      ),
    )
  case released, conversation.clear_usage(ledger, state.info.id) {
    Ok(_), Ok(_) -> state
    Error(error), _ | _, Error(error) ->
      session_state.emit(
        state,
        view.text(
          "error",
          "extensions reloaded but the previous prompt cache state could not be cleared: "
            <> error,
        ),
      )
  }
}

/// Keep the provider's cached system prefix across a live context change.
/// Only a small discovery notice enters history; the full new catalog and
/// workspace context move into the system prompt when compaction replaces history.
pub fn pin_changed_prompt(
  state: session_state.State(message),
  previous: Option(#(String, List(types.Input))),
) -> Result(#(session_state.State(message), String), String) {
  let current = runtime.peek_prompt(state.host, state.info.id)
  case previous, current {
    Some(#(old_instructions, old_context)), Some(#(instructions, context))
      if old_instructions != instructions || old_context != context
    -> {
      use state <- result.try(session_history.ensure_history(state))
      case state.history {
        Some([_, ..]) -> {
          let #(pinned, head) = case state.pin {
            loop.Pinned(prompt, head) -> #(prompt, head)
            loop.Unpinned -> #(
              conversation.PinnedPrompt(old_instructions, old_context),
              state.prepared_head,
            )
          }
          let baseline = case head {
            Some(head) -> head
            None -> 0
          }
          let update =
            note.wrap(
              "capabilities changed",
              "\nSession capabilities changed. The cached system prompt remains in use until compaction. "
                <> "Call commands.catalog() to discover current commands and skills; "
                <> "tool schemas reflect currently enabled tools.\n",
            )
          use timestamp <- result.try(conversation.append_capability_update(
            runtime.ledger(state.host),
            state.info.id,
            pinned,
            baseline,
            update,
          ))
          let state =
            session_history.remember(state, [types.User(update)], timestamp)
          Ok(#(
            session_state.State(
              ..state,
              pin: loop.Pinned(pinned, Some(baseline)),
            ),
            "; the cached system prompt remains until compaction",
          ))
        }
        _ -> Ok(#(state, ""))
      }
    }
    _, _ -> Ok(#(state, ""))
  }
}
