//// Sidebar rows and text-command page envelopes. Extensions build their
//// presentation once as a client_api.Page. The legacy adapter keeps the
//// command envelope and action/details syntax around that same presentation.

import albedo/harness/client_api
import gleam/dict.{type Dict}
import gleam/json
import gleam/list
import gleam/option
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

pub fn detail_row(
  id: String,
  text: String,
  badge: String,
  tone: Tone,
  detail: String,
) -> Row {
  Row(id, text, badge, tone, detail)
}

pub type Input {
  NoInput
  /// Free text. `prefill` starts the field with the selected row's text.
  Text(prompt: String, prefill: Bool)
  /// Sensitive input is masked in the client and never echoed into the page.
  Secret(prompt: String)
  Choice(options: List(String))
  /// A preset value, so one key applies it: "done", "on", "off".
  Value(String)
}

pub type Action {
  Action(
    key: String,
    label: String,
    run: String,
    on_row: Bool,
    input: Input,
    confirm: Bool,
  )
}

/// A few rows for a client's sidebar, beside the conversation.
pub type Glance {
  Glance(title: String, rows: List(Row))
}

fn action_json(action: Action) -> json.Json {
  let input = case action.input {
    NoInput -> [#("input", json.string("none"))]
    Text(prompt, prefill) -> [
      #("input", json.string("text")),
      #("prompt", json.string(prompt)),
      #("prefill", json.bool(prefill)),
    ]
    Secret(prompt) -> [
      #("input", json.string("secret")),
      #("prompt", json.string(prompt)),
    ]
    Choice(options) -> [
      #("input", json.string("choice")),
      #("options", json.array(options, json.string)),
    ]
    Value(value) -> [
      #("input", json.string("value")),
      #("value", json.string(value)),
    ]
  }
  json.object(list.append(
    [
      #("key", json.string(action.key)),
      #("label", json.string(action.label)),
      #("run", json.string(action.run)),
      #("row", json.bool(action.on_row)),
      #("confirm", json.bool(action.confirm)),
    ],
    input,
  ))
}

/// Preserve the command document envelope around the canonical HTTP page.
/// Text command actions retain their own argument syntax.
pub fn legacy(document: client_api.Page, actions: List(Action)) -> json.Json {
  json.object([
    #(
      "page",
      json.object([
        #("title", json.string(document.title)),
        #("summary", json.string(document.summary)),
        #("empty", json.string(document.empty_state)),
        #(
          "rows",
          json.array(document.rows, fn(row) {
            json.object([
              #("id", json.string(row.id)),
              #("text", json.string(row.text)),
              #("badge", json.string(option.unwrap(row.badge, ""))),
              #("tone", json.string(row.tone)),
              #("detail", json.string(option.unwrap(row.detail, ""))),
            ])
          }),
        ),
        #("actions", json.array(actions, action_json)),
        #("glance", json.nullable(document.glance, fn(value) { value })),
      ]),
    ),
  ])
}
