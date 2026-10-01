//// Extensions are ordered bundles of model context, tools, REPL modules, RPC routes, and request policies.

import albedo/daemon/conversation
import albedo/daemon/requests
import albedo/daemon/store
import albedo/harness/command
import albedo/harness/compaction
import albedo/harness/extensions/python/kernel as python
import albedo/harness/oauth
import albedo/harness/protect
import albedo/harness/settings
import albedo/openai_api/types
import gleam/bool
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import mist
import sqlight

pub type Context {
  Context(
    store: store.Store,
    session: String,
    kernel: python.Kernel,
    call_id: String,
    workspace: String,
    /// What the session's provider takes, so a tool never hands the model
    /// an image its next request would be refused for.
    images: types.ImageLimits,
  )
}

/// A host route: calls whose method starts with `namespace.` reach its handler.
pub type Route =
  #(String, fn(store.Store, String, String) -> String)

pub type Tool {
  Tool(
    definition: types.Tool,
    invoke: fn(Context, String) -> Result(Output, Failure),
    recover: fn(Context) -> Option(Output),
  )
}

/// Why a tool call produced no result.
pub type Failure {
  /// The call did not work. The model is told why and the turn continues.
  Refused(String)
  /// The turn ends: the host could not record what the call did, and the
  /// model must not be invited to retry something that may already have run.
  Fatal(String)
}

/// A tool result: text, plus images the provider shows the model beside it.
pub type Output {
  Output(text: String, images: List(types.Image))
}

pub fn text(value: String) -> Output {
  Output(value, [])
}

/// `tool` run on `arguments`, with a crash answered as a refusal: an
/// extension's bug costs the model one call rather than the turn.
pub fn invoke(
  tool: Tool,
  context: Context,
  arguments: String,
) -> Result(Output, Failure) {
  case protect.attempt(fn() { tool.invoke(context, arguments) }) {
    Ok(result) -> result
    Error(crash) ->
      Error(Refused(
        tool.definition.name
        <> " crashed: "
        <> crash
        <> ". Its effects are unknown; inspect them before any retry.",
      ))
  }
}

/// `tool`'s saved result for an interrupted call, or `None` if it saved
/// nothing or crashed looking.
pub fn recover(tool: Tool, context: Context) -> Option(Output) {
  case protect.attempt(fn() { tool.recover(context) }) {
    Ok(saved) -> saved
    Error(_) -> None
  }
}

pub type Managed {
  Managed(
    context: String,
    instructions: String,
    tools: List(Tool),
    python_modules: List(String),
    routes: List(Route),
    commands: List(command.Command),
    warnings: List(String),
    /// Hears the session's events; see `SessionEvent`.
    observe: fn(Session, SessionEvent) -> Nil,
    close: fn() -> Nil,
  )
}

/// What a session reports to its managed extensions as it works, in order.
/// `observe` runs inside the session actor, so it must only send and return.
pub type SessionEvent {
  /// A provider call of a turn succeeded.
  CallSent(call: SentCall)
  /// A turn ended; a cancelled one was stopped before it finished.
  TurnEnded(cancelled: Bool)
  /// A forced compaction rewrote the history the next turn sends.
  Compacted
  /// Something new reached the session: a submit, a note, a wake, or a
  /// change of model, effort, workspace, or extensions.
  Stirred
}

/// One successful provider call, as it went out.
pub type SentCall {
  SentCall(
    request: types.Request,
    /// The prefix identity its request row carries.
    prefix: requests.Prefix,
    usage: Option(types.Usage),
    /// Where the request asked the provider to cache.
    marks: List(types.CacheMark),
    /// The saved profile, endpoint, and protocol it was sent through.
    profile: String,
    endpoint: String,
    protocol: types.Protocol,
    started_ms: Int,
    finished_ms: Int,
  )
}

