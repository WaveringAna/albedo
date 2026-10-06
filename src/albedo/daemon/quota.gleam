//// Provider quota readings, polled per account and recorded raw.
////
//// One poller for the whole daemon owns the schedule. Every account albedo
//// can see is polled on its own cadence: each OAuth account in a provider's
//// rotation pool, and each API-key profile whose base url names a feed. Never
//// two polls of one account at once; a limit at or above 80 percent, or one
//// resetting within fifteen minutes, moves that account onto the busy
//// cadence; a failure backs off. Credentials come from the same readers and
//// refreshers the request path uses, so polling refreshes tokens the way
//// requests do.
////
//// Only readings are stored — percentages, windows, reset times, statuses and
//// errors exactly as the feed reported them, never anything derived. Phase 2
//// derives what it needs from these rows.

import albedo/clock

import albedo/daemon/configuration
import albedo/daemon/store
import albedo/harness/settings
import albedo/harness/usage_feed.{type Limit, type Report}
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import gleam/uri
import sqlight

/// The feed the poller polls through: the real one, or a fake in tests.
pub type Fetch =
  fn(String, json.Json, Int) -> Result(Report, String)

/// One polled account: a provide-usage provider id, the account's non-secret
/// label, and the credential to poll it with.
pub type Target {
  Target(provider: String, label: String, credential: json.Json)
}

pub type Settings {
  Settings(poll_seconds: Int, busy_poll_seconds: Int, enabled: Bool)
}

const default_settings = Settings(600, 120, True)

/// `$ALBEDO_HOME/extensions.json` under `"quota"`, read like any extension's
/// settings, and re-read every round so changes apply without a restart.
fn load_settings() -> Settings {
  let decoder = {
    use poll_seconds <- decode.optional_field("pollSeconds", 600, decode.int)
    use busy_poll_seconds <- decode.optional_field(
      "busyPollSeconds",
      120,
      decode.int,
    )
    use enabled <- decode.optional_field("enabled", True, decode.bool)
    decode.success(Settings(poll_seconds, busy_poll_seconds, enabled))
  }
  settings.load("quota", decoder, default_settings)
  |> result.unwrap(default_settings)
  |> clamped
}

fn clamped(settings: Settings) -> Settings {
  let poll_seconds = int.clamp(settings.poll_seconds, 1, 86_400)
  Settings(
    poll_seconds,
    int.clamp(settings.busy_poll_seconds, 1, poll_seconds),
    settings.enabled,
  )
}

/// The accounts this daemon can poll, with credentials refreshed the way
/// requests refresh them.
fn enumerate(home: String) -> List(Target) {
  list.flatten([
    oauth_targets("anthropic", claude_accounts(home)),
    oauth_targets("openai-codex", codex_accounts(home)),
    oauth_targets("google-antigravity", antigravity_accounts(home)),
    profile_targets(home),
  ])
}

@external(erlang, "albedo_claude_auth", "accounts")
fn claude_accounts(home: String) -> List(Dynamic)

@external(erlang, "albedo_openai_auth", "accounts")
fn codex_accounts(home: String) -> List(Dynamic)

@external(erlang, "albedo_antigravity", "accounts")
fn antigravity_accounts(home: String) -> List(Dynamic)

/// A stored OAuth account: the label the provider's own identity logic gives
/// it, plus the provide-usage credential fields.
type Stored {
  Stored(
    label: String,
    access: String,
    account_id: String,
    email: String,
    project_id: String,
  )
}

fn stored_decoder() -> decode.Decoder(Stored) {
  use label <- decode.field("label", decode.string)
  use access <- decode.optional_field("access", "", decode.string)
  use account_id <- decode.optional_field("accountId", "", decode.string)
  use email <- decode.optional_field("email", "", decode.string)
  use project_id <- decode.optional_field("projectId", "", decode.string)
  decode.success(Stored(label, access, account_id, email, project_id))
}

fn oauth_targets(provider: String, stored: List(Dynamic)) -> List(Target) {
  stored
  |> list.filter_map(fn(value) {
    decode.run(value, stored_decoder()) |> result.replace_error(Nil)
  })
  |> list.filter_map(fn(account) {
    case account.access, account.label {
      "", _ | _, "" -> Error(Nil)
      _, _ -> Ok(Target(provider, account.label, oauth_credential(account)))
    }
  })
}

