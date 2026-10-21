//// A table created by an extension is read and written only by that
//// extension (robot-docs/extensions.md: an extension owns its tables).
//// Tables of the daemon's core are shared and not checked.

import albedo_lint/index.{type Index}
import glance
import gleam/dict
import gleam/list
import gleam/string
import glinter/rule

const statements = ["from ", "join ", "into ", "update ", "references "]

pub fn rule(index: Index) -> rule.Rule {
  rule.module_rule_from_fn(
    name: "albedo_table_ownership",
    default_severity: rule.Warning,
    run: fn(module, source) {
      let path = index.path_of(index, source)
      case string.starts_with(path, "src/") {
        False -> []
        True -> {
          let checked =
            rule.new(name: "albedo_table_ownership")
            |> rule.with_simple_expression_visitor(
              visitor: fn(expression, span) {
                on_expression(index, path, expression, span)
              },
            )
          list.append(
            rule.visit_module(module:, schema: checked, source:).0,
            list.flat_map(module.constants, fn(constant) {
              check_constant(index, path, constant.definition.value)
            }),
          )
        }
      }
    },
  )
}

fn on_expression(
  index: Index,
  path: String,
  expression: glance.Expression,
  span: glance.Span,
) -> List(rule.RuleError) {
  case expression {
    glance.String(_, text) -> {
      let sql = string.lowercase(text) |> string.replace("\n", " ")
      dict.to_list(index.table_owners)
      |> list.filter(fn(table) { index.extension_of(path) != Ok(table.1) })
      |> list.filter(fn(table) { names_table(sql, table.0) })
      |> list.map(fn(table) {
        rule.error(
          message: table.0 <> " belongs to the " <> table.1 <> " extension",
          details: "Go through a function of the "
            <> table.1
            <> " extension that owns the table; the daemon only collects extension tables.",
          location: span,
        )
      })
    }
    _ -> []
  }
}

/// Constants hold SQL too, and a visitor only walks function bodies.
fn check_constant(
  index: Index,
  path: String,
  value: glance.Expression,
) -> List(rule.RuleError) {
  case value {
    glance.String(location, _) -> on_expression(index, path, value, location)
    glance.BinaryOperator(_, glance.Concatenate, left, right) ->
      list.append(
        check_constant(index, path, left),
        check_constant(index, path, right),
      )
    glance.List(_, elements, _) ->
      list.flat_map(elements, check_constant(index, path, _))
    _ -> []
  }
}

/// Whether the SQL reads or writes the table after a statement keyword.
fn names_table(sql: String, table: String) -> Bool {
  list.any(statements, fn(keyword) {
    case string.split(sql, keyword) {
      [_, ..after] ->
        list.any(after, fn(piece) {
          index.identifier(string.trim_start(piece)) == table
        })
      [] -> False
    }
  })
}