/// What a managed extension can ask of the session reporting to it.
pub type Session {
  Session(
    id: String,
    /// Sends `request` on the session's upstream as exclusive work that
    /// never reaches the transcript or the stream; its provider request row
    /// carries `prefix` and the kind `background`. Blocks until the call
    /// ends and answers its usage; fails at once while another run holds
    /// the session or its kernel is released.
    call: fn(types.Request, requests.Prefix) ->
      Result(Option(types.Usage), String),
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
    /// The window a session gets unless its cap is raised.
    context_tokens: Option(Int),
    /// The largest window the provider allows once the user raises the cap;
    /// `None` when it offers nothing past `context_tokens`.
    max_context_tokens: Option(Int),
    max_output_tokens: Option(Int),
    input_modalities: List(String),
    endpoint: Option(String),
    environment: List(String),
    source: String,
    efforts: List(String),
  )
}

/// A ModelInfo with only identity filled in: the base a catalog constructor
/// record-updates per model rather than passing dummy values for every field.
pub fn blank_model(model: String, provider: String) -> ModelInfo {
  ModelInfo(model, provider, None, None, None, [], None, [], "", [])
}

/// Picks the default reasoning effort: "medium" when supported, otherwise the
/// first available tier above medium (e.g. "high", "xhigh", "max"), or the
/// highest tier available. Models without reasoning return `None`.
pub fn default_effort(efforts: List(String)) -> Option(String) {
  case efforts {
    [] -> None
    _ ->
      list.find(efforts, fn(e) { e == "medium" })
      |> result.lazy_or(fn() {
        list.find(efforts, fn(e) { e == "high" || e == "xhigh" || e == "max" })
      })
      |> result.lazy_or(fn() { list.last(efforts) })
      |> option.from_result
  }
}

pub type ModelCatalog {
  ModelCatalog(
    lookup: fn(String, Option(String)) -> Option(ModelInfo),
    list: fn(String, Option(String)) -> List(String),
    /// Refetches the list this catalog caches, whatever its age, and reports
    /// a failed fetch; `None` for a catalog that caches nothing of its own.
    reload: Option(fn() -> Result(Nil, String)),
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
    effort: Option(String),
  )
}

/// Where a session's requests go. A provider streams albedo's request types
/// over whatever wire it speaks and explains failures the user can act on.
pub type Upstream {
  Upstream(
    /// The provider base url; catalogs use it to tell shared model ids apart.
    endpoint: String,
    /// The shape of the replay items this upstream produces and accepts.
    protocol: types.Protocol,
    stream: fn(types.Request, fn(types.Event) -> types.Control) ->
      Result(types.Turn, types.Error),
    explain: fn(types.Error) -> Option(String),
    /// The non-secret label of the account that served the most recent
    /// request, when the provider has an account pool to name one from.
    account: fn() -> Option(String),
    /// Where this upstream marks a request's cached prefixes; empty when the
    /// provider decides what to cache on its own.
    cache_marks: fn(types.Request) -> List(types.CacheMark),
    images: types.ImageLimits,
  )
}

pub type ModelProvider {
  ModelProvider(
    catalog_provider: String,
    resolve: fn(ModelContext) -> Option(Result(Upstream, String)),
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
  /// Stored folds any compaction strategy can read through its context.
  FoldPlugin(folds: compaction.Folds)
  /// A catalog answers only for models and providers it actually lists.
  ModelsPlugin(catalog: ModelCatalog)
  /// A provider turns one tagged saved profile into its upstream.
  ModelProviderPlugin(provider: ModelProvider)
  /// A browser sign-in the daemon runs on behalf of clients.
  LoginPlugin(login: oauth.Login)
  /// HTTP routes the daemon serves under `/<extension>/` while the extension
  /// is enabled globally.
  ServicePlugin(service: Service)
  /// SQLite upgrades owned by this extension, applied by the host at startup.
  MigrationPlugin(migration: Migration)
}

pub type Migration {
  /// Applied immediately after the owning extension creates its tables.
  SchemaMigration(apply: fn(sqlight.Connection) -> Result(Nil, String))
  /// Applied after core data upgrades, with the same pre-upgrade backup path.
  /// Returns the number of rows rewritten for startup reporting.
  DataMigration(
    name: String,
    run: fn(store.Store, String) -> Result(Int, String),
  )
}

/// Handles a request below the extension's mount point. The daemon token does
/// not apply: a service owns its own authentication.
pub type Service {
  Service(
    handle: fn(Daemon, List(String), request.Request(mist.Connection)) ->
      response.Response(mist.ResponseData),
  )
}

/// What a service can reach. It serves requests outside any session, so
/// upstreams resolve with the global extension selection.
pub type Daemon {
  Daemon(
    home: String,
    /// The daemon's serialized durable store, also used by session ledgers.
    ledger: store.Store,
    /// The upstream a saved profile resolves to for `model`, with `session`
    /// naming the conversation for providers that keep per-session identity.
    upstream: fn(String, String, String) -> Result(Upstream, String),
    /// Catalog model ids for a provider extension and endpoint.
    models: fn(String, Option(String)) -> List(String),
    sessions: fn() -> List(conversation.Info),
  )
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
    /// Why the daemon will not run this extension, when it quarantined it.
    quarantined: Option(String),
  )
}

