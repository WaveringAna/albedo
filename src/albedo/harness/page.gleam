//// Sidebar rows and shared text-command argument parsing.

import gleam/dict.{type Dict}
import gleam/result
import gleam/string

/// Extracts action and details from command arguments, using default_action
/// when action is omitted.
pub fn args(
  args: Dict(String, String),
  default_action: String,
) -> #(String, String) {
  let action = dict.get(args, "action") |> result.unwrap(default_action)
  let details = dict.get(args, "details") |> result.unwrap("") |> string.trim
  #(action, details)
}

/// Splits a string at the first space into the first token and the remainder.
pub fn split(text: String) -> #(String, String) {
  string.split_once(text, " ") |> result.unwrap(#(text, ""))
}

pub type Tone {
  Plain
  /// In progress or turned on.
  Active
  /// Needs attention.
  Warning
  /// Finished, disabled, or otherwise out of the way.
  Muted
}

pub type Row {
  Row(
    id: String,
    /// The short title a list shows on one line.
    text: String,
    badge: String,
    tone: Tone,
    /// The full text a client shows for the selected row, where `text` is
    /// the short title. Empty when the row has nothing more to show.
    detail: String,
  )
}

/// A few rows for a client's sidebar, beside the conversation.
pub type Glance {
  Glance(title: String, rows: List(Row))
}
