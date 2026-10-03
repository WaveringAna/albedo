//// Cache accounting when a session prompt changes.

import albedo/daemon/conversation
import albedo/daemon/events as view
import albedo/daemon/note
import albedo/daemon/session_history
import albedo/daemon/session_state
import albedo/harness/loop
import albedo/harness/runtime
import albedo/openai_api/types
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

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
  // A failed release keeps the pin; the metadata it described is stale either way.
  let pin = case released {
    Ok(_) -> loop.Unpinned
    Error(_) -> state.pin
  }
  let state =
    session_state.State(
      ..state,
      pin: pin,
      prepared_head: None,
      latest_usage: None,
    )
  let state =
    session_state.emit(
      state,
      view.note(
        "daemon",
        "extensions reloaded; prompt cache usage reset; " <> namespace,
      ),
    )
  case released, conversation.clear_usage(ledger, state.info.id) {
    Ok(_), Ok(_) -> state
    Error(error), _ | _, Error(error) ->
      session_state.emit(
        state,
        view.error(
          "extensions reloaded but the previous prompt cache state could not be cleared: "
          <> error,
        ),
      )
  }
}

/// A changed tool set uses the current prompt instead of pinning an
/// incompatible prefix. Record the actual adoption in durable history too.
pub fn record_capability_change(
  state: session_state.State(message),
  reason: String,
) -> Result(session_state.State(message), String) {
  let update =
    note.wrap(
      "capabilities changed",
      "Session capabilities changed. "
        <> reason
        <> ". The session's tool capabilities were reloaded.\n"
        <> "Call commands.catalog() for the current command and skill catalog.",
    )
  use timestamp <- result.try(conversation.commit(
    runtime.ledger(state.host),
    state.info.id,
    [types.User(update)],
    conversation.Idle,
  ))
  Ok(session_history.remember(state, [types.User(update)], timestamp))
}

fn context_blocks(context: List(types.Input)) -> List(#(String, String)) {
  list.filter_map(context, fn(input) {
    case input {
      types.User(text) -> {
        use rest <- result.try(string.split_once(
          text,
          "<extension-context name=\"",
        ))
        use named <- result.try(string.split_once(rest.1, "\""))
        Ok(#(named.0, text))
      }
      _ -> Error(Nil)
    }
  })
}

fn context_changes(
  previous: List(types.Input),
  current: List(types.Input),
) -> String {
  let before = context_blocks(previous)
  let after = context_blocks(current)
  let replaced =
    after
    |> list.filter(fn(block) { !list.contains(before, block) })
    |> list.map(fn(block) {
      "Current context for "
      <> block.0
      <> " (supersedes any earlier version):\n"
      <> block.1
    })
  let names = list.map(after, fn(block) { block.0 })
  let removed =
    before
    |> list.filter(fn(block) { !list.contains(names, block.0) })
    |> list.map(fn(block) {
      "Context removed: "
      <> block.0
      <> ". Its earlier instructions and catalog no longer apply."
    })
  let appendix = fn(context) {
    list.filter_map(context, fn(input) {
      case input {
        types.User(text) ->
          case string.starts_with(text, "<extension-context name=\"") {
            True -> Error(Nil)
            False -> Ok(text)
          }
        _ -> Error(Nil)
      }
    })
  }
  let before_append = appendix(previous)
  let after_append = appendix(current)
  let append_change = case before_append == after_append {
    True -> []
    False ->
      case after_append {
        [] -> ["APPEND_SYSTEM.md no longer applies."]
        _ -> [
          "Current APPEND_SYSTEM.md (supersedes earlier contents):\n"
          <> string.join(after_append, "\n\n"),
        ]
      }
  }
  list.append(list.append(replaced, removed), append_change)
  |> string.join("\n\n")
}

fn changes(previous: String, current: String) -> String {
  case previous == current {
    True -> ""
    False ->
      "Current system instructions (supersede earlier system instructions):\n"
      <> current
      <> "\n\n"
  }
}

/// Pin the old prompt until compaction, while reporting live capability changes.
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
          let baseline = option.unwrap(head, 0)
          let update =
            note.wrap(
              "capabilities changed",
              "\nSession capabilities changed. The cached system prompt remains in use until compaction.\n"
                <> changes(old_instructions, instructions)
                <> context_changes(old_context, context)
                <> "\nCall commands.catalog() for the current command and skill catalog.\n",
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