/// An installed extension the daemon will not run, with the reason. No
/// session selects it; it is listed so the failure is visible.
pub type Quarantined {
  Quarantined(name: String, description: String, reason: String)
}

/// The initialiser of an extension that keeps no tables.
pub fn no_initialise(_ledger: store.Store) -> Result(Nil, String) {
  Ok(Nil)
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
    no_initialise,
  )
}

/// Install every extension, quarantining each one the daemon cannot run:
/// a blank or repeated name, a missing requirement, an initialiser that
/// fails or raises, or a default selection it makes invalid. The daemon
/// starts on the rest; only storage the host owns stops it.
pub fn install(
  installed: List(Extension),
  default_enabled: List(String),
  ledger: store.Store,
) -> Result(#(List(Extension), List(Quarantined)), String) {
  use _ <- result.try(
    store.query(ledger, fn(db) {
      store.exec(
        db,
        "CREATE TABLE IF NOT EXISTS session_extensions(session TEXT NOT NULL,name TEXT NOT NULL,enabled INTEGER NOT NULL CHECK(enabled IN (0,1)),PRIMARY KEY(session,name));",
      )
    }),
  )
  let #(installed, unnamed) = distinctly_named(installed)
  let #(installed, unstarted) = started(installed, ledger)
  let #(installed, unmet) = satisfied(installed)
  let #(installed, conflicting) = agreeable(installed, default_enabled)
  Ok(#(installed, list.flatten([unnamed, unstarted, unmet, conflicting])))
}

fn quarantined(extension: Extension, reason: String) -> Quarantined {
  Quarantined(extension.name, extension.description, reason)
}

/// Split `installed` in order: each extension `check` accepts is kept, and
/// each one it refuses is quarantined with the reason it gave. `check` sees
/// what has been kept so far, since a conflict is with an earlier one.
fn sift(
  installed: List(Extension),
  check: fn(List(Extension), Extension) -> Result(Nil, String),
) -> #(List(Extension), List(Quarantined)) {
  let #(kept, rejected) =
    list.fold(installed, #([], []), fn(state, extension) {
      let #(kept, rejected) = state
      case check(kept, extension) {
        Ok(_) -> #([extension, ..kept], rejected)
        Error(reason) -> #(kept, [quarantined(extension, reason), ..rejected])
      }
    })
  #(list.reverse(kept), list.reverse(rejected))
}

/// Extensions with a name of their own, and the ones whose name is blank or
/// already taken by an earlier one.
fn distinctly_named(
  installed: List(Extension),
) -> #(List(Extension), List(Quarantined)) {
  sift(installed, fn(kept, extension) {
    let taken =
      list.any(kept, fn(other: Extension) { other.name == extension.name })
    case string.trim(extension.name), taken {
      "", _ -> Error("its name is blank")
      _, True -> Error("another installed extension has this name")
      _, False -> Ok(Nil)
    }
  })
}

