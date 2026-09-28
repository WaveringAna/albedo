//// Shared workspace instruction discovery and UTF-8 loading.

import gleam/option.{type Option}

pub type Selection {
  First
  All
}

/// Project root, project .agents/, project .albedo/, then the two home
/// directories, in that order. `First` selects the highest-priority match;
/// `All` concatenates matches. Missing files return `None`. Named prompt files
/// have no size limit; ordinary instruction files retain their 1 MiB limit.
pub fn named(
  workspace: String,
  home: String,
  name: String,
  selection: Selection,
) -> Result(Option(String), String) {
  native_named(workspace, home, name, selection)
}

@external(erlang, "albedo_instruction_files", "named")
fn native_named(
  workspace: String,
  home: String,
  name: String,
  selection: Selection,
) -> Result(Option(String), String)

@external(erlang, "albedo_instruction_files", "home")
pub fn home() -> String

/// Autoloaded AGENTS.md, CLAUDE.md, and agent-directory Markdown other than prompt files.
/// Files larger than 1 MiB are skipped.
@external(erlang, "albedo_instruction_files", "load")
pub fn load(workspace: String, home: String) -> Result(String, String)

/// The selected files' context and any warnings about skipped files.
@external(erlang, "albedo_instruction_files", "load_selected")
pub fn load_selected(
  workspace: String,
  home: String,
  session: String,
) -> Result(#(String, List(String)), String)
