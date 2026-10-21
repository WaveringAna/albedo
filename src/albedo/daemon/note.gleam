//// Notes the daemon tells the model, stored as user messages. The origin rides
//// in the tag, so a reloaded transcript can label a note the way the live
//// stream did.

import albedo/text_scalars
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

const open = "<system-note"

const close = "</system-note>"

/// `text` as a note from `origin`. Text that is already a note keeps its tag.
pub fn wrap(origin: String, text: String) -> String {
  case parse(text) {
    Some(_) -> text
    None ->
      "<system-note origin=\""
      <> origin |> string.replace("\"", "'") |> string.replace(">", ")")
      <> "\">"
      <> text
      <> close
  }
}

/// `text` without the note a kernel notice appended to it. Text that is only
/// a note comes back whole.
pub fn without_trailing(text: String) -> String {
  case string.ends_with(text, close), string.split(text, open) {
    True, [_, _, ..] as parts ->
      case list.take(parts, list.length(parts) - 1) |> string.join(open) {
        "" -> text
        body -> body
      }
    _, _ -> text
  }
}

/// The origin and body of a note. An untagged note comes from "note".
pub fn parse(text: String) -> Option(#(String, String)) {
  case string.ends_with(text, close) {
    False -> None
    True -> {
      let inner =
        text_scalars.take(
          text,
          text_scalars.length(text) - text_scalars.length(close),
        )
      case string.split_once(inner, ">") {
        Ok(#("<system-note", body)) -> Some(#("note", body))
        Ok(#("<system-note origin=\"" <> origin, body)) ->
          case string.ends_with(origin, "\"") {
            True ->
              Some(#(
                text_scalars.take(origin, text_scalars.length(origin) - 1),
                body,
              ))
            False -> None
          }
        _ -> None
      }
    }
  }
}
