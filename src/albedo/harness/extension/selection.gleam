//// A session's saved extension selection: which extensions it runs over the
//// installed set and the global defaults, how a change is proposed, checked
//// and recorded, the raised context caps, and the summaries the UI shows.

import albedo/daemon/family
import albedo/daemon/store
import albedo/harness/extension
import albedo/harness/extension/composition
import albedo/harness/page
import albedo/harness/protect
import albedo/harness/settings
import gleam/dict
import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import sqlight

pub type SelectionError {
  ConflictingStrategies
  InvalidSelection(String)
}

/// Validate global defaults before publication. One newly chosen strategy
/// replaces earlier explicit choices; an incoming null still means inheritance.
pub fn change_defaults(
  installed: List(extension.Extension),
  built_in: List(String),
  current: List(#(String, Bool)),
  changes: List(#(String, Option(Bool))),
) -> Result(List(#(String, Bool)), SelectionError) {
  let strategies =
    list.filter(changes, fn(change) {
      change.1 == Some(True) && compaction_named(installed, change.0)
    })
  use _ <- result.try(case strategies {
    [] | [_] -> Ok(Nil)
    _ -> Error(ConflictingStrategies)
  })
  use _ <- result.try(
    list.try_each(changes, fn(change) {
      case
        change.1 == Some(True)
        && !list.any(installed, fn(item) { item.name == change.0 })
      {
        True ->
          Error(InvalidSelection("extension is not installed: " <> change.0))
        False -> Ok(Nil)
      }
    }),
  )
  let choices =
    list.fold(changes, dict.from_list(current), fn(choices, change) {
      case change.1 {
        None -> dict.delete(choices, change.0)
        Some(enabled) -> dict.insert(choices, change.0, enabled)
      }
    })
  let choices = case strategies {
    [chosen] ->
      dict.fold(choices, choices, fn(choices, name, enabled) {
        case
          enabled
          && name != chosen.0
          && compaction_named(installed, name)
          && !list.any(changes, fn(change) { change.0 == name })
        {
          True -> dict.delete(choices, name)
          False -> choices
        }
      })
    _ -> choices
  }
  let choices = dict.to_list(choices)
  use _ <- result.try(
    validate_selection(select(installed, built_in, choices))
    |> result.map_error(InvalidSelection),
  )
  Ok(choices)
}

/// At most one compaction strategy runs: when several are enabled and one of
/// them is explicitly chosen, the others are dropped.
pub fn exclusive(
  items: List(a),
  strategy: fn(a) -> Bool,
  chosen: fn(a) -> Bool,
) -> List(a) {
  let strategies = list.filter(items, strategy)
  case list.length(strategies) > 1 && list.any(strategies, chosen) {
    True -> list.filter(items, fn(item) { !strategy(item) || chosen(item) })
    False -> items
  }
}

/// The built-in defaults with the user's global choices from the `enabled`
/// section of extensions.json applied. An unreadable file keeps the built-in
/// defaults so a bad edit cannot make every session fail to open.
fn global_defaults(built_in: List(String)) -> List(String) {
  let chosen = global_choices()
  let kept =
    list.filter(built_in, fn(name) { dict.get(chosen, name) != Ok(False) })
  let added =
    true_keys(chosen) |> list.filter(fn(name) { !list.contains(kept, name) })
  list.append(kept, added)
}

fn global_choices() -> dict.Dict(String, Bool) {
  bool_section("enabled")
}

/// One boolean section of extensions.json, empty when it cannot be read.
fn bool_section(section: String) -> dict.Dict(String, Bool) {
  settings.load(section, decode.dict(decode.string, decode.bool), dict.new())
  |> result.unwrap(dict.new())
}

/// The keys a boolean section sets to true.
fn true_keys(section: dict.Dict(String, Bool)) -> List(String) {
  section
  |> dict.to_list
  |> list.filter_map(fn(pair) {
    case pair.1 {
      True -> Ok(pair.0)
      False -> Error(Nil)
    }
  })
}

/// The global defaults with one compaction strategy: a strategy the user
/// enabled by name displaces a built-in default one, so installing a new
/// default strategy cannot break an older explicit choice.
pub fn resolved_defaults(
  installed: List(extension.Extension),
  built_in: List(String),
) -> List(String) {
  let chosen = global_choices()
  exclusive(global_defaults(built_in), compaction_named(installed, _), fn(name) {
    dict.get(chosen, name) == Ok(True)
  })
}

/// Models whose context cap the user raised, from the `raisedCaps` section
/// of extensions.json. An unreadable file raises nothing.
pub fn raised_caps() -> List(String) {
  true_keys(bool_section("raisedCaps"))
}

/// Raises or restores a model's context cap for every session.
pub fn raise_cap(model: String, raised: Bool) -> Result(Nil, String) {
  case raised {
    True -> set_entry(settings.home(), "raisedCaps", model, True)
    False -> remove_entry(settings.home(), "raisedCaps", model)
  }
}

/// The window a session on this model gets: the provider's maximum once the
/// user raised the cap, its default window otherwise.
pub fn window(info: extension.ModelInfo) -> Option(Int) {
  case info.max_context_tokens, list.contains(raised_caps(), info.model) {
    Some(max), True -> Some(max)
    _, _ -> info.context_tokens
  }
}

@external(erlang, "albedo_extension_settings", "set_entry")
fn set_entry(
  home: String,
  section: String,
  key: String,
  value: Bool,
) -> Result(Nil, String)

@external(erlang, "albedo_extension_settings", "remove_entry")
fn remove_entry(
  home: String,
  section: String,
  key: String,
) -> Result(Nil, String)

/// How a user changes which extensions a session runs. `SetSession` records a
/// choice for one session; `SetGlobal` changes the default every session
/// without its own choice follows; `Inherit` drops the session's choice.
pub type Change {
  SetSession(name: String, enabled: Bool)
  SetGlobal(name: String, enabled: Bool)
  Inherit(name: String)
}

pub fn change_name(change: Change) -> String {
  case change {
    SetSession(name, _) | SetGlobal(name, _) | Inherit(name) -> name
  }
}

/// The selection a session would run after `change`. Nothing is persisted;
/// `record` stores the change once its composition succeeds. A global change
/// must also leave sessions without their own choices with a valid selection.
pub fn propose(
  ledger: store.Store,
  installed: List(extension.Extension),
  default_enabled: List(String),
  session: String,
  change: Change,
) -> Result(List(extension.Extension), String) {
  let name = change_name(change)
  use _ <- result.try(
    extension.named(installed, name)
    |> result.replace_error("unknown extension: " <> name),
  )
  use current <- result.try(overrides(ledger, session))
  let defaults = resolved_defaults(installed, default_enabled)
  use _ <- result.try(case change {
    SetSession(name, False) ->
      case
        compaction_named(installed, name)
        && list.any(select(installed, defaults, current), fn(active) {
          active.name == name
        })
      {
        True -> Error("select another compaction strategy to replace " <> name)
        False -> Ok(Nil)
      }
    _ -> Ok(Nil)
  })
  let switching = case change {
    SetSession(_, True) | SetGlobal(_, True) ->
      compaction_named(installed, name)
    _ -> False
  }
  let survives = fn(other: String) -> Bool {
    other != name && { !switching || !compaction_named(installed, other) }
  }
  let #(defaults, current) = case change {
    SetSession(name, value) -> #(defaults, [
      #(name, value),
      ..list.filter(current, fn(pair) { survives(pair.0) })
    ])
    Inherit(name) -> #(
      defaults,
      list.filter(current, fn(pair) { pair.0 != name }),
    )
    SetGlobal(name, True) -> #(
      [name, ..list.filter(defaults, survives)],
      current,
    )
    SetGlobal(name, False) -> #(
      list.filter(defaults, fn(other) { other != name }),
      current,
    )
  }
  let current = case switching, change {
    True, SetSession(..) ->
      list.append(
        current,
        list.filter_map(installed, fn(ext) {
          case is_compaction(ext) && ext.name != name {
            True -> Ok(#(ext.name, False))
            False -> Error(Nil)
          }
        }),
      )
    _, _ -> current
  }
  use _ <- result.try(case change {
    SetGlobal(..) ->
      validate_selection(select(installed, defaults, []))
      |> result.map_error(fn(error) { "as the global default: " <> error })
    _ -> Ok(Nil)
  })
  let selected = select(installed, defaults, current)
  use _ <- result.try(validate_selection(selected))
  Ok(selected)
}

