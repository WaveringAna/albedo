//// Fresh management discovery, independent of prepared commands and prompt state.

import albedo/daemon/store
import albedo/harness/capabilities
import albedo/harness/extension
import albedo/harness/extensions/skills/catalog as skills
import albedo/harness/instruction_files
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

pub type Extensions {
  Extensions(skills: Bool, instructions: Bool, fingerprint: String)
}

pub type Candidate {
  Candidate(
    id: String,
    kind: String,
    title: String,
    description: Option(String),
    source: String,
    resolved_source: Option(String),
    preference_key: Option(String),
    valid: Bool,
    diagnostic: Option(String),
    shadowed_by: Option(String),
    global_preference: Option(Bool),
    session_override: Option(Bool),
    effective_enabled: Bool,
    eligible: Bool,
  )
}

pub type Snapshot {
  Snapshot(
    workspace: String,
    revision: String,
    extensions: Extensions,
    diagnostics: List(String),
    candidates: List(Candidate),
  )
}

pub fn extension_state(summaries: List(extension.Summary)) -> Extensions {
  let relevant =
    list.filter(summaries, fn(item) {
      item.name == "skills" || item.name == "instructions"
    })
  let enabled = fn(name) {
    list.any(relevant, fn(item) { item.name == name && item.enabled })
  }
  Extensions(
    enabled("skills"),
    enabled("instructions"),
    fingerprint(
      list.map(relevant, fn(item) {
        #(item.name, item.enabled, item.overridden, item.global_enabled)
      }),
    ),
  )
}

pub fn inspect(
  workspace: String,
  home: String,
  session: String,
  extensions: Extensions,
  ledger: store.Store,
) -> Result(Snapshot, String) {
  use discovered_skills <- result.try(skills.discover_at(
    workspace,
    skills.native_home(),
    skills.native_builtin(),
  ))
  use discovered_instructions <- result.try(instruction_files.inspect_at(
    workspace,
    instruction_files.home(),
  ))
  use preferences <- result.try(capabilities.load(
    home,
    Some(#(ledger, session)),
  ))
  use _ <- result.try(capabilities.validate_preferences(preferences))
  use skill_rows <- result.try(
    list.try_map(discovered_skills.candidates, fn(skill) {
      use #(global, override, effective) <- result.try(choices(
        preferences,
        "skills",
        skill.name,
      ))
      Ok(Candidate(
        skill.id,
        "skills",
        option.unwrap(skill.name, source_title(skill.source)),
        skill.description,
        skill.source,
        skill.resolved_source,
        skill.name,
        skill.valid,
        skill.diagnostic,
        skill.shadowed_by,
        global,
        override,
        effective,
        skill.eligible && effective && extensions.skills,
      ))
    }),
  )
  use instruction_rows <- result.try(
    list.try_map(discovered_instructions.candidates, fn(file) {
      use #(global, override, effective) <- result.try(capabilities.choices(
        preferences,
        "instructions",
        file.key,
      ))
      Ok(Candidate(
        file.id,
        "instructions",
        file.display,
        None,
        file.path,
        None,
        Some(file.key),
        file.valid,
        file.diagnostic,
        None,
        global,
        override,
        effective,
        file.valid && effective && extensions.instructions,
      ))
    }),
  )
  let candidates = list.append(skill_rows, instruction_rows)
  let revision =
    fingerprint(#(
      workspace,
      home,
      discovered_skills.fingerprint,
      discovered_instructions.fingerprint,
      extensions.fingerprint,
      preferences,
    ))
  Ok(Snapshot(
    workspace,
    revision,
    extensions,
    discovered_skills.diagnostics,
    candidates,
  ))
}

fn choices(
  preferences: capabilities.Preferences,
  kind: String,
  key: Option(String),
) -> Result(#(Option(Bool), Option(Bool), Bool), String) {
  case key {
    None -> Ok(#(None, None, True))
    Some(key) -> capabilities.choices(preferences, kind, key)
  }
}

@external(erlang, "albedo_capability_catalog", "fingerprint")
fn fingerprint(value: a) -> String

@external(erlang, "albedo_capability_catalog", "source_title")
fn source_title(source: String) -> String
