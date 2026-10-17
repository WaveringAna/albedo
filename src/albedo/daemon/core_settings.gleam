//// The sections of extensions.json the daemon declares itself. They are
//// listed, checked and saved beside what installed extensions declare, and
//// no extension may take their names.

import albedo/daemon/family
import albedo/harness/settings
import albedo/harness/settings/declared
import gleam/list

pub fn declared() -> List(declared.Declared) {
  [
    declared.Declared(
      "How many agents a session may keep open, and how deep they may nest.",
      settings.declaration(family.limits_section()),
    ),
  ]
}

/// The section names the daemon owns.
pub fn names() -> List(String) {
  list.map(declared(), fn(entry) { entry.declaration.section })
}
