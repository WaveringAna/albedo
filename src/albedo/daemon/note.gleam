//// Notes the daemon tells the model, stored as user messages. The origin rides
//// in the tag, so a reloaded transcript can label a note the way the live
//// stream did.

import gleam/option.{type Option, None, Some}
import gleam/string

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

/// The origin and body of a note. An untagged note comes from "note".
pub fn parse(text: String) -> Option(#(String, String)) {
  case string.ends_with(text, close) {
    False -> None
    True ->
      case string.split_once(string.drop_end(text, string.length(close)), ">") {
        Ok(#("<system-note", body)) -> Some(#("note", body))
        Ok(#("<system-note origin=\"" <> origin, body)) ->
          case string.ends_with(origin, "\"") {
            True -> Some(#(string.drop_end(origin, 1), body))
            False -> None
          }
        _ -> None
      }
  }
}