/// Only the access token crosses into the core: albedo refreshes it, and the
/// core never reads a refresh token.
fn oauth_credential(account: Stored) -> json.Json {
  let fields = [
    #("kind", json.string("oauth")),
    #("access", json.string(account.access)),
    ..text_fields([
      #("accountId", account.account_id),
      #("email", account.email),
    ])
  ]
  // Antigravity's quota is per Cloud Code Assist project.
  case account.project_id {
    "" -> json.object(fields)
    project_id ->
      json.object(
        list.append(fields, [
          #("extra", json.object([#("projectId", json.string(project_id))])),
        ]),
      )
  }
}

/// Config profiles: an alibaba profile polls through the signed-in `bl` CLI,
/// and a generic `openai` profile maps to a feed by its base url host. A
/// profile whose host has no feed is skipped.
fn profile_targets(home: String) -> List(Target) {
  configuration.providers(home)
  |> result.unwrap([])
  |> list.filter_map(fn(profile) {
    case profile.extension {
      "alibaba" ->
        Ok(Target(
          "alibaba",
          "alibaba",
          json.object([
            #("kind", json.string("cli")),
          ]),
        ))
      "openai" -> key_target(home, profile.name)
      _ -> Error(Nil)
    }
  })
}

fn key_target(home: String, name: String) -> Result(Target, Nil) {
  use #(base_url, api_key) <- result.try(
    configuration.settings(home, name, profile_decoder())
    |> result.replace_error(Nil),
  )
  use provider <- result.try(feed_provider(base_url))
  case string.trim(api_key) {
    "" -> Error(Nil)
    key ->
      Ok(Target(
        provider,
        name,
        json.object([
          #("kind", json.string("apiKey")),
          #("apiKey", json.string(key)),
        ]),
      ))
  }
}

