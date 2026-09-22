//// Autoload project conventions and user preferences from common agent instruction files.

import albedo/harness/extension as harness_extension

pub fn extension() -> harness_extension.Extension {
  extension_at(native_home())
}

/// Explicit home keeps tests and embedders isolated from the process environment.
pub fn extension_at(home: String) -> harness_extension.Extension {
  harness_extension.Extension(
    "instructions",
    "Autoload AGENTS.md, CLAUDE.md, and Markdown instructions from project and user agent directories.",
    [],
    [
      harness_extension.ContextPlugin(fn(workspace) { load_at(workspace, home) }),
    ],
    fn(_) { Ok(Nil) },
  )
}

pub fn load_at(workspace: String, home: String) -> Result(String, String) {
  native_load(workspace, home)
}

@external(erlang, "albedo_instructions", "home")
fn native_home() -> String

@external(erlang, "albedo_instructions", "load")
fn native_load(workspace: String, home: String) -> Result(String, String)
