//// Validate editable session changes without preparing or reloading a kernel.

import albedo/daemon/configuration
import albedo/daemon/conversation
import albedo/daemon/session_configuration as config
import albedo/daemon/session_history
import albedo/daemon/session_provider
import albedo/daemon/session_state
import albedo/daemon/store
import albedo/daemon/turn
import albedo/harness/extension
import albedo/harness/extension/selection
import albedo/harness/runtime
import albedo/harness/runtime/catalog as session_catalog
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/result

pub fn change(
  state: session_state.State(message),
  expected: config.Version,
  patch: config.Patch,
) -> #(session_state.State(message), Result(config.Configuration, String)) {
  let ledger = runtime.ledger(state.host)
  let prepared = {
    use current <- result.try(
      store.query(ledger, config.read_in(_, state.info.id)),
    )
    use _ <- result.try(
      case
        current.revision == expected.revision
        && current.family.revision == expected.family_revision
      {
        True -> Ok(Nil)
        False -> Error("configuration_changed")
      },
    )
    use candidate <- result.try(normalize_strategies(
      config.apply(current, patch),
      patch.selection.extensions,
      runtime.installed(state.host),
    ))
    let model_changed =
      candidate.provider_profile != current.provider_profile
      || candidate.model != current.model
      || candidate.effort != current.effort
    let selection_changed = candidate.selection != current.selection
    use _ <- result.try(
      case
        { model_changed || selection_changed }
        && { turn.running(state.activity) != None || state.booting != None }
      {
        True -> Error("session_busy")
        False -> Ok(Nil)
      },
    )
    use #(state, observed_provider, candidate) <- result.try(
      case model_changed {
        False -> Ok(#(state, None, candidate))
        True ->
          validate_model(state, candidate, patch.effort == None)
          |> result.map(fn(value) { #(value.0, Some(value.1), value.2) })
      },
    )
    let protocol = case observed_provider {
      Some(provider) -> provider.protocol
      None -> state.info.protocol
    }
    use saved <- result.try(
      with_settings_lock(
        state.home,
        fn() {
          use _ <- result.try(case observed_provider {
            None -> Ok(Nil)
            Some(observed) -> {
              use current <- result.try(configuration.named(
                state.home,
                observed.name,
              ))
              case current == observed {
                True -> Ok(Nil)
                False -> Error("settings_changed")
              }
            }
          })
          use choices <- result.try(resolve_choices(state, candidate, patch))
          store.query(ledger, config.commit_in(
            _,
            config.Edit(expected, candidate, protocol, choices),
          ))
        },
        fn() { Error("settings_unavailable") },
      ),
    )
    Ok(#(state, protocol, saved, model_changed))
  }
  case prepared {
    Error(error) -> #(state, Error(error))
    Ok(#(state, protocol, saved, model_changed)) -> {
      let history = case model_changed {
        True ->
          option.map(state.history, session_history.tag_unknown_provider(
            _,
            state.info.provider,
          ))
        False -> state.history
      }
      #(
        session_state.State(
          ..state,
          info: conversation.Info(
            ..state.info,
            title: config.display_name(saved),
            provider: saved.provider_profile,
            model: saved.model,
            protocol: protocol,
            effort: saved.effort,
          ),
          history: history,
          context: case model_changed {
            True -> session_state.unprepared()
            False -> state.context
          },
        ),
        Ok(saved),
      )
    }
  }
}

/// Choosing one strategy replaces older explicit choices. Incoming null still
/// means inheritance, and conflicting choices in this request remain invalid.
fn normalize_strategies(
  candidate: config.Configuration,
  patch: option.Option(option.Option(dict.Dict(String, option.Option(Bool)))),
  installed: List(extension.Extension),
) -> Result(config.Configuration, String) {
  let strategy = fn(name) {
    installed
    |> list.filter(fn(item) { item.name == name })
    |> extension.compaction
    != None
  }
  case patch {
    Some(Some(changes)) -> {
      let chosen =
        dict.to_list(changes)
        |> list.filter(fn(choice) {
          choice.1 == Some(True) && strategy(choice.0)
        })
      case chosen {
        [] -> Ok(candidate)
        [choice] -> {
          let extensions =
            dict.fold(
              candidate.selection.extensions,
              candidate.selection.extensions,
              fn(choices, name, enabled) {
                case
                  enabled
                  && name != choice.0
                  && strategy(name)
                  && !dict.has_key(changes, name)
                {
                  True -> dict.delete(choices, name)
                  False -> choices
                }
              },
            )
          Ok(
            config.Configuration(
              ..candidate,
              selection: config.Selection(
                ..candidate.selection,
                extensions: extensions,
              ),
            ),
          )
        }
        _ -> Error("selection_conflict")
      }
    }
    _ -> Ok(candidate)
  }
}

fn validate_model(
  state: session_state.State(message),
  candidate: config.Configuration,
  inherit_effort: Bool,
) -> Result(
  #(session_state.State(message), configuration.Provider, config.Configuration),
  String,
) {
  use provider <- result.try(configuration.named(
    state.home,
    candidate.provider_profile,
  ))
  let candidate = case inherit_effort {
    False -> candidate
    True ->
      config.Configuration(
        ..candidate,
        effort: session_provider.resolve_effort(
          session_provider.model_efforts(
            state.host,
            state.home,
            candidate.provider_profile,
            candidate.model,
          ),
          candidate.effort,
          provider.effort,
        ),
      )
  }
  use _ <- result.try(case candidate.effort {
    None -> Ok(Nil)
    Some(level) ->
      case
        list.contains(
          session_provider.model_efforts(
            state.host,
            state.home,
            candidate.provider_profile,
            candidate.model,
          ),
          level,
        )
      {
        True -> Ok(Nil)
        False -> Error("unsupported reasoning effort")
      }
  })
  use state <- result.try(session_history.ensure_history(state))
  use _ <- result.try(session_history.projected_for(
    state.history,
    provider.name,
    provider.protocol,
  ))
  Ok(#(state, provider, candidate))
}

@external(erlang, "albedo_settings_lock", "with_lock")
fn with_settings_lock(
  home: String,
  run: fn() -> Result(a, String),
  busy: fn() -> Result(a, String),
) -> Result(a, String)

fn resolve_choices(
  state: session_state.State(message),
  candidate: config.Configuration,
  patch: config.Patch,
) -> Result(List(config.Choice), String) {
  use saved <- result.try(
    store.query(runtime.ledger(state.host), config.choices_in(_, state.info.id)),
  )
  let selection = patch.selection
  case
    selection.extensions == None
    && selection.skills == None
    && selection.instructions == None
    && selection.mcp == None
  {
    True -> Ok(saved)
    False -> {
      use catalog <- result.try(session_catalog.inspect(
        state.home,
        session_catalog.Inventory(
          runtime.ledger(state.host),
          runtime.installed(state.host),
          runtime.quarantined(state.host),
          runtime.base_defaults(state.host),
        ),
        state.info.id,
      ))
      use _ <- result.try(
        case selection.skills != None || selection.instructions != None {
          True ->
            case patch.catalog_revision == Some(catalog.revision) {
              True -> Ok(Nil)
              False -> Error("catalog_changed")
            }
          False -> Ok(Nil)
        },
      )
      use choices <- result.try(
        list.try_fold(
          [
            #("extensions", "extension", candidate.selection.extensions),
            #("skills", "skill", candidate.selection.skills),
            #("instructions", "instruction", candidate.selection.instructions),
            #("mcp", "mcp", candidate.selection.mcp),
          ],
          [],
          fn(choices, group) {
            use resolved <- result.try(
              list.try_map(dict.to_list(group.2), fn(choice) {
                case
                  list.find(catalog.candidates, fn(row) {
                    row.kind == group.1 && row.id == choice.0
                  })
                {
                  Ok(row) -> {
                    use _ <- result.try(
                      case
                        choice.1 && { !row.valid || row.shadowed_by != None }
                      {
                        True -> Error("candidate_unavailable")
                        False -> Ok(Nil)
                      },
                    )
                    use key <- result.try(case row.preference_key, choice.1 {
                      Some(key), _ -> Ok(key)
                      None, False ->
                        saved
                        |> list.find(fn(previous) {
                          previous.kind == group.0
                          && previous.candidate == choice.0
                        })
                        |> result.map(fn(previous) { previous.preference_key })
                        |> result.replace_error("candidate_unavailable")
                      None, True -> Error("candidate_unavailable")
                    })
                    Ok(config.Choice(group.0, choice.0, key, choice.1))
                  }
                  Error(_) ->
                    saved
                    |> list.find(fn(row) {
                      row.kind == group.0
                      && row.candidate == choice.0
                      && { !choice.1 || row.enabled }
                    })
                    |> result.map(fn(row) {
                      config.Choice(..row, enabled: choice.1)
                    })
                    |> result.replace_error("candidate_unavailable")
                }
              }),
            )
            use resolved <- result.try(resolve_aliases(
              resolved,
              catalog.candidates,
            ))
            Ok(list.append(choices, resolved))
          },
        ),
      )
      let defaults =
        catalog.candidates
        |> list.filter(fn(row) {
          row.kind == "extension" && option.unwrap(row.global_preference, False)
        })
        |> list.map(fn(row) { row.id })
      use _ <- result.try(
        selection.select(
          runtime.installed(state.host),
          defaults,
          dict.to_list(candidate.selection.extensions),
        )
        |> selection.validate_selection
        |> result.replace_error("selection_invalid"),
      )
      Ok(choices)
    }
  }
}

/// A discovered replacement owns its setting; an absent source cannot override it.
fn resolve_aliases(
  choices: List(config.Choice),
  candidates: List(session_catalog.Candidate),
) -> Result(List(config.Choice), String) {
  let discovered = fn(choice: config.Choice) {
    list.any(candidates, fn(candidate) {
      candidate.id == choice.candidate
      && candidate.valid
      && candidate.preference_key == Some(choice.preference_key)
    })
  }
  use resolved <- result.try(
    list.try_fold(choices, dict.new(), fn(resolved, choice) {
      case dict.get(resolved, choice.preference_key) {
        Error(_) -> Ok(dict.insert(resolved, choice.preference_key, choice))
        Ok(previous) ->
          case discovered(previous), discovered(choice) {
            False, True ->
              Ok(dict.insert(resolved, choice.preference_key, choice))
            True, False -> Ok(resolved)
            _, _ -> Error("duplicate candidate preference")
          }
      }
    }),
  )
  Ok(dict.values(resolved))
}
