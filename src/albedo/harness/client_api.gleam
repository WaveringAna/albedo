//// Declarative client operations contributed by an extension. These values
//// describe resource requests; they never invoke a model command.

import gleam/http
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}

pub type Binding {
  Literal(json.Json)
  Session(pointer: String)
  Row(pointer: String)
  Form(pointer: String)
}

pub type Delivery {
  Read
  Mutation
}

pub type Field {
  Field(
    name: String,
    label: String,
    kind: String,
    required: Bool,
    default: json.Json,
    choices: List(#(json.Json, String)),
    description: String,
    default_binding: Option(Binding),
  )
}

pub type Operation {
  Operation(
    id: String,
    method: http.Method,
    path_template: String,
    path: List(#(String, Binding)),
    query: List(#(String, Binding)),
    headers: List(#(String, Binding)),
    body: List(#(String, Binding)),
    result_schema: json.Json,
    success_status: Option(Int),
  )
}

pub type Command {
  Command(
    slash_name: String,
    delivery: Delivery,
    arguments: List(Field),
    operation: Operation,
  )
}

/// A human action offered by a resource page.
pub type Action {
  Action(
    id: String,
    label: String,
    // The key chord the TUI binds to the action, spelled as it names keys
    // ("ctrl+o"); empty leaves it to the actions menu. Never a bare letter:
    // every list screen's search box takes those.
    keyboard_hint: String,
    confirmation: Option(String),
    fields: List(Field),
    operation: Operation,
  )
}

pub fn action(value: Action) -> json.Json {
  json.object([
    #("id", json.string(value.id)),
    #("label", json.string(value.label)),
    #("keyboard_hint", json.string(value.keyboard_hint)),
    #("confirmation", json.nullable(value.confirmation, json.string)),
    #("fields", json.array(value.fields, field)),
    #("operation", operation(value.operation)),
  ])
}

/// Bind each named form input to its matching request-body property.
pub fn form_body(names: List(String)) -> List(#(String, Binding)) {
  list.map(names, fn(name) { #("/" <> name, Form("/" <> name)) })
}

pub fn binding(binding: Binding) -> json.Json {
  case binding {
    Literal(value) ->
      json.object([#("source", json.string("literal")), #("value", value)])
    Session(pointer) ->
      json.object([
        #("source", json.string("session")),
        #("pointer", json.string(pointer)),
      ])
    Row(pointer) ->
      json.object([
        #("source", json.string("row")),
        #("pointer", json.string(pointer)),
      ])
    Form(pointer) ->
      json.object([
        #("source", json.string("form")),
        #("pointer", json.string(pointer)),
      ])
  }
}

pub fn operation(operation: Operation) -> json.Json {
  let bindings = fn(items: List(#(String, Binding))) {
    json.object(list.map(items, fn(item) { #(item.0, binding(item.1)) }))
  }
  json.object([
    #("operation_id", json.string(operation.id)),
    #("method", json.string(http.method_to_string(operation.method))),
    #("path_template", json.string(operation.path_template)),
    #("path", bindings(operation.path)),
    #("query", bindings(operation.query)),
    #("headers", bindings(operation.headers)),
    #("body", bindings(operation.body)),
    #("result_schema", operation.result_schema),
    ..case operation.success_status {
      None -> []
      Some(status) -> [#("success_status", json.int(status))]
    }
  ])
}

pub fn field(field: Field) -> json.Json {
  json.object([
    #("name", json.string(field.name)),
    #("label", json.string(field.label)),
    #("type", json.string(field.kind)),
    #("required", json.bool(field.required)),
    #("default", field.default),
    #(
      "choices",
      json.array(field.choices, fn(choice) {
        json.object([#("value", choice.0), #("label", json.string(choice.1))])
      }),
    ),
    #("minimum", json.null()),
    #("maximum", json.null()),
    #("description", json.string(field.description)),
    ..case field.default_binding {
      None -> []
      Some(value) -> [#("default_binding", binding(value))]
    }
  ])
}

/// A resource page keeps extension-specific resource bodies explicit.
pub type PageRow {
  PageRow(
    id: String,
    text: String,
    badge: Option(String),
    tone: String,
    detail: Option(String),
    resource: json.Json,
  )
}

pub type Page {
  Page(
    title: String,
    summary: String,
    empty_state: String,
    glance: Option(json.Json),
    actions: List(Action),
    rows: List(PageRow),
  )
}

pub fn page(value: Page) -> json.Json {
  json.object([
    #("title", json.string(value.title)),
    #("summary", json.string(value.summary)),
    #("empty_state", json.string(value.empty_state)),
    #("glance", json.nullable(value.glance, fn(value) { value })),
    #("actions", json.array(value.actions, action)),
    #(
      "rows",
      json.array(value.rows, fn(row) {
        json.object([
          #("id", json.string(row.id)),
          #("text", json.string(row.text)),
          #("badge", json.nullable(row.badge, json.string)),
          #("tone", json.string(row.tone)),
          #("detail", json.nullable(row.detail, json.string)),
          #("resource", row.resource),
        ])
      }),
    ),
  ])
}

/// Standard field defaults; callers can update labels, bindings, or choices.
pub fn text_field(name: String, required: Bool) -> Field {
  Field(name, name, "text", required, json.null(), [], "", None)
}

pub fn integer_field(name: String, required: Bool) -> Field {
  Field(..text_field(name, required), kind: "integer")
}

pub fn choice_field(
  name: String,
  required: Bool,
  choices: List(String),
) -> Field {
  Field(
    ..text_field(name, required),
    kind: "choice",
    choices: list.map(choices, fn(value) { #(json.string(value), value) }),
  )
}

/// An operation with no bindings or result constraints.
pub fn operation_defaults(
  id: String,
  method: http.Method,
  path_template: String,
  success_status: Int,
) -> Operation {
  Operation(
    id,
    method,
    path_template,
    [],
    [],
    [],
    [],
    json.object([]),
    Some(success_status),
  )
}
