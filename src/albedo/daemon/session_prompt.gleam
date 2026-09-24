//// Human-readable deltas for a pinned provider prompt after extension changes.

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

/// Describes only what changed between two prompt prefixes: instruction
/// paragraphs added or dropped, and context blocks added, changed, or removed.
pub fn context_update(
  old_instructions: String,
  old_context: List(types.Input),
  instructions: String,
  context: List(types.Input),
) -> String {
  let paragraphs = fn(text) {
    string.split(text, "\n")
    |> list.filter(fn(line) { string.trim(line) != "" })
  }
  let before = paragraphs(old_instructions)
  let after = paragraphs(instructions)
  let blocks = fn(inputs) {
    list.filter_map(inputs, fn(input) {
      case input {
        types.User(text) -> Ok(text)
        _ -> Error(Nil)
      }
    })
  }
  let old_blocks = blocks(old_context)
  let new_blocks = blocks(context)
  let new_names = list.map(new_blocks, block_name)
  let section = fn(title, items) {
    case items {
      [] -> []
      _ -> [title <> "\n" <> string.join(items, "\n")]
    }
  }
  [
    "[albedo] This session's extensions changed. Until the next compaction, "
      <> "the extension instructions and context earlier in this conversation "
      <> "are out of date; apply these changes to them.",
    ..list.flatten([
      section(
        "New or updated instructions:",
        list.filter(after, fn(line) { !list.contains(before, line) }),
      ),
      section(
        "No longer applies:",
        before
          |> list.filter(fn(line) { !list.contains(after, line) })
          |> list.map(fn(line) { "- " <> first_sentence(line) }),
      ),
      section(
        "New or updated context:",
        list.filter(new_blocks, fn(block) { !list.contains(old_blocks, block) }),
      ),
      section(
        "Removed context:",
        old_blocks
          |> list.map(block_name)
          |> list.filter(fn(name) {
            name != "" && !list.contains(new_names, name)
          })
          |> list.map(fn(name) { "- " <> name }),
      ),
    ])
  ]
  |> string.join("\n\n")
  |> fn(content) { note.wrap("context update", "\n" <> content <> "\n") }
}

/// The `name` of an `<extension-context name="...">` block, or "".
fn block_name(block: String) -> String {
  case string.split_once(block, "<extension-context name=\"") {
    Ok(#(_, rest)) ->
      case string.split_once(rest, "\"") {
        Ok(#(name, _)) -> name
        Error(_) -> ""
      }
    Error(_) -> ""
  }
}

fn first_sentence(line: String) -> String {
  case string.split_once(line, ". ") {
    Ok(#(sentence, _)) -> sentence <> "."
    Error(_) -> line
  }
}

/// A changed tool list invalidates the provider's cached prefix, so the next
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
      session_state.State(..state, pin: loop.Unpinned, latest_usage: None)
    Error(_) -> session_state.State(..state, latest_usage: None)
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

/// After a reload or extension toggle changed the session's prompt prefix (system instructions or
/// leading extension context), keep the prefix the provider has cached and
/// deliver the new one as a durable user turn. The pin lasts until compaction
/// rewrites history. Sessions without history have nothing cached and simply
/// use the new prompt.
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
              None,
            )
          }
          let update =
            context_update(old_instructions, old_context, instructions, context)
          use timestamp <- result.try(conversation.append_capability_update(
            runtime.ledger(state.host),
            state.info.id,
            pinned,
            update,
          ))
          let state =
            session_history.remember(state, [types.User(update)], timestamp)
          Ok(#(
            session_state.State(..state, pin: loop.Pinned(pinned, head)),
            "; the change reaches the model as a context update, and the system prompt is rebuilt at the next compaction",
          ))
        }
        _ -> Ok(#(state, ""))
      }
    }
    _, _ -> Ok(#(state, ""))
  }
}
