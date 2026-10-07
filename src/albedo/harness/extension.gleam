//// Extensions are ordered bundles of model context, tools, REPL modules, RPC routes, and request policies.

import albedo/daemon/conversation
import albedo/daemon/requests
import albedo/daemon/store
import albedo/harness/client_api
import albedo/harness/command
import albedo/harness/compaction
import albedo/harness/extensions/python/kernel as python
import albedo/harness/oauth
import albedo/harness/page
import albedo/harness/protect
import albedo/harness/web_search
import albedo/openai_api/types
import gleam/bool
import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/int
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
  /// An idle session came back after a daemon restart, still waiting on
  /// work that will wake it, and rebuilt its last turn call: the request it
  /// sent, checked against that call's prefix identity, with the call's
  /// usage. Its timing is the latest send of that prefix, the turn call or
  /// one of the `pings` background calls that repeated it since.
  Restored(call: SentCall, pings: Int)
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
    /// Asks the session to prepare its extensions again, noting `reason` in
    /// the transcript. Answers at once; the session declines while a turn is
    /// running, so call it again when the next one ends.
    refresh: fn(String) -> Nil,
    /// Whether work that will wake the session is under way: a background
    /// job not started as a service, or an open child (or one beneath it)
    /// in a turn or itself waiting on such a job. A job a kernel cannot
    /// list does not count.
    awaited: fn() -> Bool,
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

/// What an extension deletes when a session is deleted: its rows for the
/// session, inside the delete's transaction.
pub type Cleaner =
  fn(sqlight.Connection, String) -> Result(Nil, String)

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
  /// A layer over whichever compaction strategy is active.
  NotesPlugin(notes: compaction.Notes)
  /// Stored folds any compaction strategy can read through its context.
  FoldPlugin(folds: compaction.Folds)
  /// A catalog answers only for models and providers it actually lists.
  ModelsPlugin(catalog: ModelCatalog)
  /// A provider turns one tagged saved profile into its upstream.
  ModelProviderPlugin(provider: ModelProvider)
  /// A browser sign-in the daemon runs on behalf of clients.
  LoginPlugin(login: oauth.Login)
  /// HTTP routes the daemon serves under `/extensions/<extension>/` while the extension
  /// is enabled globally.
  ServicePlugin(service: Service)
  /// A bounded read-only sidebar, independent of command invocation.
  GlancePlugin(
    read: fn(store.Store, String, String) -> Result(page.Glance, String),
    resource_url: fn(String, String) -> String,
  )
  /// Human client bindings for this extension's actual command catalog.
  ClientPlugin(commands: List(client_api.Command))
  /// SQLite upgrades owned by this extension, applied by the host at startup.
  MigrationPlugin(migration: Migration)
  /// Rows this extension keeps for a session, deleted with it. Every
  /// installed extension's runs, enabled or not: its rows still belong to the
  /// session.
  CleanPlugin(clean: Cleaner)
  /// A web search this extension answers with its own sign-in.
  SearchPlugin(provider: web_search.Provider)
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

/// Admission policy enforced by daemon ingress before reading the body.
pub type Authorization {
  DaemonToken
  LocalAccess
  /// The service verifies the buffered body before admitting any work.
  SignedBody
}

/// Handles a buffered request below the extension's mount point. The live
/// request is available for streaming responses, not for reading the body.
pub type Service {
  Service(
    admission: fn(List(String), http.Method) -> Admission,
    handle: fn(
      Daemon,
      List(String),
      request.Request(BitArray),
      request.Request(mist.Connection),
    ) -> response.Response(mist.ResponseData),
  )
}

pub type Admission {
  Admission(authorization: Authorization, body_limit: Int)
  RelayAdmission(authorization: Authorization, body_limit: Int)
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
  let #(installed, dependents) = satisfied(installed)
  Ok(#(
    installed,
    list.flatten([unnamed, unstarted, unmet, conflicting, dependents]),
  ))
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
pub fn conflict(selected: List(Extension)) -> Option(String) {
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

/// The installed extension named `name`, if there is one.
pub fn named(
  installed: List(Extension),
  name: String,
) -> Result(Extension, Nil) {
  list.find(installed, fn(extension) { extension.name == name })
}

/// Every plugin payload `pick` accepts across these extensions, in registry
/// order, with the owning extension's name.
pub fn plugin_values(
  installed: List(Extension),
  pick: fn(String, Plugin) -> Result(a, Nil),
) -> List(a) {
  installed
  |> list.flat_map(fn(extension) {
    extension.plugins
    |> list.filter_map(fn(plugin) { pick(extension.name, plugin) })
  })
}

/// A managed contribution with nothing in it, for record updates.
pub fn empty() -> Managed {
  Managed("", "", [], [], [], [], [], fn(_, _) { Nil }, fn() { Nil })
}

/// A static plugin's contribution, known without loading or preparing it.
pub fn declare(plugin: Plugin) -> Option(Managed) {
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

pub fn declared(extension: Extension) -> List(Managed) {
  extension.plugins |> list.map(declare) |> option.values
}

/// The aggregate command routes are included so capability validation sees
/// them: a plugin route cannot squat the "commands" namespace.
pub fn contribution_routes(values: List(Managed)) -> List(Route) {
  list.append(
    list.flat_map(values, fn(value) { value.routes }),
    command.routes(list.flat_map(values, fn(value) { value.commands })),
  )
}

pub fn duplicate_capabilities(values: List(Managed)) -> Bool {
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

/// Every installed extension's session cleanup, in registry order.
pub fn cleaners(installed: List(Extension)) -> List(Cleaner) {
  plugin_values(installed, fn(_, plugin) {
    case plugin {
      CleanPlugin(clean) -> Ok(clean)
      _ -> Error(Nil)
    }
  })
}

/// Every enabled notes layer, in registry order.
pub fn notes(installed: List(Extension)) -> List(compaction.Notes) {
  plugin_values(installed, fn(_, plugin) {
    case plugin {
      NotesPlugin(value) -> Ok(value)
      _ -> Error(Nil)
    }
  })
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
fn model_names(
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

/// Every web search the extensions answer, in registry order.
pub fn searches(installed: List(Extension)) -> List(web_search.Provider) {
  plugin_values(installed, fn(_, plugin) {
    case plugin {
      SearchPlugin(provider) -> Ok(provider)
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