fn profile_decoder() -> decode.Decoder(#(String, String)) {
  use base_url <- decode.optional_field("baseUrl", "", decode.string)
  use api_key <- decode.optional_field("apiKey", "", decode.string)
  decode.success(#(base_url, api_key))
}

fn feed_provider(base_url: String) -> Result(String, Nil) {
  use parsed <- result.try(uri.parse(base_url) |> result.replace_error(Nil))
  use host <- result.try(parsed.host |> option.to_result(Nil))
  case string.lowercase(host) {
    "hyper.charm.land" -> Ok("hyper")
    "api.deepseek.com" -> Ok("deepseek")
    _ -> Error(Nil)
  }
}

fn text_fields(fields: List(#(String, String))) -> List(#(String, json.Json)) {
  list.filter_map(fields, fn(field) {
    case field.1 {
      "" -> Error(Nil)
      value -> Ok(#(field.0, json.string(value)))
    }
  })
}

// ---- the poller ---------------------------------------------------------

pub type Message {
  Tick
  /// The account list, as a spawn saw it.
  Enumerated(List(Target))
  /// One poll finished: the account key, whether it failed, and whether it
  /// is busy.
  Polled(key: String, failed: Bool, busy: Bool)
  Down(process.Down)
}

type Account {
  Account(
    /// provider <> "/" <> label: one polled account, never two polls at once.
    key: String,
    target: Target,
    /// Wall-clock milliseconds for this account's next poll.
    next_due: Int,
    /// Consecutive failed polls, for backoff.
    failures: Int,
    /// The process polling now, so a crash frees the slot.
    polling: Option(process.Pid),
  )
}

type State {
  State(
    home: String,
    database: store.Store,
    fetch: Fetch,
    accounts: Dict(String, Account),
    self: Subject(Message),
    /// A tick is already scheduled.
    ticking: Bool,
    /// The process listing accounts now, so a crash cannot wedge it.
    enumerating: Option(process.Pid),
    last_enumerated: Int,
  )
}

/// One poller for the whole daemon. It starts with the daemon, restarts under
/// its supervisor, and polls each account it can see on its own cadence.
pub fn start(
  home: String,
  database: store.Store,
  fetch: Fetch,
) -> Result(actor.Started(Subject(Message)), actor.StartError) {
  actor.new_with_initialiser(30_000, fn(self) {
    label("albedo_quota", home)
    let _ = process.send_after(self, 0, Tick)
    Ok(
      actor.initialised(State(
        home,
        database,
        fetch,
        dict.new(),
        self,
        True,
        None,
        0,
      ))
      |> actor.returning(self)
      |> actor.selecting(
        process.new_selector()
        |> process.select(self)
        |> process.select_monitors(Down),
      ),
    )
  })
  |> actor.on_message(handle)
  |> actor.start
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Tick -> retick(State(..on_tick(state), ticking: False))
    Enumerated(targets) ->
      retick(merged(
        State(..state, enumerating: None),
        targets,
        clock.system_ms(),
      ))
    Polled(key, failed, busy) -> retick(finished(state, key, failed, busy))
    Down(process.ProcessDown(_, pid, _)) -> retick(fell(state, pid))
    // The poller monitors processes only; a port is never one of them.
    Down(process.PortDown(_, _, _)) -> actor.continue(state)
  }
}

fn on_tick(state: State) -> State {
  let config = load_settings()
  let now = clock.system_ms()
  case config.enabled {
    False -> State(..state, accounts: dict.new())
    True -> {
      let state = case
        state.enumerating,
        now - state.last_enumerated >= config.poll_seconds * 1000
      {
        None, True -> enumerate_now(state, now)
        _, _ -> state
      }
      start_due(state, now)
    }
  }
}

/// Account discovery runs off the poller: a refresh may wait on the network.
/// The attempt is what the cadence counts from, so a discovery that fails
/// fast never spins.
fn enumerate_now(state: State, now: Int) -> State {
  let self = state.self
  let home = state.home
  let pid =
    process.spawn_unlinked(fn() {
      process.send(self, Enumerated(enumerate(home)))
    })
  let _ = process.monitor(pid)
  State(..state, enumerating: Some(pid), last_enumerated: now)
}

/// New accounts poll at once; an account that is polling now finishes first,
/// so its readings stay even if the account has since gone.
fn merged(state: State, targets: List(Target), now: Int) -> State {
  let fresh =
    list.fold(targets, dict.new(), fn(accounts, target) {
      let key = key_of(target)
      let account = case dict.get(state.accounts, key) {
        Ok(existing) -> Account(..existing, target: target)
        Error(_) -> Account(key, target, now, 0, None)
      }
      dict.insert(accounts, key, account)
    })
  let accounts =
    dict.fold(state.accounts, fresh, fn(accounts, key, account) {
      case dict.has_key(accounts, key), account.polling {
        False, Some(_) -> dict.insert(accounts, key, account)
        _, _ -> accounts
      }
    })
  State(..state, accounts: accounts)
}

fn start_due(state: State, now: Int) -> State {
  let fetch = state.fetch
  let database = state.database
  let self = state.self
  dict.fold(state.accounts, state, fn(state, key, account) {
    case account.next_due <= now, account.polling {
      True, None -> {
        let target = account.target
        let pid =
          process.spawn_unlinked(fn() {
            let #(failed, busy) = run(fetch, database, target)
            process.send(self, Polled(key, failed, busy))
          })
        let _ = process.monitor(pid)
        State(
          ..state,
          accounts: dict.insert(
            state.accounts,
            key,
            Account(..account, polling: Some(pid)),
          ),
        )
      }
      _, _ -> state
    }
  })
}

/// Seconds until an account's next poll: the busy cadence while any limit is
/// at or above 80 percent or resets within fifteen minutes, the ordinary
/// cadence otherwise, and after `failures` failed polls in a row a backoff
/// that doubles six times at most and never waits past an hour.
pub fn wait_seconds(settings: Settings, failures: Int, busy: Bool) -> Int {
  case failures, busy {
    0, True -> settings.busy_poll_seconds
    0, False -> settings.poll_seconds
    _, _ ->
      settings.poll_seconds * int.bitwise_shift_left(1, int.min(failures, 6))
      |> int.min(3600)
  }
}

fn finished(state: State, key: String, failed: Bool, busy: Bool) -> State {
  case dict.get(state.accounts, key) {
    Error(_) -> state
    Ok(account) -> {
      let failures = case failed {
        True -> account.failures + 1
        False -> 0
      }
      let wait = wait_seconds(load_settings(), failures, busy)
      State(
        ..state,
        accounts: dict.insert(
          state.accounts,
          key,
          Account(
            ..account,
            failures: failures,
            polling: None,
            next_due: clock.system_ms() + wait * 1000,
          ),
        ),
      )
    }
  }
}

/// A spawned poll that crashed never answers `Polled`: free its slot and
/// back the account off, so a crashing feed cannot wedge the schedule.
fn fell(state: State, pid: process.Pid) -> State {
  case state.enumerating {
    Some(enumerating) if enumerating == pid -> State(..state, enumerating: None)
    _ ->
      case
        dict.to_list(state.accounts)
        |> list.find(fn(entry) { entry.1.polling == Some(pid) })
      {
        Error(_) -> state
        Ok(#(key, _)) -> finished(state, key, True, False)
      }
  }
}

/// One tick in flight at a time: the next is scheduled for whichever account
/// or enumeration is soonest, so the busy cadence is honoured exactly.
fn retick(state: State) -> actor.Next(State, Message) {
  case state.ticking {
    True -> actor.continue(state)
    False -> {
      let _ = process.send_after(state.self, tick_delay(state), Tick)
      actor.continue(State(..state, ticking: True))
    }
  }
}

fn tick_delay(state: State) -> Int {
  let config = load_settings()
  case config.enabled {
    False -> config.poll_seconds * 1000
    True -> {
      let now = clock.system_ms()
      let due =
        [
          list.map(dict.values(state.accounts), fn(account) { account.next_due }),
          [state.last_enumerated + config.poll_seconds * 1000],
        ]
        |> list.flatten
      let delay = case minimum(due) {
        None -> config.poll_seconds * 1000
        Some(when) -> when - now
      }
      int.clamp(delay, 250, config.poll_seconds * 1000)
    }
  }
}

fn minimum(values: List(Int)) -> Option(Int) {
  list.fold(values, None, fn(best, value) {
    case best {
      Some(current) -> Some(int.min(current, value))
      None -> Some(value)
    }
  })
}

/// One poll of one account, off the poller: whatever comes back is recorded
/// exactly as it came, then the schedule hears whether it failed and whether
/// the account is busy.
fn run(fetch: Fetch, database: store.Store, target: Target) -> #(Bool, Bool) {
  let now = clock.system_ms()
  case fetch(target.provider, target.credential, now) {
    Ok(report) -> {
      record(database, target, report.plan, report.limits, report.error, now)
      #(report.error != None, is_busy(report, now))
    }
    Error(message) -> {
      record(database, target, None, [], Some(message), now)
      #(True, False)
    }
  }
}

fn is_busy(report: Report, now: Int) -> Bool {
  list.any(report.limits, fn(limit) {
    case limit.used_percent {
      Some(used) if used >=. 80.0 -> True
      _ ->
        case limit.resets_at {
          Some(resets_at) ->
            resets_at > now && resets_at - now <= 15 * 60 * 1000
          None -> False
        }
    }
  })
}

// ---- the readings -------------------------------------------------------

/// One stored reading, exactly as the feed reported it.
pub type Sample {
  Sample(
    id: Int,
    /// The account's non-secret label.
    account: String,
    provider: String,
    /// The report plan: what 100 percent means can change with it.
    plan: Option(String),
    limit_id: String,
    label: String,
    used_percent: Option(Float),
    window_label: Option(String),
    window_seconds: Option(Int),
    resets_at: Option(Int),
    scope: Option(String),
    status: String,
    error: Option(String),
    observed_at: Int,
    source: String,
  )
}

const schema =
  "
CREATE TABLE IF NOT EXISTS quota_sample (
 id INTEGER PRIMARY KEY AUTOINCREMENT,
 account TEXT NOT NULL,
 provider TEXT NOT NULL,
 plan TEXT,
 limit_id TEXT NOT NULL DEFAULT '',
 label TEXT NOT NULL DEFAULT '',
 used_percent REAL,
 window_label TEXT,
 window_seconds INTEGER,
 resets_at INTEGER,
 scope TEXT,
 status TEXT NOT NULL DEFAULT '',
 error TEXT,
 observed_at INTEGER NOT NULL,
 source TEXT NOT NULL DEFAULT 'poll'
);
CREATE INDEX IF NOT EXISTS quota_sample_latest
 ON quota_sample(account, provider, limit_id, id);
"

/// The table, before any session or poller starts.
pub fn initialise(database: store.Store) -> Result(Nil, String) {
  store.query(database, fn(db) { store.exec(db, schema) })
}

/// Only readings: one row per limit the report carried, or one row carrying
/// the report's error when it carried none.
fn record(
  database: store.Store,
  target: Target,
  plan: Option(String),
  limits: List(Limit),
  error: Option(String),
  now: Int,
) -> Nil {
  let rows = case limits {
    [] -> [
      Row(
        target.label,
        target.provider,
        plan,
        "",
        "",
        None,
        None,
        None,
        None,
        None,
        "",
        error,
        now,
      ),
    ]
    _ ->
      list.map(limits, fn(limit) {
        Row(
          target.label,
          target.provider,
          plan,
          limit.id,
          limit.label,
          limit.used_percent,
          limit.window_label,
          limit.window_seconds,
          limit.resets_at,
          limit.scope,
          limit.status,
          error,
          now,
        )
      })
  }
  let outcome =
    store.query(database, fn(db) {
      list.try_each(rows, fn(row) { insert(db, row) })
    })
  case outcome {
    Ok(_) -> Nil
    Error(message) -> io.println_error("quota sample write failed: " <> message)
  }
}

type Row {
  Row(
    account: String,
    provider: String,
    plan: Option(String),
    limit_id: String,
    label: String,
    used_percent: Option(Float),
    window_label: Option(String),
    window_seconds: Option(Int),
    resets_at: Option(Int),
    scope: Option(String),
    status: String,
    error: Option(String),
    observed_at: Int,
  )
}

fn insert(db: sqlight.Connection, row: Row) -> Result(Nil, String) {
  store.run(
    db,
    "INSERT INTO quota_sample(account, provider, plan, limit_id, label, used_percent, window_label, window_seconds, resets_at, scope, status, error, observed_at, source)
     VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'poll')",
    [
      sqlight.text(row.account),
      sqlight.text(row.provider),
      sqlight.nullable(sqlight.text, row.plan),
      sqlight.text(row.limit_id),
      sqlight.text(row.label),
      sqlight.nullable(sqlight.float, row.used_percent),
      sqlight.nullable(sqlight.text, row.window_label),
      sqlight.nullable(sqlight.int, row.window_seconds),
      sqlight.nullable(sqlight.int, row.resets_at),
      sqlight.nullable(sqlight.text, row.scope),
      sqlight.text(row.status),
      sqlight.nullable(sqlight.text, row.error),
      sqlight.int(row.observed_at),
    ],
  )
}

const sample_columns =
  "id, account, provider, plan, limit_id, label, used_percent, window_label, window_seconds, resets_at, scope, status, error, observed_at, source"

fn sample_decoder() -> decode.Decoder(Sample) {
  use id <- decode.field(0, decode.int)
  use account <- decode.field(1, decode.string)
  use provider <- decode.field(2, decode.string)
  use plan <- decode.field(3, decode.optional(decode.string))
  use limit_id <- decode.field(4, decode.string)
  use label <- decode.field(5, decode.string)
  use used_percent <- decode.field(6, decode.optional(decode.float))
  use window_label <- decode.field(7, decode.optional(decode.string))
  use window_seconds <- decode.field(8, decode.optional(decode.int))
  use resets_at <- decode.field(9, decode.optional(decode.int))
  use scope <- decode.field(10, decode.optional(decode.string))
  use status <- decode.field(11, decode.string)
  use error <- decode.field(12, decode.optional(decode.string))
  use observed_at <- decode.field(13, decode.int)
  use source <- decode.field(14, decode.string)
  decode.success(Sample(
    id,
    account,
    provider,
    plan,
    limit_id,
    label,
    used_percent,
    window_label,
    window_seconds,
    resets_at,
    scope,
    status,
    error,
    observed_at,
    source,
  ))
}

/// The latest reading per account and limit, read-only.
pub fn latest(database: store.Store) -> Result(List(Sample), String) {
  store.read(database, "SELECT " <> sample_columns <> " FROM quota_sample s
     WHERE s.id = (SELECT MAX(t.id) FROM quota_sample t
                   WHERE t.account = s.account AND t.provider = s.provider
                     AND t.limit_id = s.limit_id)
     ORDER BY s.account, s.provider, s.limit_id", [], sample_decoder())
}

/// Readings newest-first with id keyset paging: `before` 0 starts at the
/// newest, any other value continues after that row id.
pub fn history(
  database: store.Store,
  before: Int,
  limit: Int,
) -> Result(List(Sample), String) {
  case before <= 0 {
    True ->
      store.read(
        database,
        "SELECT "
          <> sample_columns
          <> " FROM quota_sample ORDER BY id DESC LIMIT ?",
        [sqlight.int(limit)],
        sample_decoder(),
      )
    False ->
      store.read(
        database,
        "SELECT "
          <> sample_columns
          <> " FROM quota_sample WHERE id < ? ORDER BY id DESC LIMIT ?",
        [sqlight.int(before), sqlight.int(limit)],
        sample_decoder(),
      )
  }
}

fn key_of(target: Target) -> String {
  target.provider <> "/" <> target.label
}

@external(erlang, "albedo_inspect", "label")
fn label(kind: String, id: String) -> Nil
