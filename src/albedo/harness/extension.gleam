//// Extensions are ordered bundles of model context, tools, REPL modules, RPC routes, and request policies.

import albedo/daemon/store
import albedo/harness/command
import albedo/harness/compaction
import albedo/harness/extensions/python/kernel as python
import albedo/harness/oauth
import albedo/harness/settings
import albedo/openai_api/types
import gleam/dict
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

/// A host route: calls whose method starts with `namespace.` reach its handler.
pub type Route =
  #(String, fn(store.Store, String, String) -> String)

pub type Tool {
  Tool(
    definition: types.Tool,
    invoke: fn(Context, String) -> Result(Output, String),
    recover: fn(Context) -> Option(Output),
  )
}

/// A tool result: text, plus images the provider shows the model beside it.
pub type Output {
  Output(text: String, images: List(types.Image))
}

pub fn text(value: String) -> Output {
  Output(value, [])
}

pub type Managed {
  Managed(
    context: String,
    instructions: String,
    tools: List(Tool),
    python_modules: List(String),
    routes: List(Route),
    commands: List(command.Command),
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

pub type ModelCatalog {
  ModelCatalog(
    lookup: fn(String, String) -> Option(ModelInfo),
    list: fn(String, String) -> List(String),
  )
}

pub type ModelContext {
  ModelContext(
    home: String,
    session: String,
    profile: String,
    provider: String,
    model: String,
    protocol: types.Protocol,
  )
}

pub type ModelProvider {
  ModelProvider(
    catalog_provider: String,
    resolve: fn(ModelContext) -> Option(Result(types.Client, String)),
  )
}

pub type Plugin {
  ContextPlugin(load: fn(String) -> Result(String, String))
  ToolPlugin(
    instructions: String,
    tools: List(Tool),
    python_modules: List(String),
    routes: List(Route),
  )
  ManagedPlugin(
    prepare: fn(store.Store, String, String) -> Result(Managed, String),
  )
  /// Session commands shared by the CLI menu and the kernel's `commands` object.
  CommandPlugin(commands: List(command.Command))
  CompactionPlugin(strategy: compaction.Strategy)
  /// A catalog answers only for models and providers it actually lists.
  ModelsPlugin(catalog: ModelCatalog)
  /// A provider turns one tagged saved profile into a request client.
  ModelProviderPlugin(provider: ModelProvider)
  /// A browser sign-in the daemon runs on behalf of clients.
  LoginPlugin(login: oauth.Login)
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
    /// The session has its own choice for this extension; otherwise it
    /// follows the global default.
    overridden: Bool,
    /// What sessions without their own choice get.
    global_enabled: Bool,
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
  use overrides <- result.try(overrides(ledger, session))
  let selected = select(installed, global_defaults(default_enabled), overrides)
  use _ <- result.try(validate_selection(selected))
  Ok(selected)
}

fn overrides(
  ledger: store.Store,
  session: String,
) -> Result(List(#(String, Bool)), String) {
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
  })
}

fn select(
  installed: List(Extension),
  defaults: List(String),
  overrides: List(#(String, Bool)),
) -> List(Extension) {
  list.filter(installed, fn(extension) {
    list.key_find(overrides, extension.name)
    |> result.unwrap(list.contains(defaults, extension.name))
  })
}

/// The built-in defaults with the user's global choices from the `enabled`
/// section of extensions.json applied. An unreadable file keeps the built-in
/// defaults so a bad edit cannot make every session fail to open.
pub fn global_defaults(built_in: List(String)) -> List(String) {
  let chosen =
    settings.load(
      "enabled",
      decode.dict(decode.string, decode.bool),
      dict.new(),
    )
    |> result.unwrap(dict.new())
  let kept =
    list.filter(built_in, fn(name) { dict.get(chosen, name) != Ok(False) })
  let added =
    dict.to_list(chosen)
    |> list.filter_map(fn(pair) {
      case pair.1 && !list.contains(kept, pair.0) {
        True -> Ok(pair.0)
        False -> Error(Nil)
      }
    })
  list.append(kept, added)
}

/// How a user changes which extensions a session runs. `SetSession` records a
/// choice for one session; `SetGlobal` changes the default every session
/// without its own choice follows; `Inherit` drops the session's choice.
pub type Change {
  SetSession(name: String, enabled: Bool)
  SetGlobal(name: String, enabled: Bool)
  Inherit(name: String)
}

fn change_name(change: Change) -> String {
  case change {
    SetSession(name, _) | SetGlobal(name, _) | Inherit(name) -> name
  }
}

/// The selection a session would run after `change`. Nothing is persisted;
/// `record` stores the change once its composition succeeds. A global change
/// must also leave sessions without their own choices with a valid selection.
pub fn propose(
  ledger: store.Store,
  installed: List(Extension),
  default_enabled: List(String),
  session: String,
  change: Change,
) -> Result(List(Extension), String) {
  let name = change_name(change)
  use _ <- result.try(
    list.find(installed, fn(extension) { extension.name == name })
    |> result.replace_error("unknown extension: " <> name),
  )
  use current <- result.try(overrides(ledger, session))
  let defaults = global_defaults(default_enabled)
  let #(defaults, current) = case change {
    SetSession(name, value) -> #(defaults, [
      #(name, value),
      ..list.filter(current, fn(pair) { pair.0 != name })
    ])
    Inherit(name) -> #(
      defaults,
      list.filter(current, fn(pair) { pair.0 != name }),
    )
    SetGlobal(name, True) -> #(
      [name, ..list.filter(defaults, fn(other) { other != name })],
      current,
    )
    SetGlobal(name, False) -> #(
      list.filter(defaults, fn(other) { other != name }),
      current,
    )
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
      store.query(ledger, fn(db) {
        sqlight.query(
          "DELETE FROM session_extensions WHERE session=? AND name=?",
          db,
          [sqlight.text(session), sqlight.text(name)],
          decode.dynamic,
        )
        |> result.replace(Nil)
        |> result.map_error(fn(error) { error.message })
      })
  }
}

