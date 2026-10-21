//// Previews and names are cut with `text_scalars`, not with the grapheme
//// functions of `gleam/string` (robot-docs/runtime.md, "Unicode scalar limits").

import albedo_lint/index.{type Index}
import glance
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import glinter/rule

const grapheme_functions = ["length", "slice", "drop_start", "drop_end"]

pub fn rule(index: Index) -> rule.Rule {
  let checked =
    rule.new_with_context(name: "albedo_text_scalars", initial: None)
    |> rule.with_import_visitor(visitor: on_import)
    |> rule.with_expression_enter_visitor(visitor: on_expression)
  rule.module_rule_from_fn(
    name: "albedo_text_scalars",
    default_severity: rule.Warning,
    run: fn(module, source) {
      let path = index.path_of(index, source)
      case
        path == "src/albedo/text_scalars.gleam"
        || !string.starts_with(path, "src/")
      {
        True -> []
        False -> rule.visit_module(module:, schema: checked, source:).0
      }
    },
  )
}

/// The name `gleam/string` goes by in the module, once imported.
fn on_import(
  definition: glance.Definition(glance.Import),
  alias: Option(String),
) -> #(List(rule.RuleError), Option(String)) {
  let glance.Definition(definition: import_, ..) = definition
  case import_.module {
    "gleam/string" -> #([], Some(imported_name(import_)))
    _ -> #([], alias)
  }
}

fn imported_name(import_: glance.Import) -> String {
  case import_.alias {
    Some(glance.Named(name)) -> name
    _ -> "string"
  }
}

fn on_expression(
  expression: glance.Expression,
  span: glance.Span,
  alias: Option(String),
) -> #(List(rule.RuleError), Option(String)) {
  case expression, alias {
    glance.FieldAccess(_, glance.Variable(_, module), function), Some(name)
      if module == name
    ->
      case list.contains(grapheme_functions, function) {
        True -> #(
          [
            rule.error(
              message: "string." <> function <> " counts graphemes",
              details: "Use text_scalars.length, take, drop or tail for previews and names; they count Unicode scalars and release the source binary.",
              location: span,
            ),
          ],
          alias,
        )
        False -> #([], alias)
      }
    _, _ -> #([], alias)
  }
}
