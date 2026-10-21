//// glinter with albedo's own rules. `test/gleam-lint.sh --albedo` runs it
//// against the checkout; the rules are configured in the root gleam.toml
//// next to the built-in ones.

import albedo_lint/index
import albedo_lint/rules/clock
import albedo_lint/rules/table_ownership
import albedo_lint/rules/text_scalars
import argv
import glinter

pub fn main() -> Nil {
  let index = index.build(project_root(argv.load().arguments))
  glinter.run(extra_rules: [
    text_scalars.rule(index),
    clock.rule(index),
    table_ownership.rule(index),
  ])
}

fn project_root(arguments: List(String)) -> String {
  case arguments {
    ["--project", directory, ..] -> directory
    [_, ..rest] -> project_root(rest)
    [] -> "."
  }
}