@external(erlang, "albedo_extension_settings", "set_enabled")
fn set_global(home: String, name: String, enabled: Bool) -> Result(Nil, String)

/// The selection that would result from toggling one extension for this
/// session. Nothing is persisted; `set_enabled` records the choice once its
/// composition succeeds.
pub fn selection(
  ledger: store.Store,
  installed: List(Extension),
  default_enabled: List(String),
  session: String,
  name: String,
  value: Bool,
) -> Result(List(Extension), String) {
  propose(ledger, installed, default_enabled, session, SetSession(name, value))
}

pub fn set_enabled(
  ledger: store.Store,
  session: String,
  name: String,
  value: Bool,
) -> Result(Nil, String) {
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
    |> result.replace(Nil)
    |> result.map_error(fn(error) { error.message })
  })
}

/// Checks what a selection declares before anything is loaded or prepared.
/// `compose` repeats the capability check once managed contributions exist.
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
  let compactions =
    list.flat_map(selected, fn(extension) {
      list.filter(extension.plugins, fn(plugin) {
        case plugin {
          CompactionPlugin(_) -> True
          _ -> False
        }
      })
    })
  case
    duplicate_capabilities(list.flat_map(selected, declared))
    || list.length(compactions) > 1
  {
    True ->
      Error(
        "enabled extensions have duplicate capabilities or multiple compaction strategies",
      )
    False -> Ok(Nil)
  }
}

/// One session's extension state, composed from nothing: every selected
/// extension's static contributions in registry order, then every prepared
/// managed plugin. It is never mutated. A refresh or reload composes a
/// replacement and closes whichever composition loses, so each contribution
/// applies exactly once and a plugin that disappears takes its tools with it.
pub opaque type Composition {
  Composition(
    extensions: List(Extension),
    contributions: List(Prepared),
    managed: List(Prepared),
  )
}

/// Load context and prepare managed plugins for one selection. A failure
/// closes everything already prepared and leaves no composition to own.
pub fn compose(
  selected: List(Extension),
  ledger: store.Store,
  session: String,
  workspace: String,
) -> Result(Composition, String) {
  use static <- result.try(
    list.try_map(selected, fn(extension) {
      list.try_map(extension.plugins, fn(plugin) {
        case plugin {
          ContextPlugin(load) ->
            load(workspace)
            |> result.map(fn(context) { [Managed(..empty(), context: context)] })
            |> result.map_error(fn(error) { extension.name <> ": " <> error })
          _ -> Ok(option.values([declare(plugin)]))
        }
      })
      |> result.map(fn(values) {
        values
        |> list.flatten
        |> list.map(Prepared(extension.name, _))
      })
    })
    |> result.map(list.flatten),
  )
  use managed <- result.try(prepare(selected, ledger, session, workspace))
  let composition = Composition(selected, list.append(static, managed), managed)
  case
    duplicate_capabilities(
      list.map(composition.contributions, fn(item) { item.value }),
    )
  {
    False -> Ok(composition)
    True -> {
      close(composition)
      Error("prepared extensions have duplicate capabilities")
    }
  }
}