/// Extensions whose tables and schema upgrades are in place, and the ones
/// whose initialiser failed or raised.
fn started(
  installed: List(Extension),
  ledger: store.Store,
) -> #(List(Extension), List(Quarantined)) {
  sift(installed, fn(_, extension) {
    protect.guarded(fn() {
      use _ <- result.try(extension.initialise(ledger))
      list.try_each(extension.plugins, fn(plugin) {
        case plugin {
          MigrationPlugin(SchemaMigration(apply)) -> store.query(ledger, apply)
          _ -> Ok(Nil)
        }
      })
    })
    |> result.map_error(fn(error) { "it did not install: " <> error })
  })
}

/// Extensions whose requirements are all installed, and the ones missing
/// one. Quarantine cascades: what an absent extension was needed for cannot
/// run either.
fn satisfied(
  installed: List(Extension),
) -> #(List(Extension), List(Quarantined)) {
  let names = list.map(installed, fn(extension) { extension.name })
  let unmet = fn(extension: Extension) {
    list.filter(extension.requires, fn(name) { !list.contains(names, name) })
  }
  case list.partition(installed, fn(extension) { unmet(extension) == [] }) {
    #(kept, []) -> #(kept, [])
    #(kept, missing) -> {
      let #(kept, cascaded) = satisfied(kept)
      let rejected =
        list.map(missing, fn(extension) {
          quarantined(
            extension,
            "it requires "
              <> string.join(unmet(extension), ", ")
              <> ", which is not installed",
          )
        })
      #(kept, list.append(rejected, cascaded))
    }
  }
}

/// Extensions the default selection can run, and the ones it cannot: a
/// default-enabled extension whose requirement is not enabled with it, or
/// one that conflicts with another already enabled by default.
fn agreeable(
  installed: List(Extension),
  default_enabled: List(String),
) -> #(List(Extension), List(Quarantined)) {
  let enabled = fn(name) { list.contains(default_enabled, name) }
  sift(installed, fn(kept, extension) {
    use <- bool.guard(!enabled(extension.name), Ok(Nil))
    use _ <- result.try(
      case list.find(extension.requires, fn(name) { !enabled(name) }) {
        Ok(missing) ->
          Error("the default selection does not enable " <> missing)
        Error(_) -> Ok(Nil)
      },
    )
    let selection =
      list.filter([extension, ..kept], fn(other: Extension) {
        enabled(other.name)
      })
    case conflict(selection) {
      Some(reason) -> Error("the default selection cannot have " <> reason)
      None -> Ok(Nil)
    }
  })
}

/// Why these extensions cannot all be enabled at once, if they cannot.
fn conflict(selected: List(Extension)) -> Option(String) {
  let strategies =
    plugin_values(selected, fn(_, plugin) {
      case plugin {
        CompactionPlugin(strategy) -> Ok(strategy)
        _ -> Error(Nil)
      }
    })
  case
    duplicate_capabilities(list.flat_map(selected, declared)),
    list.length(strategies) > 1
  {
    True, _ -> Some("duplicate capabilities")
    _, True -> Some("multiple compaction strategies")
    _, _ -> None
  }
}

