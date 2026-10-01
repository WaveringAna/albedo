//// Immutable Agent Skills catalog snapshots and on-demand activation.

import albedo/harness/project_files
import gleam/json
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string

pub type Skill {
  Skill(
    name: String,
    description: String,
    path: String,
    resolved_directory: String,
    resolved_source: String,
    selection_identity: String,
  )
}

pub type Catalog {
  Catalog(skills: List(Skill), diagnostics: List(String))
}

pub type Candidate {
  Candidate(
    id: String,
    name: Option(String),
    description: Option(String),
    source: String,
    resolved_source: Option(String),
    valid: Bool,
    diagnostic: Option(String),
    eligible: Bool,
    shadowed_by: Option(String),
  )
}

pub type Discovery {
  Discovery(
    candidates: List(Candidate),
    diagnostics: List(String),
    truncated: Bool,
    fingerprint: String,
  )
}

pub fn discover_at(
  workspace: String,
  home: String,
  builtin: String,
) -> Result(Discovery, String) {
  native_discover(workspace, home, builtin)
  |> result.map(fn(discovery) {
    Discovery(discovery.0, discovery.1, discovery.2, discovery.3)
  })
}

@external(erlang, "albedo_skills", "discover")
fn native_discover(
  workspace: String,
  home: String,
  builtin: String,
) -> Result(#(List(Candidate), List(String), Bool, String), String)

pub type Command {
  Command(name: String, description: String, command: String, source: String)
}

pub type Activation {
  Activation(
    name: String,
    description: String,
    source: String,
    arguments: String,
    instructions: String,
  )
}

pub type Page {
  Page(
    encoding: String,
    content: String,
    next_offset: Int,
    truncated: Bool,
    size: Int,
    path: String,
  )
}

pub type Resources {
  Resources(names: List(String), truncated: Bool, diagnostics: List(String))
}

const reserved_commands = [
  "a",
  "agents",
  "context",
  "exit",
  "extensions",
  "login",
  "model",
  "mouse",
  "new",
  "plugins",
  "q",
  "quit",
  "sessions",
  "status",
  "t",
  "thinking",
  "tree",
  "v",
  "verbose",
  "workspace",
]

/// Explicit home and built-in root make tests and embedders independent of the
/// daemon account and install; an empty `builtin` ships no built-in skills.
/// A remote workspace's project skills are read from its daemon-side mirror
/// (project_files); while its host is out of reach only the home and
/// built-in directories are scanned (native discovery takes "" as no
/// project), and a diagnostic says so.
pub fn scan_at(
  workspace: String,
  home: String,
  builtin: String,
) -> Result(Catalog, String) {
  let #(project, skipped) = case project_files.readable(workspace) {
    Ok(dir) -> #(dir, [])
    Error(why) -> #("", ["project skills skipped: " <> why])
  }
  use #(skills, diagnostics, _) <- result.try(native_catalog(
    project,
    home,
    builtin,
  ))
  Ok(Catalog(
    list.map(skills, fn(v) { Skill(v.0, v.1, v.2, v.3, v.4, v.5) }),
    list.append(skipped, diagnostics),
  ))
}

pub fn only(catalog: Catalog, names: List(String)) -> Catalog {
  Catalog(
    list.filter(catalog.skills, fn(skill) { list.contains(names, skill.name) }),
    catalog.diagnostics,
  )
}

pub fn commands(catalog: Catalog) -> List(Command) {
  list.map(catalog.skills, fn(skill) {
    Command(skill.name, skill.description, command_name(skill.name), skill.path)
  })
}

fn command_name(name: String) -> String {
  case list.contains(reserved_commands, name) {
    True -> "/skill:" <> name
    False -> "/" <> name
  }
}

