//// Extensions are ordered bundles of model context, tools, REPL modules, RPC routes, and request policies.

import albedo/daemon/store
import albedo/harness/compaction
import albedo/harness/python/kernel as python
import albedo/openai_api/types
import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import sqlight

pub type Context {
  Context(
    store: store.Store,
    session: String,
    kernel: python.Kernel,
    call_id: String,
    workspace: String,
  )
}

pub type Tool {
  Tool(
    definition: types.Tool,
    invoke: fn(Context, String) -> Result(String, String),
    recover: fn(Context) -> Option(String),
  )
}

pub type Managed {
  Managed(
    context: String,
    instructions: String,
    tools: List(Tool),
    python_modules: List(String),
    routes: List(#(String, fn(store.Store, String, String) -> String)),
    close: fn() -> Nil,
  )
}

pub type Prepared {
  Prepared(extension: String, value: Managed)
}

/// Locally known facts about one model, read from a catalog rather than guessed.
pub type ModelInfo {
  ModelInfo(
    model: String,
    provider: String,
    context_tokens: Option(Int),
    max_output_tokens: Option(Int),
    input_modalities: List(String),
    endpoint: Option(String),
    environment: List(String),
    source: String,
  )
}

pub type Plugin {
  ContextPlugin(load: fn(String) -> Result(String, String))
  ToolPlugin(
    instructions: String,
    tools: List(Tool),
    python_modules: List(String),
    routes: List(#(String, fn(store.Store, String, String) -> String)),
  )
  ManagedPlugin(
    prepare: fn(store.Store, String, String) -> Result(Managed, String),
  )
  CompactionPlugin(strategy: compaction.Strategy)
  /// `lookup(model, endpoint)` answers only for models a catalog actually lists.
  ModelsPlugin(lookup: fn(String, String) -> Option(ModelInfo))
}

pub type Extension {
  Extension(
    name: String,
    description: String,
    requires: List(String),
    plugins: List(Plugin),
    initialise: fn(store.Store) -> Result(Nil, String),
  )
}

pub type Summary {
  Summary(
    name: String,
    description: String,
    enabled: Bool,
    context: Bool,
    tools: List(String),
    python_modules: List(String),
    requires: List(String),
    plugins: List(String),
  )
}

pub fn python_module(
  name: String,
  description: String,
  module: String,
  instructions: String,
  requires: List(String),
) -> Extension {
  Extension(
    name,
    description,
    requires,
    [ToolPlugin(instructions, [], [module], [])],
    fn(_) { Ok(Nil) },
  )
}

/// Registry validity does not require every extension to be co-enabled. This permits
/// installing alternative compaction policies whose defaults select at most one.
pub fn install(
  installed: List(Extension),
  default_enabled: List(String),
  ledger: store.Store,
) -> Result(Nil, String) {
  use _ <- result.try(validate_registry(installed, default_enabled))
  let defaults =
    list.filter(installed, fn(extension) {
      list.contains(default_enabled, extension.name)
    })
  use _ <- result.try(validate_selection(defaults))
  use _ <- result.try(
    store.query(ledger, fn(db) {
      sqlight.exec(
        "CREATE TABLE IF NOT EXISTS session_extensions(session TEXT NOT NULL,name TEXT NOT NULL,enabled INTEGER NOT NULL CHECK(enabled IN (0,1)),PRIMARY KEY(session,name));",
        db,
      )
      |> result.replace(Nil)
      |> result.map_error(fn(error) { error.message })
    }),
  )
  list.try_each(installed, fn(extension) { extension.initialise(ledger) })
}

fn validate_registry(
  installed: List(Extension),
  defaults: List(String),
) -> Result(Nil, String) {
  let names = list.map(installed, fn(extension) { extension.name })
  case
    list.any(names, fn(name) { string.trim(name) == "" })
    || names != list.unique(names)
    || defaults != list.unique(defaults)
    || !list.all(defaults, list.contains(names, _))
    || list.any(installed, fn(extension) {
      !list.all(extension.requires, list.contains(names, _))
    })
  {
    True -> Error("duplicate or invalid extension registry/default selection")
    False -> Ok(Nil)
  }
}

pub fn enabled(
  ledger: store.Store,
  installed: List(Extension),
  default_enabled: List(String),
  session: String,
) -> Result(List(Extension), String) {
  use overrides <- result.try(
    store.query(ledger, fn(db) {
      sqlight.query(
        "SELECT name,enabled FROM session_extensions WHERE session=?",
        db,
        [sqlight.text(session)],
        {
          use name <- decode.field(0, decode.string)
          use enabled <- decode.field(1, decode.int)
          decode.success(#(name, enabled == 1))
        },
      )
      |> result.map_error(fn(error) { error.message })
    }),
  )
  let selected =
    list.filter(installed, fn(extension) {
      list.key_find(overrides, extension.name)
      |> result.unwrap(list.contains(default_enabled, extension.name))
    })
  use _ <- result.try(validate_selection(selected))
  Ok(selected)
}

pub fn selection(
  ledger: store.Store,
  installed: List(Extension),
  default_enabled: List(String),
  session: String,
  name: String,
  value: Bool,
) -> Result(List(Extension), String) {
  use _ <- result.try(
    list.find(installed, fn(extension) { extension.name == name })
    |> result.replace_error("unknown extension: " <> name),
  )
  use selected <- result.try(enabled(
    ledger,
    installed,
    default_enabled,
    session,
  ))
  let candidate = case value {
    True ->
      list.filter(installed, fn(extension) {
        extension.name == name
        || list.any(selected, fn(active) { active.name == extension.name })
      })
    False -> list.filter(selected, fn(extension) { extension.name != name })
  }
  use _ <- result.try(validate_selection(candidate))
  Ok(candidate)
}

pub fn set_enabled(
  ledger: store.Store,
  installed: List(Extension),
  default_enabled: List(String),
  session: String,
  name: String,
  value: Bool,
) -> Result(List(Extension), String) {
  use candidate <- result.try(selection(
    ledger,
    installed,
    default_enabled,
    session,
    name,
    value,
  ))
  store.query(ledger, fn(db) {
    sqlight.query(
      "INSERT INTO session_extensions(session,name,enabled) VALUES(?,?,?) ON CONFLICT(session,name) DO UPDATE SET enabled=excluded.enabled",
      db,
      [
        sqlight.text(session),
        sqlight.text(name),
        sqlight.int(case value {
          True -> 1
          False -> 0
        }),
      ],
      decode.dynamic,
    )
    |> result.replace(candidate)
    |> result.map_error(fn(error) { error.message })
  })
}

fn validate_selection(selected: List(Extension)) -> Result(Nil, String) {
  let names = list.map(selected, fn(extension) { extension.name })
  use _ <- result.try(
    selected
    |> list.try_each(fn(extension) {
      case
        list.find(extension.requires, fn(required) {
          !list.contains(names, required)
        })
      {
        Ok(missing) ->
          Error(extension.name <> " requires enabled extension " <> missing)
        Error(_) -> Ok(Nil)
      }
    }),
  )
  let tools = selected |> tools |> list.map(fn(tool) { tool.definition.name })
  let routes = selected |> routes |> list.map(fn(route) { route.0 })
  let modules = selected |> modules |> list.map(canonical_module)
  let compactions =
    selected
    |> list.flat_map(fn(extension) {
      list.filter(extension.plugins, fn(plugin) {
        case plugin {
          CompactionPlugin(_) -> True
          _ -> False
        }
      })
    })
  case
    tools != list.unique(tools)
    || overlapping_routes(routes)
    || modules != list.unique(modules)
    || list.length(compactions) > 1
  {
    True ->
      Error(
        "enabled extensions have duplicate capabilities or multiple compaction strategies",
      )
    False -> Ok(Nil)
  }
}

pub fn summaries(
  ledger: store.Store,
  installed: List(Extension),
  default_enabled: List(String),
  session: String,
) -> Result(List(Summary), String) {
  materialized_summaries(ledger, installed, default_enabled, session, [])
}

pub fn materialized_summaries(
  ledger: store.Store,
  installed: List(Extension),
  default_enabled: List(String),
  session: String,
  prepared: List(Prepared),
) -> Result(List(Summary), String) {
  use selected <- result.try(enabled(
    ledger,
    installed,
    default_enabled,
    session,
  ))
  let names = list.map(selected, fn(extension) { extension.name })
  Ok(
    list.map(installed, fn(extension) {
      let managed =
        list.filter(prepared, fn(item) { item.extension == extension.name })
      Summary(
        extension.name,
        extension.description,
        list.contains(names, extension.name),
        list.any(extension.plugins, fn(plugin) {
          case plugin {
            ContextPlugin(_) | ManagedPlugin(_) -> True
            _ -> False
          }
        }),
        list.append(
          extension.plugins
            |> tool_values
            |> list.map(fn(tool) { tool.definition.name }),
          managed
            |> list.flat_map(fn(item) { item.value.tools })
            |> list.map(fn(tool) { tool.definition.name }),
        ),
        list.append(
          module_values(extension.plugins),
          list.flat_map(managed, fn(item) { item.value.python_modules }),
        ),
        extension.requires,
        list.map(extension.plugins, fn(plugin) {
          case plugin {
            ContextPlugin(_) -> "context"
            ToolPlugin(_, _, _, _) -> "tool"
            ManagedPlugin(_) -> "managed"
            CompactionPlugin(_) -> "compaction"
            ModelsPlugin(_) -> "models"
          }
        }),
      )
    }),
  )
}

pub fn context(
  installed: List(Extension),
  workspace: String,
) -> Result(List(#(String, String)), String) {
  installed
  |> list.try_fold([], fn(loaded, extension) {
    use values <- result.try(
      extension.plugins
      |> list.filter_map(fn(plugin) {
        case plugin {
          ContextPlugin(load) -> Ok(load)
          _ -> Error(Nil)
        }
      })
      |> list.try_map(fn(load) {
        load(workspace)
        |> result.map_error(fn(error) { extension.name <> ": " <> error })
      }),
    )
    Ok(list.append(
      loaded,
      list.map(values, fn(value) { #(extension.name, value) }),
    ))
  })
}

/// Prepare every session-owned plugin in registry order. A failed prepare closes
/// all earlier values; a plugin that fails must close any resources it started itself.
pub fn prepare(
  installed: List(Extension),
  ledger: store.Store,
  session: String,
  workspace: String,
) -> Result(List(Prepared), String) {
  let preparations =
    installed
    |> list.flat_map(fn(extension) {
      extension.plugins
      |> list.filter_map(fn(plugin) {
        case plugin {
          ManagedPlugin(run) -> Ok(#(extension.name, run))
          _ -> Error(Nil)
        }
      })
    })
  use prepared <- result.try(do_prepare(
    preparations,
    [],
    ledger,
    session,
    workspace,
  ))
  case validate_materialized(installed, prepared) {
    Ok(_) -> Ok(prepared)
    Error(error) -> {
      close(prepared)
      Error(error)
    }
  }
}

fn do_prepare(
  remaining: List(
    #(String, fn(store.Store, String, String) -> Result(Managed, String)),
  ),
  prepared: List(Prepared),
  ledger: store.Store,
  session: String,
  workspace: String,
) -> Result(List(Prepared), String) {
  case remaining {
    [] -> Ok(list.reverse(prepared))
    [#(name, run), ..rest] ->
      case run(ledger, session, workspace) {
        Ok(value) ->
          do_prepare(
            rest,
            [Prepared(name, value), ..prepared],
            ledger,
            session,
            workspace,
          )
        Error(error) -> {
          close(list.reverse(prepared))
          Error(name <> ": " <> error)
        }
      }
  }
}

pub fn close(prepared: List(Prepared)) -> Nil {
  prepared
  |> list.reverse
  |> list.each(fn(item) { item.value.close() })
}

pub fn managed_context(prepared: List(Prepared)) -> List(#(String, String)) {
  list.map(prepared, fn(item) { #(item.extension, item.value.context) })
}

pub fn materialized_tools(
  installed: List(Extension),
  prepared: List(Prepared),
) -> List(Tool) {
  list.append(
    tools(installed),
    list.flat_map(prepared, fn(item) { item.value.tools }),
  )
}

pub fn materialized_modules(
  installed: List(Extension),
  prepared: List(Prepared),
) -> List(String) {
  list.append(
    modules(installed),
    list.flat_map(prepared, fn(item) { item.value.python_modules }),
  )
}

pub fn materialized_routes(
  installed: List(Extension),
  prepared: List(Prepared),
) -> List(#(String, fn(store.Store, String, String) -> String)) {
  list.append(
    routes(installed),
    list.flat_map(prepared, fn(item) { item.value.routes }),
  )
}

pub fn materialized_instructions(
  installed: List(Extension),
  prepared: List(Prepared),
) -> String {
  [
    instructions(installed),
    ..list.map(prepared, fn(item) { item.value.instructions })
  ]
  |> list.filter(fn(value) { string.trim(value) != "" })
  |> string.join("\n")
}

fn validate_materialized(
  installed: List(Extension),
  prepared: List(Prepared),
) -> Result(Nil, String) {
  let tools =
    materialized_tools(installed, prepared)
    |> list.map(fn(tool) { tool.definition.name })
  let routes =
    materialized_routes(installed, prepared)
    |> list.map(fn(route) { route.0 })
  let modules =
    materialized_modules(installed, prepared)
    |> list.map(canonical_module)
  case
    tools != list.unique(tools)
    || overlapping_routes(routes)
    || modules != list.unique(modules)
  {
    True -> Error("prepared extensions have duplicate capabilities")
    False -> Ok(Nil)
  }
}

pub fn tools(installed: List(Extension)) -> List(Tool) {
  list.flat_map(installed, fn(extension) { tool_values(extension.plugins) })
}

pub fn modules(installed: List(Extension)) -> List(String) {
  list.flat_map(installed, fn(extension) { module_values(extension.plugins) })
}

pub fn routes(
  installed: List(Extension),
) -> List(#(String, fn(store.Store, String, String) -> String)) {
  list.flat_map(installed, fn(extension) { route_values(extension.plugins) })
}

pub fn instructions(installed: List(Extension)) -> String {
  installed
  |> list.flat_map(fn(extension) {
    list.filter_map(extension.plugins, fn(plugin) {
      case plugin {
        ToolPlugin(value, _, _, _) ->
          case string.trim(value) {
            "" -> Error(Nil)
            _ -> Ok(value)
          }
        _ -> Error(Nil)
      }
    })
  })
  |> string.join("\n")
}

pub fn compaction(installed: List(Extension)) -> Option(compaction.Strategy) {
  installed
  |> list.flat_map(fn(extension) {
    list.filter_map(extension.plugins, fn(plugin) {
      case plugin {
        CompactionPlugin(value) -> Ok(value)
        _ -> Error(Nil)
      }
    })
  })
  |> list.first
  |> option.from_result
}

/// The first enabled catalog that knows this model answers.
pub fn model_info(
  installed: List(Extension),
  model: String,
  endpoint: String,
) -> Option(ModelInfo) {
  installed
  |> list.flat_map(fn(extension) {
    list.filter_map(extension.plugins, fn(plugin) {
      case plugin {
        ModelsPlugin(lookup) -> Ok(lookup)
        _ -> Error(Nil)
      }
    })
  })
  |> list.fold_until(None, fn(_, lookup) {
    case lookup(model, endpoint) {
      Some(info) -> list.Stop(Some(info))
      None -> list.Continue(None)
    }
  })
}

fn tool_values(plugins: List(Plugin)) -> List(Tool) {
  list.flat_map(plugins, fn(plugin) {
    case plugin {
      ToolPlugin(_, values, _, _) -> values
      _ -> []
    }
  })
}

fn module_values(plugins: List(Plugin)) -> List(String) {
  list.flat_map(plugins, fn(plugin) {
    case plugin {
      ToolPlugin(_, _, values, _) -> values
      _ -> []
    }
  })
}

fn route_values(
  plugins: List(Plugin),
) -> List(#(String, fn(store.Store, String, String) -> String)) {
  list.flat_map(plugins, fn(plugin) {
    case plugin {
      ToolPlugin(_, _, _, values) -> values
      _ -> []
    }
  })
}

fn canonical_module(name: String) -> String {
  case string.contains(name, ".") {
    True -> name
    False -> "albedo_plugins." <> name
  }
}

fn overlapping_routes(routes: List(String)) -> Bool {
  case routes {
    [] -> False
    [route, ..rest] ->
      route == ""
      || list.any(rest, fn(other) {
        route == other
        || string.starts_with(route, other <> ".")
        || string.starts_with(other, route <> ".")
      })
      || overlapping_routes(rest)
  }
}
