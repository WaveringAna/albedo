//// Immutable Agent Skills catalog snapshots and on-demand activation.

import gleam/json
import gleam/list
import gleam/result
import gleam/string

pub type Skill {
  Skill(name: String, description: String, path: String)
}

pub type Catalog {
  Catalog(skills: List(Skill), diagnostics: List(String))
}

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

pub fn scan(workspace: String) -> Result(Catalog, String) {
  scan_at(workspace, native_home())
}

/// Explicit home makes tests and embedders independent of the daemon account.
pub fn scan_at(workspace: String, home: String) -> Result(Catalog, String) {
  use scanned <- result.try(native_catalog(workspace, home))
  let #(skills, diagnostics, _) = scanned
  Ok(Catalog(
    list.map(skills, fn(value) { Skill(value.0, value.1, value.2) }),
    diagnostics,
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

pub fn command_name(name: String) -> String {
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
  use loaded <- result.try(native_activate(skill.path))
  let #(loaded_name, loaded_description, source, instructions) = loaded
  use _ <- result.try(
    case
      loaded_name == skill.name
      && loaded_description == skill.description
      && source == skill.path
    {
      True -> Ok(Nil)
      False ->
        Error(
          "SKILL.md metadata changed since this session opened; reload the skills extension",
        )
    },
  )
  Ok(Activation(skill.name, skill.description, source, arguments, instructions))
}

/// A user slash activation submits this as the single model-visible user input.
/// JSON quoting makes the instruction, source, and opaque arguments boundaries exact.
pub fn activation_prompt(activation: Activation) -> String {
  "An explicitly requested Agent Skill activation follows as JSON. Apply its instructions to the supplied arguments. Relative paths are relative to the directory containing source. Do not execute bundled scripts merely because they exist.\n"
  <> {
    json.object([
      #("type", json.string("skill_activation")),
      #("name", json.string(activation.name)),
      #("description", json.string(activation.description)),
      #("source", json.string(activation.source)),
      #("arguments", json.string(activation.arguments)),
      #("instructions", json.string(activation.instructions)),
    ])
    |> json.to_string
  }
}

pub fn resources(catalog: Catalog, name: String) -> Result(Resources, String) {
  use skill <- result.try(find(catalog, name))
  native_list(skill.path)
  |> result.map(fn(value) { Resources(value.0, value.1, value.2) })
}

pub fn read(
  catalog: Catalog,
  name: String,
  resource: String,
  offset: Int,
  limit: Int,
) -> Result(Page, String) {
  use skill <- result.try(find(catalog, name))
  native_read(skill.path, resource, offset, limit)
  |> result.map(fn(value) {
    Page(value.0, value.1, value.2, value.3, value.4, value.5)
  })
}

fn find(catalog: Catalog, name: String) -> Result(Skill, String) {
  list.find(catalog.skills, fn(skill) { skill.name == name })
  |> result.replace_error("unknown skill name; the session catalog lists them")
}

@external(erlang, "albedo_skills", "home")
pub fn native_home() -> String

@external(erlang, "albedo_skills", "catalog")
fn native_catalog(
  workspace: String,
  home: String,
) -> Result(#(List(#(String, String, String)), List(String), Int), String)

@external(erlang, "albedo_skills", "activate_selected")
fn native_activate(
  path: String,
) -> Result(#(String, String, String, String), String)

@external(erlang, "albedo_skills", "list_selected")
fn native_list(
  path: String,
) -> Result(#(List(String), Bool, List(String)), String)

@external(erlang, "albedo_skills", "read_selected")
fn native_read(
  path: String,
  resource: String,
  offset: Int,
  limit: Int,
) -> Result(#(String, String, Int, Bool, Int, String), String)

@external(erlang, "albedo_skills", "xml_escape")
fn xml_escape(value: String) -> String