/// Whether another override or default keeps its place beside a compaction
/// switch: sibling strategies are displaced, everything else stays.
/// Persists a change `propose` accepted.
pub fn record(
  ledger: store.Store,
  session: String,
  change: Change,
) -> Result(Nil, String) {
  case change {
    SetSession(name, value) -> set_enabled(ledger, session, name, value)
    SetGlobal(name, value) -> set_global(settings.home(), name, value)
    Inherit(name) ->
      store.write(
        ledger,
        "DELETE FROM session_extensions WHERE session=? AND name=?",
        [sqlight.text(session), sqlight.text(name)],
      )
  }
}

@external(erlang, "albedo_extension_settings", "set_enabled")
fn set_global(home: String, name: String, enabled: Bool) -> Result(Nil, String)

pub fn is_compaction(ext: extension.Extension) -> Bool {
  list.any(ext.plugins, fn(plugin) {
    case plugin {
      extension.CompactionPlugin(_) -> True
      _ -> False
    }
  })
}

/// Whether `name` names a compaction strategy extension. First match is the
/// only match: `validate_registry` rejects duplicate names.
fn compaction_named(
  installed: List(extension.Extension),
  name: String,
) -> Bool {
  case extension.named(installed, name) {
    Ok(ext) -> is_compaction(ext)
    Error(_) -> False
  }
}

