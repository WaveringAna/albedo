//// Fresh management discovery, independent of prepared commands and prompt state.

import albedo/harness/capabilities
import albedo/harness/extension
import albedo/harness/extensions/skills/catalog as skills
import albedo/harness/instruction_files
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

pub type Extensions {
  Extensions(skills: Bool, instructions: Bool, fingerprint: String)
}

pub type Change {
  Change(
    workspace: String,
    revision: String,
    id: String,
    scope: String,
    enabled: Option(Bool),
  )
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

pub const stale_error = "catalog changed; refresh before changing a capability"

pub fn change_decoder() -> decode.Decoder(Change) {
  use revision <- decode.field("revision", decode.string)
  use id <- decode.field("id", decode.string)
  use scope <- decode.field("scope", decode.string)
  use enabled <- decode.field("enabled", decode.optional(decode.bool))
  decode.success(Change("", revision, id, scope, enabled))
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
  use preferences <- result.try(capabilities.load(home, Some(session)))
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
      session,
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

pub fn save(
  home: String,
  session: String,
  change: Change,
  extensions: fn() -> Result(Extensions, String),
  after: fn() -> Result(a, String),
) -> Result(a, String) {
  guarded_capability(
    home,
    session,
    fn() {
      use current_extensions <- result.try(extensions())
      use snapshot <- result.try(inspect(
        change.workspace,
        home,
        session,
        current_extensions,
      ))
      case snapshot.revision == change.revision {
        False -> Error(stale_error)
        True -> {
          use row <- result.try(
            list.find(snapshot.candidates, fn(row) { row.id == change.id })
            |> result.replace_error(stale_error),
          )
          use key <- result.try(option.to_result(
            row.preference_key,
            "candidate has no validated preference key",
          ))
          case change.scope == "global" || change.scope == "session" {
            False -> Error("choose global or session scope")
            True ->
              case row.shadowed_by, row.valid, change.enabled {
                Some(_), _, _ -> Error("shadowed candidates cannot be changed")
                _, False, Some(True) ->
                  Error("invalid candidates cannot be enabled")
                _, _, _ -> Ok(#(row.kind, key, change.scope, change.enabled))
              }
          }
        }
      }
    },
    after,
  )
}

pub fn to_json(snapshot: Snapshot) -> json.Json {
  json.object([
    #("workspace", json.string(snapshot.workspace)),
    #("revision", json.string(snapshot.revision)),
    #(
      "extensions",
      json.object([
        #("skills", json.bool(snapshot.extensions.skills)),
        #("instructions", json.bool(snapshot.extensions.instructions)),
      ]),
    ),
    #("diagnostics", json.array(snapshot.diagnostics, json.string)),
    #("candidates", json.array(snapshot.candidates, candidate_json)),
  ])
}

fn candidate_json(row: Candidate) -> json.Json {
  json.object([
    #("id", json.string(row.id)),
    #("kind", json.string(row.kind)),
    #("title", json.string(row.title)),
    #("description", json.nullable(row.description, json.string)),
    #("source", json.string(row.source)),
    #("resolved_source", json.nullable(row.resolved_source, json.string)),
    #("preference_key", json.nullable(row.preference_key, json.string)),
    #("valid", json.bool(row.valid)),
    #("diagnostic", json.nullable(row.diagnostic, json.string)),
    #("shadowed_by", json.nullable(row.shadowed_by, json.string)),
    #("global_preference", json.nullable(row.global_preference, json.bool)),
    #("session_override", json.nullable(row.session_override, json.bool)),
    #("effective_enabled", json.bool(row.effective_enabled)),
    #("eligible", json.bool(row.eligible)),
  ])
}

@external(erlang, "albedo_capability_catalog", "fingerprint")
fn fingerprint(value: a) -> String

@external(erlang, "albedo_settings_store", "catalog_capability")
fn guarded_capability(
  home: String,
  session: String,
  resolve: fn() -> Result(#(String, String, String, Option(Bool)), String),
  after: fn() -> Result(a, String),
) -> Result(a, String)

@external(erlang, "albedo_capability_catalog", "source_title")
fn source_title(source: String) -> String
