//// What the runtime reports about a session's composition without preparing
//// it: the discovery inventory, the desired selection and its revision, and
//// the observation an HTTP caller or the session actor reads.

import albedo/daemon/session_catalog
import albedo/harness/extension
import albedo/harness/protect
import albedo/harness/runtime/state as runtime_state
import albedo/harness/settings
import albedo/shared
import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

pub fn composition_inventory(
  state: runtime_state.State,
) -> session_catalog.Inventory {
  let installed = shared.read(state.installed)
  session_catalog.Inventory(
    state.work,
    installed.extensions,
    installed.quarantined,
    installed.default_enabled,
  )
}

/// The bases an observation of one session may reuse: its own desired
/// discovery and the basis its loaded composition was prepared on, never
/// another session's or the runtime cache.
pub fn bases_for(
  state: runtime_state.State,
  id: String,
) -> List(runtime_state.Desired) {
  list.filter_map(
    [
      dict.get(state.desired, id) |> option.from_result,
      dict.get(state.compositions, id)
        |> option.from_result
        |> option.then(fn(cached) { cached.basis }),
    ],
    option.to_result(_, Nil),
  )
}

/// One observation worker's reading: what it discovered, rechecked after
/// plugin observation so inputs that changed under it are reported as such,
/// and the answer for `reply`'s kind.
pub fn observe(
  inventory: session_catalog.Inventory,
  retained: List(runtime_state.Desired),
  cached: Option(runtime_state.Cached),
  home: String,
  id: String,
  reply: runtime_state.ObservationReply,
) -> #(Result(runtime_state.Desired, String), runtime_state.ObservationResult) {
  let discovered =
    protect.attempt(fn() {
      case reply {
        runtime_state.CompositionReply(_) ->
          retained_desired(inventory, retained, home, id)
        runtime_state.CatalogReply(_) -> desired(inventory, retained, home, id)
      }
    })
    |> result.flatten
  let observed = case reply {
    runtime_state.CompositionReply(_) ->
      runtime_state.CompositionResult({
        use value <- result.try(discovered)
        protect.attempt(fn() {
          observe_composition_value(inventory, cached, value.snapshot, id)
        })
        |> result.flatten
      })
    runtime_state.CatalogReply(_) ->
      runtime_state.CatalogResult({
        use _ <- result.try(case discovered {
          Error("session not found") -> Error("session not found")
          _ -> Ok(Nil)
        })
        Ok(runtime_state.CatalogObservation(
          result.map(discovered, fn(value) { value.snapshot }),
          option.then(cached, fn(value) { value.loaded_revision }),
          option.map(cached, fn(value) {
            extension.command_entries(value.composition)
          })
            |> option.unwrap([]),
          option.map(cached, fn(value) {
            extension.client_commands(value.composition)
          })
            |> option.unwrap([]),
        ))
      })
  }
  let discovered =
    protect.attempt(fn() {
      use value <- result.try(discovered)
      use unchanged <- result.try(case reply {
        runtime_state.CompositionReply(_) ->
          session_catalog.saved_key(home, inventory, id)
          |> result.map(fn(saved) { saved == value.saved })
        runtime_state.CatalogReply(_) ->
          session_catalog.inputs(home, inventory, id)
          |> result.map(fn(after) { after.key == value.inputs })
      })
      case unchanged {
        True -> Ok(value)
        False -> Error("composition inputs changed during observation")
      }
    })
    |> result.flatten
  #(discovered, observed)
}

/// Trusted embeddings may prepare kernels without a daemon session row. They
/// have no saved discovery basis; daemon sessions retain the real basis used
/// for preparation instead of substituting a later desired revision.
pub fn composition_basis(
  inventory: session_catalog.Inventory,
  id: String,
  retained: List(runtime_state.Desired),
) -> Result(Option(runtime_state.Desired), String) {
  let home = settings.home()
  case session_catalog.inputs(home, inventory, id) {
    Ok(inputs) -> {
      case list.find(retained, fn(value) { value.inputs == inputs.key }) {
        Ok(observation) -> Ok(Some(observation))
        Error(_) -> {
          use snapshot <- result.try(session_catalog.inspect(
            home,
            inventory,
            id,
          ))
          use after <- result.try(session_catalog.inputs(home, inventory, id))
          case after.key == inputs.key {
            True ->
              Ok(
                Some(runtime_state.Desired(inputs.key, inputs.saved, snapshot)),
              )
            False -> Error("composition inputs changed during preparation")
          }
        }
      }
    }
    Error("session not found") -> Ok(None)
    Error(reason) -> Error(reason)
  }
}

