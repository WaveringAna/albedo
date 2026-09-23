//// An extension's own screen, described as data. A page command (a command
//// with `page: True`) answers one `Document` when run without arguments; a
//// client renders it and runs each action as the same command with
//// `action` = the action's `run` and `details` = the selected row's id (for
//// row actions) followed by the entered text or chosen option, separated by a
//// space. The client re-runs the page command afterwards, so the document is
//// always rebuilt from the extension's own state rather than patched locally.

import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}

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
  Row(id: String, text: String, badge: String, tone: Tone)
}

pub type Input {
  NoInput
  /// Free text. `prefill` starts the field with the selected row's text.
  Text(prompt: String, prefill: Bool)
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

pub type Document {
  Document(
    title: String,
    summary: String,
    /// Shown instead of rows when there are none.
    empty: String,
    rows: List(Row),
    actions: List(Action),
    glance: Option(Glance),
  )
}

pub fn to_json(document: Document) -> json.Json {
  json.object([
    #(
      "page",
      json.object([
        #("title", json.string(document.title)),
        #("summary", json.string(document.summary)),
        #("empty", json.string(document.empty)),
        #("rows", json.array(document.rows, row_json)),
        #("actions", json.array(document.actions, action_json)),
        #("glance", case document.glance {
          None -> json.null()
          Some(glance) ->
            json.object([
              #("title", json.string(glance.title)),
              #("rows", json.array(glance.rows, row_json)),
            ])
        }),
      ]),
    ),
  ])
}

fn row_json(row: Row) -> json.Json {
  json.object([
    #("id", json.string(row.id)),
    #("text", json.string(row.text)),
    #("badge", json.string(row.badge)),
    #(
      "tone",
      json.string(case row.tone {
        Plain -> "plain"
        Active -> "active"
        Warning -> "warning"
        Muted -> "muted"
      }),
    ),
  ])
}

fn action_json(action: Action) -> json.Json {
  let input = case action.input {
    NoInput -> [#("input", json.string("none"))]
    Text(prompt, prefill) -> [
      #("input", json.string("text")),
      #("prompt", json.string(prompt)),
      #("prefill", json.bool(prefill)),
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