/// Installed extensions' data upgrades, in registry/plugin order, not session
/// selection order. Each migration owns its markers and transaction boundaries.
pub fn migrate(
  installed: List(Extension),
  ledger: store.Store,
  backup: String,
) -> Result(List(#(String, Int)), String) {
  plugin_values(installed, fn(_, plugin) {
    case plugin {
      MigrationPlugin(DataMigration(name, run)) -> Ok(#(name, run))
      _ -> Error(Nil)
    }
  })
  |> list.try_map(fn(migration) {
    migration.1(ledger, backup)
    |> result.map(fn(count) { #(migration.0, count) })
  })
}

pub fn enabled(
  ledger: store.Store,
  installed: List(Extension),
  default_enabled: List(String),
  session: String,
) -> Result(List(Extension), String) {
  use overrides <- result.try(overrides(ledger, session))
  let selected =
    select(installed, resolved_defaults(installed, default_enabled), overrides)
  use _ <- result.try(validate_selection(selected))
  Ok(selected)
}

fn overrides(
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
fn select(
  installed: List(Extension),
  defaults: List(String),
  overrides: List(#(String, Bool)),
) -> List(Extension) {
  let selected =
    list.filter(installed, fn(extension) {
      list.key_find(overrides, extension.name)
      |> result.unwrap(list.contains(defaults, extension.name))
    })
  let chosen = fn(extension: Extension) {
    list.key_find(overrides, extension.name) == Ok(True)
  }
  exclusive(selected, is_compaction, chosen)
}

/// At most one compaction strategy runs: when several are enabled and one of
/// them is explicitly chosen, the others are dropped.
fn exclusive(
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
pub fn global_defaults(built_in: List(String)) -> List(String) {
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
fn resolved_defaults(
  installed: List(Extension),
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
pub fn window(info: ModelInfo) -> Option(Int) {
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
  installed: List(Extension),
  default_enabled: List(String),
  session: String,
  change: Change,
) -> Result(List(Extension), String) {
  let name = change_name(change)
  use _ <- result.try(
    named(installed, name)
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
        list.filter_map(installed, fn(extension) {
          case is_compaction(extension) && extension.name != name {
            True -> Ok(#(extension.name, False))
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

fn is_compaction(extension: Extension) -> Bool {
  list.any(extension.plugins, fn(plugin) {
    case plugin {
      CompactionPlugin(_) -> True
      _ -> False
    }
  })
}

/// The installed extension named `name`, if there is one.
fn named(installed: List(Extension), name: String) -> Result(Extension, Nil) {
  list.find(installed, fn(extension) { extension.name == name })
}

/// Whether `name` names a compaction strategy extension. First match is the
/// only match: `validate_registry` rejects duplicate names.
fn compaction_named(installed: List(Extension), name: String) -> Bool {
  case named(installed, name) {
    Ok(extension) -> is_compaction(extension)
    Error(_) -> False
  }
}

/// Every plugin payload `pick` accepts across these extensions, in registry
/// order, with the owning extension's name.
fn plugin_values(
  installed: List(Extension),
  pick: fn(String, Plugin) -> Result(a, Nil),
) -> List(a) {
  installed
  |> list.flat_map(fn(extension) {
    extension.plugins
    |> list.filter_map(fn(plugin) { pick(extension.name, plugin) })
  })
}

/// Save only changed selections. A single transaction prevents a restart from
/// seeing both compaction strategies enabled during a replacement.
pub fn set_selection(
  ledger: store.Store,
  session: String,
  previous: List(Extension),
  selected: List(Extension),
) -> Result(Nil, String) {
  set_selection_with(ledger, session, previous, selected, None)
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
  previous: List(Extension),
  selected: List(Extension),
  installed: List(Extension),
) -> Result(Nil, String) {
  let name = change_name(change)
  let replacing = case change {
    SetSession(_, True) | SetGlobal(_, True) ->
      compaction_named(installed, name)
    _ -> False
  }
  case change, replacing {
    SetSession(..), True ->
      set_selection_with(
        ledger,
        session,
        previous,
        selected,
        Some(#(name, True)),
      )
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
  previous: List(Extension),
  selected: List(Extension),
  explicit: Option(#(String, Bool)),
) -> Result(Nil, String) {
  let changes =
    list.append(
      entered(selected, previous, True),
      entered(previous, selected, False),
    )
  write_changes(ledger, session, case explicit {
    Some(choice) -> [choice, ..changes]
    None -> changes
  })
}

/// The extensions `side` runs and `other` does not, as (name, value) pairs.
fn entered(
  side: List(Extension),
  other: List(Extension),
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
      })
    })
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
  case conflict(selected) {
    Some(reason) -> Error("enabled extensions have " <> reason)
    None -> Ok(Nil)
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
    /// The warning-only contributions of the extensions that broke.
    failures: List(Prepared),
  )
}

/// Compose one session's extensions: static contributions with their loaded
/// context, then every prepared managed plugin. An extension that fails,
/// crashes, or collides with another is left out with a warning; the session
/// composes without it.
pub fn compose(
  selected: List(Extension),
  ledger: store.Store,
  session: String,
  workspace: String,
) -> Composition {
  let #(loadable, unloadable) =
    split(list.flat_map(selected, loaded(_, workspace)))
  let #(static, static_rejected) = distinct([], loadable)
  let #(preparable, unpreparable) =
    split(prepare(selected, ledger, session, workspace))
  let #(managed, managed_rejected) = distinct(static, preparable)
  let failures =
    list.flatten([
      unloadable,
      static_rejected,
      unpreparable,
      managed_rejected,
    ])
  Composition(
    selected,
    list.flatten([static, managed, failures]),
    managed,
    failures,
  )
}

/// The working contributions and the broken ones, each in order.
fn split(
  values: List(Result(Prepared, Prepared)),
) -> #(List(Prepared), List(Prepared)) {
  list.fold_right(values, #([], []), fn(state, value) {
    case value {
      Ok(working) -> #([working, ..state.0], state.1)
      Error(broken) -> #(state.0, [broken, ..state.1])
    }
  })
}

/// One extension's static contributions, with its context loaded. An
/// extension whose context will not load contributes only its warning: the
/// rest of the session composes without it.
fn loaded(
  extension: Extension,
  workspace: String,
) -> List(Result(Prepared, Prepared)) {
  let values =
    list.try_map(extension.plugins, fn(plugin) {
      case plugin {
        ContextPlugin(load) ->
          protect.guarded(fn() { load(workspace) })
          |> result.map(fn(context) { [Managed(..empty(), context: context)] })
        _ -> Ok(option.values([declare(plugin)]))
      }
    })
  case values {
    Ok(values) ->
      values
      |> list.flatten
      |> list.map(fn(value) { Ok(Prepared(extension.name, value)) })
    Error(error) -> [
      Error(broken(extension.name, "its context failed: " <> error)),
    ]
  }
}

/// Accept `candidates` in order, dropping any that claims a tool, command,
/// python module, or route `taken` or an earlier candidate already has.
/// Answers the kept ones and the dropped ones' warnings; a dropped
/// contribution is closed here, since the session never sees it.
fn distinct(
  taken: List(Prepared),
  candidates: List(Prepared),
) -> #(List(Prepared), List(Prepared)) {
  let #(kept, rejected) =
    list.fold(candidates, #([], []), fn(state, candidate) {
      let #(kept, rejected) = state
      let claimed = list.flatten([[candidate], kept, taken])
      case duplicate_capabilities(list.map(claimed, value)) {
        False -> #([candidate, ..kept], rejected)
        True -> {
          close_prepared([candidate])
          #(kept, [
            broken(
              candidate.extension,
              "it duplicates another extension's tools, commands, python modules, or routes",
            ),
            ..rejected
          ])
        }
      }
    })
  #(list.reverse(kept), list.reverse(rejected))
}

/// A broken extension's only contribution: no capabilities, one warning,
/// which the session shows as a note.
fn broken(name: String, reason: String) -> Prepared {
  Prepared(
    name,
    Managed(..empty(), warnings: [
      "extension " <> name <> " is inactive in this session: " <> reason,
    ]),
  )
}

fn value(prepared: Prepared) -> Managed {
  prepared.value
}

/// Release every managed resource, newest first.
pub fn close(composition: Composition) -> Nil {
  close_prepared(composition.managed)
}

/// Every contribution's observer, in registry order, each guarded: these run
/// inside the session actor, where a crash would take the session with it.
pub fn observers(
  composition: Composition,
) -> List(fn(Session, SessionEvent) -> Nil) {
  list.map(composition.contributions, fn(item) {
    fn(session, event) {
      case protect.attempt(fn() { item.value.observe(session, event) }) {
        Ok(_) -> Nil
        Error(crash) -> report(item.extension, "observer", crash)
      }
    }
  })
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

/// Each extension that failed to load or prepare, with the warning saying
/// why. Enabling one of these is an error, not a silent no-op.
pub fn inactive(composition: Composition) -> List(#(String, String)) {
  list.map(composition.failures, fn(item) {
    #(item.extension, string.join(item.value.warnings, "; "))
  })
}

pub fn warnings(composition: Composition) -> List(String) {
  list.flat_map(composition.contributions, fn(item) { item.value.warnings })
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
  quarantined: List(Quarantined),
  default_enabled: List(String),
  session: String,
  composition: Option(Composition),
) -> Result(List(Summary), String) {
  use chosen <- result.try(overrides(ledger, session))
  let defaults = resolved_defaults(installed, default_enabled)
  let selected = select(installed, defaults, chosen)
  use _ <- result.try(validate_selection(selected))
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
            FoldPlugin(_) -> "folds"
            ModelsPlugin(_) -> "models"
            ModelProviderPlugin(_) -> "model_provider"
            LoginPlugin(_) -> "login"
            ServicePlugin(_) -> "service"
            MigrationPlugin(_) -> "migration"
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
fn quarantined_summary(failure: Quarantined) -> Summary {
  Summary(
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

/// A managed contribution with nothing in it, for record updates.
pub fn empty() -> Managed {
  Managed("", "", [], [], [], [], [], fn(_, _) { Nil }, fn() { Nil })
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

/// Prepare every session-owned plugin in registry order. A plugin that fails
/// or crashes contributes its warning and nothing else; it must close any
/// resources it started itself.
fn prepare(
  installed: List(Extension),
  ledger: store.Store,
  session: String,
  workspace: String,
) -> List(Result(Prepared, Prepared)) {
  plugin_values(installed, fn(name, plugin) {
    case plugin {
      ManagedPlugin(run) -> Ok(#(name, run))
      _ -> Error(Nil)
    }
  })
  |> list.map(fn(item) {
    let #(name, run) = item
    case protect.guarded(fn() { run(ledger, session, workspace) }) {
      Ok(value) -> Ok(Prepared(name, value))
      Error(error) -> Error(broken(name, "it failed to prepare: " <> error))
    }
  })
}

/// Release each contribution, newest first. A close that crashes is reported
/// and the rest still run, so one bad teardown leaks nothing else.
fn close_prepared(prepared: List(Prepared)) -> Nil {
  prepared
  |> list.reverse
  |> list.each(fn(item) {
    case protect.attempt(item.value.close) {
      Ok(_) -> Nil
      Error(crash) -> report(item.extension, "close", crash)
    }
  })
}

/// What an extension's crash leaves in the daemon's log.
fn report(name: String, stage: String, crash: String) -> Nil {
  io.println_error(
    "extension " <> name <> " " <> stage <> " crashed, " <> crash,
  )
}

pub fn compaction(installed: List(Extension)) -> Option(compaction.Strategy) {
  plugin_values(installed, fn(_, plugin) {
    case plugin {
      CompactionPlugin(value) -> Ok(value)
      _ -> Error(Nil)
    }
  })
  |> list.first
  |> option.from_result
}

/// Every enabled fold provider, in registry order.
pub fn folds(installed: List(Extension)) -> List(compaction.Folds) {
  plugin_values(installed, fn(_, plugin) {
    case plugin {
      FoldPlugin(value) -> Ok(value)
      _ -> Error(Nil)
    }
  })
}

/// The enabled models catalogs, in registry order.
fn catalogs(installed: List(Extension)) -> List(ModelCatalog) {
  plugin_values(installed, fn(_, plugin) {
    case plugin {
      ModelsPlugin(catalog) -> Ok(catalog)
      _ -> Error(Nil)
    }
  })
}

/// How long every catalog together may take to reload.
const reload_timeout_ms = 60_000

/// Reload every enabled catalog that caches its own list, all at once. The
/// outcomes come back in registry order, each named by the extension that
/// owns the catalog; one still fetching at the deadline is reported as such.
pub fn reload_catalogs(
  installed: List(Extension),
) -> List(#(String, Result(Nil, String))) {
  let reloads =
    plugin_values(installed, fn(name, plugin) {
      case plugin {
        ModelsPlugin(ModelCatalog(reload: Some(reload), ..)) ->
          Ok(#(name, reload))
        _ -> Error(Nil)
      }
    })
  let answers = process.new_subject()
  list.each(reloads, fn(item) {
    let #(name, reload) = item
    process.spawn_unlinked(fn() {
      process.send(answers, #(name, result.flatten(protect.attempt(reload))))
    })
  })
  let expired = process.new_subject()
  let timer = process.send_after(expired, reload_timeout_ms, Nil)
  let received =
    process.new_selector()
    |> process.select_map(answers, Some)
    |> process.select_map(expired, fn(_) { None })
    |> gather(list.length(reloads), dict.new())
  process.cancel_timer(timer)
  list.map(reloads, fn(item) {
    let late =
      Error(
        "still fetching after "
        <> int.to_string(reload_timeout_ms / 1000)
        <> "s",
      )
    #(item.0, dict.get(received, item.0) |> result.unwrap(late))
  })
}

fn gather(
  selector: process.Selector(Option(#(String, a))),
  left: Int,
  received: Dict(String, a),
) -> Dict(String, a) {
  case left {
    0 -> received
    _ ->
      case process.selector_receive_forever(selector) {
        Some(#(name, outcome)) ->
          gather(selector, left - 1, dict.insert(received, name, outcome))
        None -> received
      }
  }
}

/// The first enabled catalog that knows this model answers.
pub fn model_info(
  installed: List(Extension),
  model: String,
  endpoint: Option(String),
) -> Option(ModelInfo) {
  catalogs(installed)
  |> list.fold_until(None, fn(_, catalog) {
    case catalog.lookup(model, endpoint) {
      Some(info) -> list.Stop(Some(info))
      None -> list.Continue(None)
    }
  })
}

/// The first enabled catalog that lists this provider or endpoint answers.
pub fn model_names(
  installed: List(Extension),
  provider: String,
  endpoint: Option(String),
) -> List(String) {
  catalogs(installed)
  |> list.fold_until([], fn(_, catalog) {
    case catalog.list(provider, endpoint) {
      [] -> list.Continue([])
      names -> list.Stop(names)
    }
  })
}

/// The first plugin payload `pick` accepts in the extension named `name`.
fn plugin_payload(
  installed: List(Extension),
  name: String,
  pick: fn(Plugin) -> Result(a, Nil),
) -> Result(a, Nil) {
  named(installed, name)
  |> result.try(fn(extension) { list.find_map(extension.plugins, pick) })
}

/// The first provider plugin claiming the saved profile owns its upstream.
/// Resolve an extension's declared models.dev namespace through enabled catalogs.
pub fn provider_model_names(
  installed: List(Extension),
  provider: String,
  endpoint: Option(String),
) -> List(String) {
  plugin_payload(installed, provider, fn(plugin) {
    case plugin {
      ModelProviderPlugin(value) -> Ok(value.catalog_provider)
      _ -> Error(Nil)
    }
  })
  |> result.map(fn(catalog_provider) {
    model_names(installed, catalog_provider, endpoint)
  })
  |> result.unwrap([])
}

/// Normalizes an endpoint url: empty or whitespace becomes `None`.
pub fn clean_endpoint(endpoint: String) -> Option(String) {
  case string.trim(endpoint) {
    "" -> None
    url -> Some(url)
  }
}

/// The service an enabled extension mounts, if any.
pub fn service(
  selected: List(Extension),
  name: String,
) -> Result(Service, Nil) {
  plugin_payload(selected, name, fn(plugin) {
    case plugin {
      ServicePlugin(service) -> Ok(service)
      _ -> Error(Nil)
    }
  })
}

pub fn logins(installed: List(Extension)) -> List(oauth.Login) {
  plugin_values(installed, fn(_, plugin) {
    case plugin {
      LoginPlugin(login) -> Ok(login)
      _ -> Error(Nil)
    }
  })
}

pub fn upstream(
  installed: List(Extension),
  context: ModelContext,
) -> Result(Upstream, String) {
  plugin_values(installed, fn(_, plugin) {
    case plugin {
      ModelProviderPlugin(provider) -> Ok(provider.resolve)
      _ -> Error(Nil)
    }
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