pub fn context(catalog: Catalog) -> String {
  let skill_xml =
    catalog.skills
    |> list.map(fn(skill) {
      "  <skill>\n"
      <> "    <name>"
      <> xml_escape(skill.name)
      <> "</name>\n"
      <> "    <description>"
      <> xml_escape(skill.description)
      <> "</description>\n"
      <> "    <location>"
      <> xml_escape(skill.path)
      <> "</location>\n"
      <> "    <command>"
      <> xml_escape(command_name(skill.name))
      <> "</command>\n"
      <> "  </skill>"
    })
    |> string.join("\n")
  let diagnostic_xml = case catalog.diagnostics {
    [] -> ""
    values ->
      "\n  <diagnostics>\n"
      <> {
        values
        |> list.map(fn(value) {
          "    <diagnostic>" <> xml_escape(value) <> "</diagnostic>"
        })
        |> string.join("\n")
      }
      <> "\n  </diagnostics>"
  }
  "<available_skills>\n"
  <> skill_xml
  <> diagnostic_xml
  <> "\n</available_skills>\n"
  <> "This catalog contains metadata only. Every listed slash command is a session command: invoke it through the `commands` object (commands.catalog() maps slash names to typed methods) to receive its instructions as data before applying them. await skills.resources(name) lists bundled resource names, and await skills.read(name, resource=...) reads one bounded page, returning {content, next_offset, size, truncated}. A user may explicitly run the shown slash command, which submits the activation as one user turn. Reading or activating a skill never executes scripts, imports skill modules, fetches links, or grants tools; allowed-tools metadata is descriptive only."
}

pub fn activate(
  catalog: Catalog,
  name: String,
  arguments: String,
) -> Result(Activation, String) {
  use skill <- result.try(find(catalog, name))
  use #(loaded_name, loaded_description, source, instructions) <- result.try(
    native_activate(skill),
  )
  Ok(Activation(
    loaded_name,
    loaded_description,
    source,
    arguments,
    instructions,
  ))
}

/// A user slash activation submits this as the single model-visible user input.
/// JSON quoting makes the instruction, source, and opaque arguments boundaries exact.
pub fn activation_prompt(activation: Activation) -> String {
  "An explicitly requested Agent Skill activation follows as JSON. Apply its instructions to the supplied arguments. Resolve relative paths from the installed skill directory containing source, even when source is a symlink to instructions elsewhere. Do not execute bundled scripts merely because they exist.\n"
  <> json.to_string(
    json.object([
      #("type", json.string("skill_activation")),
      #("name", json.string(activation.name)),
      #("description", json.string(activation.description)),
      #("source", json.string(activation.source)),
      #("arguments", json.string(activation.arguments)),
      #("instructions", json.string(activation.instructions)),
    ]),
  )
}

pub fn resources(catalog: Catalog, name: String) -> Result(Resources, String) {
  use skill <- result.try(find(catalog, name))
  native_list(skill)
  |> result.map(fn(v) { Resources(v.0, v.1, v.2) })
}

pub fn read(
  catalog: Catalog,
  name: String,
  resource: String,
  offset: Int,
  limit: Int,
) -> Result(Page, String) {
  use skill <- result.try(find(catalog, name))
  native_read(skill, resource, offset, limit)
  |> result.map(fn(v) { Page(v.0, v.1, v.2, v.3, v.4, v.5) })
}

fn find(catalog: Catalog, name: String) -> Result(Skill, String) {
  list.find(catalog.skills, fn(skill) { skill.name == name })
  |> result.replace_error("unknown skill name; the session catalog lists them")
}

@external(erlang, "albedo_skills", "home")
pub fn native_home() -> String

@external(erlang, "albedo_skills", "builtin_root")
pub fn native_builtin() -> String

@external(erlang, "albedo_skills", "catalog")
fn native_catalog(
  workspace: String,
  home: String,
  builtin: String,
) -> Result(
  #(List(#(String, String, String, String, String, String)), List(String), Int),
  String,
)

@external(erlang, "albedo_skills", "activate_selected")
fn native_activate(
  skill: Skill,
) -> Result(#(String, String, String, String), String)

@external(erlang, "albedo_skills", "list_selected")
fn native_list(
  skill: Skill,
) -> Result(#(List(String), Bool, List(String)), String)

@external(erlang, "albedo_skills", "read_selected")
fn native_read(
  skill: Skill,
  resource: String,
  offset: Int,
  limit: Int,
) -> Result(#(String, String, Int, Bool, Int, String), String)

@external(erlang, "albedo_skills", "xml_escape")
fn xml_escape(value: String) -> String