/// Release every managed resource, newest first.
pub fn close(composition: Composition) -> Nil {
  close_prepared(composition.managed)
}

pub fn extensions(composition: Composition) -> List(Extension) {
  composition.extensions
}

/// Nonempty context blocks, labelled by the extension that supplied them.
pub fn context(composition: Composition) -> List(#(String, String)) {
  composition.contributions
  |> list.filter(fn(item) { string.trim(item.value.context) != "" })
  |> list.map(fn(item) { #(item.extension, item.value.context) })
}

pub fn instructions(composition: Composition) -> String {
  composition.contributions
  |> list.map(fn(item) { item.value.instructions })
  |> list.filter(fn(value) { string.trim(value) != "" })
  |> string.join("\n")
}

pub fn tools(composition: Composition) -> List(Tool) {
  list.flat_map(composition.contributions, fn(item) { item.value.tools })
}

pub fn python_modules(composition: Composition) -> List(String) {
  list.flat_map(composition.contributions, fn(item) {
    item.value.python_modules
  })
}

/// Every session command, in registry order. One list feeds the CLI menu,
/// the kernel bindings, and the aggregate command routes.
pub fn commands(composition: Composition) -> List(command.Command) {
  list.flat_map(composition.contributions, fn(item) { item.value.commands })
}

pub fn routes(composition: Composition) -> List(Route) {
  contribution_routes(
    list.map(composition.contributions, fn(item) { item.value }),
  )
}

/// Static commands declared by these extensions, without preparing any.
pub fn declared_commands(installed: List(Extension)) -> List(command.Command) {
  list.flat_map(installed, declared)
  |> list.flat_map(fn(value) { value.commands })
}

pub fn summaries(
  ledger: store.Store,
  installed: List(Extension),
  default_enabled: List(String),
  session: String,
  composition: Option(Composition),
) -> Result(List(Summary), String) {
  use selected <- result.try(enabled(
    ledger,
    installed,
    default_enabled,
    session,
  ))
  use chosen <- result.try(overrides(ledger, session))
  let defaults = global_defaults(default_enabled)
  let names = list.map(selected, fn(extension) { extension.name })
  let managed = case composition {
    Some(composition) -> composition.managed
    None -> []
  }
  Ok(
    list.map(installed, fn(extension) {
      let values =
        list.append(
          declared(extension),
          managed
            |> list.filter(fn(item) { item.extension == extension.name })
            |> list.map(fn(item) { item.value }),
        )
      Summary(
        extension.name,
        extension.description,
        list.contains(names, extension.name),
        list.key_find(chosen, extension.name) |> result.is_ok,
        list.contains(defaults, extension.name),
        list.any(extension.plugins, fn(plugin) {
          case plugin {
            ContextPlugin(_) | ManagedPlugin(_) -> True
            _ -> False
          }
        }),
        values
          |> list.flat_map(fn(value) { value.tools })
          |> list.map(fn(tool) { tool.definition.name }),
        list.flat_map(values, fn(value) { value.python_modules }),
        extension.requires,
        list.map(extension.plugins, fn(plugin) {
          case plugin {
            ContextPlugin(_) -> "context"
            ToolPlugin(_, _, _, _) -> "tool"
            ManagedPlugin(_) -> "managed"
            CommandPlugin(_) -> "commands"
            CompactionPlugin(_) -> "compaction"
            ModelsPlugin(_) -> "models"
            ModelProviderPlugin(_) -> "model_provider"
            LoginPlugin(_) -> "login"
          }
        }),
      )
    }),
  )
}

fn empty() -> Managed {
  Managed("", "", [], [], [], [], fn() { Nil })
}

/// A static plugin's contribution, known without loading or preparing it.
fn declare(plugin: Plugin) -> Option(Managed) {
  case plugin {
    ToolPlugin(instructions, tools, modules, routes) ->
      Some(
        Managed(
          ..empty(),
          instructions: instructions,
          tools: tools,
          python_modules: modules,
          routes: routes,
        ),
      )
    CommandPlugin(commands) -> Some(Managed(..empty(), commands: commands))
    _ -> None
  }
}

fn declared(extension: Extension) -> List(Managed) {
  extension.plugins |> list.map(declare) |> option.values
}

/// The aggregate command routes are included so capability validation sees
/// them: a plugin route cannot squat the "commands" namespace.
fn contribution_routes(values: List(Managed)) -> List(Route) {
  list.append(
    list.flat_map(values, fn(value) { value.routes }),
    command.routes(list.flat_map(values, fn(value) { value.commands })),
  )
}

fn duplicate_capabilities(values: List(Managed)) -> Bool {
  let tools =
    values
    |> list.flat_map(fn(value) { value.tools })
    |> list.map(fn(tool) { tool.definition.name })
  let modules =
    values
    |> list.flat_map(fn(value) { value.python_modules })
    |> list.map(canonical_module)
  let commands =
    values
    |> list.flat_map(fn(value) { value.commands })
    |> list.map(fn(command) { command.name })
  tools != list.unique(tools)
  || overlapping_routes(
    list.map(contribution_routes(values), fn(route) { route.0 }),
  )
  || modules != list.unique(modules)
  || commands != list.unique(commands)
}

/// Prepare every session-owned plugin in registry order. A failed prepare closes
/// all earlier values; a plugin that fails must close any resources it started itself.
fn prepare(
  installed: List(Extension),
  ledger: store.Store,
  session: String,
  workspace: String,
) -> Result(List(Prepared), String) {
  installed
  |> list.flat_map(fn(extension) {
    list.filter_map(extension.plugins, fn(plugin) {
      case plugin {
        ManagedPlugin(run) -> Ok(#(extension.name, run))
        _ -> Error(Nil)
      }
    })
  })
  |> list.try_fold([], fn(prepared, item) {
    let #(name, run) = item
    case run(ledger, session, workspace) {
      Ok(value) -> Ok([Prepared(name, value), ..prepared])
      Error(error) -> {
        close_prepared(list.reverse(prepared))
        Error(name <> ": " <> error)
      }
    }
  })
  |> result.map(list.reverse)
}

fn close_prepared(prepared: List(Prepared)) -> Nil {
  prepared
  |> list.reverse
  |> list.each(fn(item) { item.value.close() })
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
        ModelsPlugin(catalog) -> Ok(catalog.lookup)
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

/// The first enabled catalog that lists this provider or endpoint answers.
pub fn model_names(
  installed: List(Extension),
  provider: String,
  endpoint: String,
) -> List(String) {
  installed
  |> list.flat_map(fn(extension) {
    list.filter_map(extension.plugins, fn(plugin) {
      case plugin {
        ModelsPlugin(catalog) -> Ok(catalog.list)
        _ -> Error(Nil)
      }
    })
  })
  |> list.fold_until([], fn(_, list_models) {
    case list_models(provider, endpoint) {
      [] -> list.Continue([])
      names -> list.Stop(names)
    }
  })
}

/// The first provider plugin claiming the saved profile owns its client.
/// Resolve an extension's declared models.dev namespace through enabled catalogs.
pub fn provider_model_names(
  installed: List(Extension),
  provider: String,
  endpoint: String,
) -> List(String) {
  installed
  |> list.find(fn(item) { item.name == provider })
  |> result.try(fn(item) {
    item.plugins
    |> list.find_map(fn(plugin) {
      case plugin {
        ModelProviderPlugin(value) -> Ok(value.catalog_provider)
        _ -> Error(Nil)
      }
    })
  })
  |> result.map(fn(catalog_provider) {
    model_names(installed, catalog_provider, endpoint)
  })
  |> result.unwrap([])
}

pub fn logins(installed: List(Extension)) -> List(oauth.Login) {
  list.flat_map(installed, fn(extension) {
    list.filter_map(extension.plugins, fn(plugin) {
      case plugin {
        LoginPlugin(login) -> Ok(login)
        _ -> Error(Nil)
      }
    })
  })
}

pub fn model_client(
  installed: List(Extension),
  context: ModelContext,
) -> Result(types.Client, String) {
  installed
  |> list.flat_map(fn(extension) {
    list.filter_map(extension.plugins, fn(plugin) {
      case plugin {
        ModelProviderPlugin(provider) -> Ok(provider.resolve)
        _ -> Error(Nil)
      }
    })
  })
  |> list.fold_until(
    Error("no enabled model provider extension handles this profile"),
    fn(_, resolve) {
      case resolve(context) {
        None ->
          list.Continue(Error(
            "no enabled model provider extension handles this profile",
          ))
        Some(answer) -> list.Stop(answer)
      }
    },
  )
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
