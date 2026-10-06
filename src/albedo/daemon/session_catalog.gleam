//// Fresh native discovery. Reading it does not prepare a kernel or invoke a command.

import albedo/daemon/conversation
import albedo/daemon/settings
import albedo/daemon/store
import albedo/harness/capabilities
import albedo/harness/capability_catalog
import albedo/harness/extension
import albedo/harness/extension/selection
import albedo/harness/extensions/skills/catalog as skills
import albedo/harness/instruction_files
import albedo/harness/project_files
import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import sqlight

pub type Candidate {
  Candidate(
    id: String,
    kind: String,
    title: String,
    description: String,
    source: String,
    resolved_source: Option(String),
    preference_key: Option(String),
    valid: Bool,
    eligible: Bool,
    effective_enabled: Bool,
    global_preference: Option(Bool),
    session_override: Option(Bool),
    shadowed_by: Option(String),
    dependencies: List(String),
    diagnostic: Option(String),
    metadata: Option(extension.Summary),
  )
}

pub type Snapshot {
  Snapshot(
    workspace: String,
    revision: String,
    candidates: List(Candidate),
    diagnostics: List(String),
    /// Captured source and capability facts used to prepare a composition.
    basis: String,
  )
}

pub type Inventory {
  Inventory(
    ledger: store.Store,
    installed: List(extension.Extension),
    quarantined: List(extension.Quarantined),
    defaults: List(String),
  )
}

pub type Inputs {
  /// `saved` keys the stored choices and settings alone; `key` adds the
  /// contents of every discovered source file.
  Inputs(key: String, basis: String, saved: String)
}

