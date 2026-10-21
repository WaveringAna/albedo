//// `albedo/clock` owns Gleam clock access (robot-docs/runtime.md, "clocks").

import albedo_lint/index.{type Index}
import glance
import gleam/list
import gleam/string
import glinter/rule

const time_modules = ["erlang", "os", "calendar"]

const time_functions = [
  "system_time", "monotonic_time", "timestamp", "universaltime", "local_time",
  "now", "time", "localtime_to_universaltime", "universaltime_to_localtime",
]

pub fn rule(index: Index) -> rule.Rule {
  let checked =
    rule.new(name: "albedo_clock")
    |> rule.with_simple_import_visitor(visitor: on_import)
    |> rule.with_simple_function_visitor(visitor: on_function)
  rule.module_rule_from_fn(
    name: "albedo_clock",
    default_severity: rule.Warning,
    run: fn(module, source) {
      let path = index.path_of(index, source)
      case
        path == "src/albedo/clock.gleam" || !string.starts_with(path, "src/")
      {
        True -> []
        False -> rule.visit_module(module:, schema: checked, source:).0
      }
    },
  )
}

fn on_import(
  definition: glance.Definition(glance.Import),
) -> List(rule.RuleError) {
  case definition.definition.module {
    "gleam/time/timestamp" -> [
      rule.error(
        message: "gleam/time/timestamp reads a clock",
        details: "Use albedo/clock: system_ms or system_seconds for stored times, monotonic_ms for elapsed time and deadlines.",
        location: definition.definition.location,
      ),
    ]
    _ -> []
  }
}

fn on_function(
  definition: glance.Definition(glance.Function),
  span: glance.Span,
) -> List(rule.RuleError) {
  list.filter_map(definition.attributes, fn(attribute) {
    case attribute {
      glance.Attribute(
        "external",
        [_, glance.String(_, module), glance.String(_, function)],
      ) ->
        case
          list.contains(time_modules, module)
          && list.contains(time_functions, function)
        {
          True ->
            Ok(rule.error(
              message: module <> ":" <> function <> " is a clock external",
              details: "Use albedo/clock instead of declaring another clock external; native time units depend on the VM.",
              location: span,
            ))
          False -> Error(Nil)
        }
      _ -> Error(Nil)
    }
  })
}