/// Reuse actual discovery facts while their content and saved choices match.
/// Equivalent sessions can share the immutable snapshot; each lifetime owns
/// its retained reference and teardown removes that reference.
pub fn desired(
  inventory: session_catalog.Inventory,
  retained: List(runtime_state.Desired),
  home: String,
  id: String,
) -> Result(runtime_state.Desired, String) {
  use inputs <- result.try(session_catalog.inputs(home, inventory, id))
  case list.find(retained, fn(value) { value.inputs == inputs.key }) {
    Ok(value) -> Ok(value)
    Error(_) -> {
      use snapshot <- result.try(session_catalog.inspect(home, inventory, id))
      use after <- result.try(session_catalog.inputs(home, inventory, id))
      case after.key == inputs.key {
        True -> Ok(runtime_state.Desired(inputs.key, inputs.saved, snapshot))
        False -> Error("composition inputs changed during discovery")
      }
    }
  }
}

/// The retained discovery while the saved choices and settings still match.
/// Skill, instruction, and MCP files are walked again only on a miss; changes
/// on disk reach a session through a reload.
pub fn retained_desired(
  inventory: session_catalog.Inventory,
  retained: List(runtime_state.Desired),
  home: String,
  id: String,
) -> Result(runtime_state.Desired, String) {
  use saved <- result.try(session_catalog.saved_key(home, inventory, id))
  case list.find(retained, fn(value) { value.saved == saved }) {
    Ok(value) -> Ok(value)
    Error(_) -> desired(inventory, retained, home, id)
  }
}

pub fn observe_composition_value(
  inventory: session_catalog.Inventory,
  cached: Option(runtime_state.Cached),
  discovery: session_catalog.Snapshot,
  id: String,
) -> Result(runtime_state.CompositionObservation, String) {
  let desired_revision =
    session_catalog.composition_revision(
      discovery,
      discovery.candidates
        |> list.filter(fn(candidate) {
          candidate.kind == "extension" && candidate.effective_enabled
        })
        |> list.map(fn(candidate) { candidate.id }),
    )
  let loaded = option.then(cached, fn(value) { value.loaded_revision })
  let failures =
    option.map(cached, fn(value) {
      extension.inactive(value.composition) |> list.map(fn(item) { item.0 })
    })
    |> option.unwrap([])
  let selected =
    option.map(cached, fn(value) {
      extension.extensions(value.composition)
      |> list.map(fn(item) { item.name })
    })
    |> option.unwrap([])
  let availability =
    list.map(
      discovery.candidates
        |> list.filter(fn(candidate) { candidate.kind == "extension" }),
      fn(candidate) {
        #(
          candidate.id,
          list.contains(selected, candidate.id)
            && !list.contains(failures, candidate.id),
        )
      },
    )
    |> dict.from_list
  let dependencies =
    inventory.installed
    |> list.map(fn(item) { #(item.name, item.requires) })
    |> dict.from_list
  let quarantine =
    list.append(
      inventory.quarantined,
      list.filter_map(
        option.map(cached, fn(value) { extension.inactive(value.composition) })
          |> option.unwrap([]),
        fn(failure) {
          list.find(inventory.installed, fn(item) { item.name == failure.0 })
          |> result.map(fn(item) {
            extension.Quarantined(item.name, item.description, failure.1)
          })
        },
      ),
    )
  use glances <- result.try(case cached {
    None -> Ok([])
    Some(cached) ->
      extension.glances(cached.composition, inventory.ledger, id, cached.cwd)
  })
  Ok(runtime_state.CompositionObservation(
    discovery,
    desired_revision,
    loaded,
    case loaded {
      None -> False
      Some(revision) -> revision != desired_revision
    },
    dependencies,
    quarantine,
    availability,
    glances,
  ))
}

/// Reuse immutable discovery facts from observations and actual preparations.
pub fn retained_basis(
  state: runtime_state.State,
) -> List(runtime_state.Desired) {
  list.append(
    dict.values(state.desired),
    dict.values(state.compositions)
      |> list.filter_map(fn(cached) { option.to_result(cached.basis, Nil) }),
  )
}