/// Actual saved revisions and source contents, without parsing candidate rows.
/// This is a private runtime observation key, not a wire revision.
pub fn inputs(
  home: String,
  inventory: Inventory,
  id: String,
) -> Result(Inputs, String) {
  use choices <- result.try(saved_choices(inventory, id))
  use saved <- result.try(native_saved(home))
  use sources <- result.try(native_inputs(
    home,
    project_files.observed(choices.0) |> option.unwrap(""),
    instruction_files.home(),
    skills.native_builtin(),
  ))
  Ok(Inputs(
    fingerprint(string.inspect(#(choices, sources.0))),
    sources.1,
    fingerprint(string.inspect(#(choices, saved))),
  ))
}

/// The `saved` part of `inputs`, without reading any skill, instruction, or
/// MCP source file.
pub fn saved_key(
  home: String,
  inventory: Inventory,
  id: String,
) -> Result(String, String) {
  use choices <- result.try(saved_choices(inventory, id))
  use saved <- result.try(native_saved(home))
  Ok(fingerprint(string.inspect(#(choices, saved))))
}

fn saved_choices(
  inventory: Inventory,
  id: String,
) -> Result(#(String, Int, List(#(String, String, String, Bool))), String) {
  store.query(inventory.ledger, fn(db) {
    use #(workspace, revision) <- result.try(store.one(
      db,
      "SELECT cwd,config_revision FROM sessions WHERE id=?",
      [sqlight.text(id)],
      {
        use workspace <- decode.field(0, decode.string)
        use revision <- decode.field(1, decode.int)
        decode.success(#(workspace, revision))
      },
      "session not found",
    ))
    use choices <- result.try(
      store.rows(
        db,
        "SELECT kind,candidate,preference_key,enabled FROM session_selection WHERE session=? UNION ALL SELECT 'extensions',name,name,enabled FROM session_extensions WHERE session=? ORDER BY 1,2,3",
        [sqlight.text(id), sqlight.text(id)],
        {
          use kind <- decode.field(0, decode.string)
          use candidate <- decode.field(1, decode.string)
          use key <- decode.field(2, decode.string)
          use enabled <- decode.field(3, sqlight.decode_bool())
          decode.success(#(kind, candidate, key, enabled))
        },
      ),
    )
    Ok(#(workspace, revision, choices))
  })
}

@external(erlang, "albedo_session_catalog", "inputs")
fn native_inputs(
  home: String,
  workspace: String,
  sources_home: String,
  builtin: String,
) -> Result(#(String, String), String)

@external(erlang, "albedo_session_catalog", "saved")
fn native_saved(home: String) -> Result(String, String)

pub fn inspect(
  home: String,
  inventory: Inventory,
  id: String,
) -> Result(Snapshot, String) {
  use observed_inputs <- result.try(inputs(home, inventory, id))
  use captured <- result.try(conversation.capture(inventory.ledger, id))
  use summaries <- result.try(selection.summaries(
    inventory.ledger,
    inventory.installed,
    inventory.quarantined,
    inventory.defaults,
    id,
    None,
  ))
  use files <- result.try(capability_catalog.inspect(
    project_files.observed(captured.info.cwd) |> option.unwrap(""),
    home,
    id,
    capability_catalog.extension_state(summaries),
    inventory.ledger,
  ))
  use definitions <- result.try(
    settings.mcp_definitions(home)
    |> result.map_error(fn(_) { "MCP definitions are unavailable" }),
  )
  use preferences <- result.try(capabilities.load(
    home,
    Some(#(inventory.ledger, id)),
  ))
  let extensions =
    list.map(summaries, fn(summary) {
      Candidate(
        summary.name,
        "extension",
        summary.name,
        summary.description,
        "installed",
        None,
        Some(summary.name),
        summary.quarantined == None,
        summary.quarantined == None,
        summary.enabled,
        Some(summary.global_enabled),
        case summary.overridden {
          True -> Some(summary.enabled)
          False -> None
        },
        None,
        summary.requires,
        summary.quarantined,
        Some(summary),
      )
    })
  let file_revision = files.revision
  let diagnostics = files.diagnostics
  let files =
    list.map(files.candidates, fn(candidate) {
      Candidate(
        candidate.id,
        case candidate.kind {
          "skills" -> "skill"
          _ -> "instruction"
        },
        candidate.title,
        option.unwrap(candidate.description, ""),
        candidate.source,
        candidate.resolved_source,
        candidate.preference_key,
        candidate.valid,
        candidate.eligible,
        candidate.effective_enabled,
        candidate.global_preference,
        candidate.session_override,
        candidate.shadowed_by,
        [],
        candidate.diagnostic,
        None,
      )
    })
  let mcp_enabled =
    list.any(summaries, fn(summary) { summary.name == "mcp" && summary.enabled })
  use servers <- result.try(
    list.try_map(definitions, fn(definition) {
      use choices <- result.try(capabilities.choices(
        preferences,
        "mcp",
        definition.0,
      ))
      Ok(Candidate(
        definition.0,
        "mcp",
        definition.0,
        "MCP server",
        "settings",
        None,
        Some(definition.0),
        True,
        definition.1 && mcp_enabled && choices.2,
        definition.1 && mcp_enabled && choices.2,
        choices.0,
        choices.1,
        None,
        ["mcp"],
        None,
        None,
      ))
    }),
  )
  let candidates = list.append(extensions, files) |> list.append(servers)
  use settings_revision <- result.try(settings.composition_revision(home))
  let revision =
    fingerprint(
      string.inspect(#(
        captured.info.cwd,
        file_revision,
        settings_revision,
        candidates,
      )),
    )
  let basis =
    fingerprint(
      string.inspect(#(
        captured.info.cwd,
        observed_inputs.basis,
        candidates
          |> list.filter(fn(candidate) { candidate.kind != "extension" })
          |> list.map(fn(candidate) {
            #(
              candidate.kind,
              candidate.preference_key,
              candidate.session_override,
            )
          }),
      )),
    )
  use after <- result.try(inputs(home, inventory, id))
  case after.key == observed_inputs.key {
    True ->
      Ok(Snapshot(captured.info.cwd, revision, candidates, diagnostics, basis))
    False -> Error("composition inputs changed during discovery")
  }
}

/// A composition revision describes captured inputs and actual selected
/// extensions, independently of the management discovery validator.
pub fn composition_revision(
  snapshot: Snapshot,
  selected: List(String),
) -> String {
  fingerprint(
    string.inspect(#(snapshot.basis, list.sort(selected, string.compare))),
  )
}

@external(erlang, "albedo_session_catalog", "fingerprint")
fn fingerprint(value: String) -> String