fn set_enabled(
  ledger: store.Store,
  session: String,
  name: String,
  value: Bool,
) -> Result(Nil, String) {
  write_changes(ledger, session, [#(name, value)])
}

/// Persist a strategy replacement and the explicit choice in one transaction.
pub fn record_selected(
  ledger: store.Store,
  session: String,
  change: Change,
  previous: List(extension.Extension),
  selected: List(extension.Extension),
  installed: List(extension.Extension),
) -> Result(Nil, String) {
  let name = change_name(change)
  let replacing = case change {
    SetSession(_, True) | SetGlobal(_, True) ->
      compaction_named(installed, name)
    _ -> False
  }
  case change, replacing {
    SetSession(..), True ->
      set_selection_with(ledger, session, previous, selected, #(name, True))
    SetGlobal(..), True -> {
      use _ <- result.try(
        list.try_each(installed, fn(other) {
          case other.name != name && is_compaction(other) {
            True -> set_global(settings.home(), other.name, False)
            False -> Ok(Nil)
          }
        }),
      )
      record(ledger, session, change)
    }
    _, _ -> record(ledger, session, change)
  }
}

fn set_selection_with(
  ledger: store.Store,
  session: String,
  previous: List(extension.Extension),
  selected: List(extension.Extension),
  explicit: #(String, Bool),
) -> Result(Nil, String) {
  let changes =
    list.append(
      entered(selected, previous, True),
      entered(previous, selected, False),
    )
  write_changes(ledger, session, [explicit, ..changes])
}

/// The extensions `side` runs and `other` does not, as (name, value) pairs.
fn entered(
  side: List(extension.Extension),
  other: List(extension.Extension),
  value: Bool,
) -> List(#(String, Bool)) {
  side
  |> list.filter(fn(item) {
    !list.any(other, fn(old) { old.name == item.name })
  })
  |> list.map(fn(item) { #(item.name, value) })
}

fn write_changes(
  ledger: store.Store,
  session: String,
  changes: List(#(String, Bool)),
) -> Result(Nil, String) {
  store.query(ledger, fn(db) {
    store.transaction(db, fn() {
      use _ <- result.try(family.available_in(db, session))
      use _ <- result.try(
        list.try_each(changes, fn(change) {
          store.run(
            db,
            "INSERT INTO session_extensions(session,name,enabled) VALUES(?,?,?) ON CONFLICT(session,name) DO UPDATE SET enabled=excluded.enabled",
            [
              sqlight.text(session),
              sqlight.text(change.0),
              sqlight.bool(change.1),
            ],
          )
        }),
      )
      store.run(
        db,
        "UPDATE sessions SET config_revision=config_revision+1 WHERE id=?",
        [sqlight.text(session)],
      )
    })
  })
}

/// Checks what a selection declares before anything is loaded or prepared.
/// `compose` repeats the capability check once managed contributions exist.
pub fn validate_selection(
  selected: List(extension.Extension),
) -> Result(Nil, String) {
  let names = list.map(selected, fn(ext) { ext.name })
  use _ <- result.try(
    selected
    |> list.try_each(fn(ext) {
      case
        list.find(ext.requires, fn(required) { !list.contains(names, required) })
      {
        Ok(missing) ->
          Error(ext.name <> " requires enabled extension " <> missing)
        Error(_) -> Ok(Nil)
      }
    }),
  )
  case extension.conflict(selected) {
    Some(reason) -> Error("enabled extensions have " <> reason)
    None -> Ok(Nil)
  }
}

pub type Glance {
  Glance(extension: String, value: page.Glance, url: String)
}

/// Read declared glances only for working loaded extensions. A failed owner
/// read fails the observation; an empty sidebar remains an observed value.
pub fn glances(
  composed: composition.Composition,
  ledger: store.Store,
  session: String,
  workspace: String,
) -> Result(List(Glance), String) {
  let failed = composition.inactive(composed) |> list.map(fn(item) { item.0 })
  let reads =
    composition.extensions(composed)
    |> list.filter(fn(item) { !list.contains(failed, item.name) })
    |> list.flat_map(fn(item) {
      item.plugins
      |> list.filter_map(fn(plugin) {
        case plugin {
          extension.GlancePlugin(read, resource_url) ->
            Ok(#(item.name, read, resource_url))
          _ -> Error(Nil)
        }
      })
    })
  list.try_map(list.take(reads, 16), fn(item) {
    use value <- result.try(
      protect.attempt(fn() { item.1(ledger, session, workspace) })
      |> result.replace_error("extension sidebar failed"),
    )
    use value <- result.try(value)
    Ok(Glance(
      item.0,
      page.Glance(value.title, list.take(value.rows, 12)),
      item.2(session, workspace),
    ))
  })
}

pub fn summaries(
  ledger: store.Store,
  installed: List(extension.Extension),
  quarantined: List(extension.Quarantined),
  default_enabled: List(String),
  session: String,
  composed: Option(composition.Composition),
) -> Result(List(extension.Summary), String) {
  use chosen <- result.try(overrides(ledger, session))
  let defaults = resolved_defaults(installed, default_enabled)
  let selected = select(installed, defaults, chosen)
  use _ <- result.try(validate_selection(selected))
  let names = list.map(selected, fn(ext) { ext.name })
  let managed = case composed {
    Some(composed) -> composition.managed(composed)
    None -> []
  }
  Ok(
    list.map(installed, fn(ext) {
      let values =
        list.append(
          extension.declared(ext),
          managed
            |> list.filter(fn(item) { item.extension == ext.name })
            |> list.map(fn(item) { item.value }),
        )
      extension.Summary(
        ext.name,
        ext.description,
        list.contains(names, ext.name),
        list.key_find(chosen, ext.name) |> result.is_ok,
        list.contains(defaults, ext.name),
        list.any(ext.plugins, fn(plugin) {
          case plugin {
            extension.ContextPlugin(_) | extension.ManagedPlugin(_) -> True
            _ -> False
          }
        }),
        values
          |> list.flat_map(fn(value) { value.tools })
          |> list.map(fn(tool) { tool.definition.name }),
        list.flat_map(values, fn(value) { value.python_modules }),
        ext.requires,
        list.map(ext.plugins, fn(plugin) {
          case plugin {
            extension.ContextPlugin(_) -> "context"
            extension.ToolPlugin(_, _, _, _) -> "tool"
            extension.ManagedPlugin(_) -> "managed"
            extension.CommandPlugin(_) -> "commands"
            extension.CompactionPlugin(_) -> "compaction"
            extension.NotesPlugin(_) -> "notes"
            extension.FoldPlugin(_) -> "folds"
            extension.ModelsPlugin(_) -> "models"
            extension.ModelProviderPlugin(_) -> "model_provider"
            extension.LoginPlugin(_) -> "login"
            extension.ServicePlugin(_) -> "service"
            extension.GlancePlugin(..) -> "glance"
            extension.ClientPlugin(_) -> "client"
            extension.MigrationPlugin(_) -> "migration"
            extension.CleanPlugin(_) -> "clean"
            extension.SearchPlugin(_) -> "search"
          }
        }),
        None,
      )
    })
    |> list.append(list.map(quarantined, quarantined_summary)),
  )
}

/// What a quarantined extension shows: no capabilities, never enabled, and
/// the reason the daemon will not run it.
fn quarantined_summary(failure: extension.Quarantined) -> extension.Summary {
  extension.Summary(
    name: failure.name,
    description: failure.description,
    enabled: False,
    overridden: False,
    global_enabled: False,
    context: False,
    tools: [],
    python_modules: [],
    requires: [],
    plugins: [],
    quarantined: Some(failure.reason),
  )
}

pub fn enabled(
  ledger: store.Store,
  installed: List(extension.Extension),
  default_enabled: List(String),
  session: String,
) -> Result(List(extension.Extension), String) {
  use overrides <- result.try(overrides(ledger, session))
  let selected =
    select(installed, resolved_defaults(installed, default_enabled), overrides)
  use _ <- result.try(validate_selection(selected))
  Ok(selected)
}

pub fn overrides(
  ledger: store.Store,
  session: String,
) -> Result(List(#(String, Bool)), String) {
  store.query(ledger, fn(db) {
    store.rows(
      db,
      "SELECT name,enabled FROM session_extensions WHERE session=?",
      [sqlight.text(session)],
      {
        use name <- decode.field(0, decode.string)
        use enabled <- decode.field(1, decode.int)
        decode.success(#(name, enabled == 1))
      },
    )
  })
}

/// A compaction strategy the session enabled by name displaces one that only
/// the defaults enable, as with a default strategy installed after the choice.
pub fn select(
  installed: List(extension.Extension),
  defaults: List(String),
  overrides: List(#(String, Bool)),
) -> List(extension.Extension) {
  let selected =
    list.filter(installed, fn(ext) {
      list.key_find(overrides, ext.name)
      |> result.unwrap(list.contains(defaults, ext.name))
    })
  let chosen = fn(ext: extension.Extension) {
    list.key_find(overrides, ext.name) == Ok(True)
  }
  exclusive(selected, is_compaction, chosen)
}
