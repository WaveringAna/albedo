//// Instruction selection, prompt precedence, and rendering over native file IO.

import albedo/harness/capabilities
import albedo/harness/settings
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub type Selection {
  First
  All
}

type Location {
  ProjectRoot
  ProjectAgents
  ProjectAlbedo
  GlobalAgents
  GlobalAlbedo
}

type Candidate {
  Candidate(location: Location, display: String, path: String)
}

pub type InspectedFile {
  InspectedFile(
    id: String,
    key: String,
    display: String,
    path: String,
    valid: Bool,
    diagnostic: Option(String),
  )
}

pub type Discovery {
  Discovery(candidates: List(InspectedFile), fingerprint: String)
}

/// Inspect all discovered files without applying preferences or preparing context.
pub fn inspect_at(
  workspace: String,
  home: String,
) -> Result(Discovery, String) {
  native_inspect(workspace, home)
  |> result.map(fn(discovery) { Discovery(discovery.0, discovery.1) })
}

@external(erlang, "albedo_instruction_files", "inspect")
fn native_inspect(
  workspace: String,
  home: String,
) -> Result(#(List(InspectedFile), String), String)

type ReadLimit {
  Instructions
  Prompts
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
  use files <- result.try(discover_named(workspace, home, name))
  let files = ordered(files)
  let selected = case selection {
    First -> list.take(files, 1)
    All -> files
  }
  use #(loaded, _) <- result.try(read(selected, Prompts))
  case loaded {
    [] -> Ok(None)
    _ -> Ok(Some(string.join(list.map(loaded, fn(file) { file.1 }), "\n\n")))
  }
}

@external(erlang, "albedo_instruction_files", "home")
pub fn home() -> String

/// The selected files' context and any warnings about skipped files.
pub fn load_selected(
  workspace: String,
  home: String,
  session: String,
) -> Result(#(String, List(String)), String) {
  load_with_selection(workspace, home, Some(session))
}

fn load_with_selection(
  workspace: String,
  home: String,
  session: Option(String),
) -> Result(#(String, List(String)), String) {
  use files <- result.try(discover_instructions(workspace, home))
  case files {
    // An empty selection must not read or validate capability preferences.
    [] -> Ok(#("", []))
    _ -> {
      use preferences <- result.try(case session {
        None -> capabilities.load("", None)
        Some(_) -> capabilities.load(settings.home(), session)
      })
      use selected <- result.try(select(ordered(files), preferences))
      use #(loaded, warnings) <- result.try(read(selected, Instructions))
      Ok(#(render(loaded), warnings))
    }
  }
}

fn ordered(files: List(Candidate)) -> List(Candidate) {
  // Native discovery sorts within each directory; policy orders the locations.
  list.flat_map(
    [ProjectRoot, ProjectAgents, ProjectAlbedo, GlobalAgents, GlobalAlbedo],
    fn(location) {
      list.filter(files, fn(file) {
        let Candidate(candidate_location, _, _) = file
        candidate_location == location
      })
    },
  )
}

fn scope(location: Location) -> String {
  case location {
    ProjectRoot | ProjectAgents | ProjectAlbedo -> "project"
    GlobalAgents | GlobalAlbedo -> "global"
  }
}

fn select(
  files: List(Candidate),
  preferences: capabilities.Preferences,
) -> Result(List(Candidate), String) {
  use choices <- result.try(
    list.try_map(files, fn(file) {
      capabilities.enabled(
        preferences,
        "instructions",
        scope(file.location) <> ":" <> file.display,
      )
      |> result.map(fn(enabled) { #(file, enabled) })
    }),
  )
  choices
  |> list.filter(fn(choice) { choice.1 })
  |> list.map(fn(choice) { choice.0 })
  |> Ok
}

fn render(loaded: List(#(Candidate, String))) -> String {
  case loaded {
    [] -> ""
    _ -> {
      let project =
        list.filter(loaded, fn(file) { scope(file.0.location) == "project" })
      let global =
        list.filter(loaded, fn(file) { scope(file.0.location) == "global" })
      "# Autoloaded instructions\n\n"
      <> "Project-level files define conventions for this project. Global-level files "
      <> "describe the user's general preferences. Apply both; when they conflict on "
      <> "project-specific work, follow the project-level convention. Files at the same "
      <> "level are concatenated rather than overriding one another.\n"
      <> render_group(
        "\n## Project-level conventions\n\nUse these for project-level conventions.\n",
        project,
      )
      <> render_group(
        "\n## Global user preferences\n\nUse these for acting in the user's preferences.\n",
        global,
      )
    }
  }
}

fn render_group(header: String, files: List(#(Candidate, String))) -> String {
  case files {
    [] -> ""
    _ ->
      header
      <> string.concat(
        list.map(files, fn(file) {
          "\n### " <> file.0.display <> "\n\n" <> file.1 <> "\n"
        }),
      )
  }
}

@external(erlang, "albedo_instruction_files", "discover_instructions")
fn discover_instructions(
  workspace: String,
  home: String,
) -> Result(List(Candidate), String)

@external(erlang, "albedo_instruction_files", "discover_named")
fn discover_named(
  workspace: String,
  home: String,
  name: String,
) -> Result(List(Candidate), String)

@external(erlang, "albedo_instruction_files", "read")
fn read(
  files: List(Candidate),
  limit: ReadLimit,
) -> Result(#(List(#(Candidate, String)), List(String)), String)
