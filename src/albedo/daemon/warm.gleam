//// The prompt-cache warmer. A session that sits idle waiting on work that
//// will wake it (its children still running) re-sends the request its last
//// turn actually sent, with only the output budget lowered, just before the
//// provider's cache would expire: the next real turn reads its context from
//// cache instead of rewriting it. The session keeps the last sent request in
//// memory only, so a daemon restart simply stops warming.
////
//// Every decision here is a plain value, so the stop rules and their
//// arithmetic can hold without a kernel, a provider, or an actor. Each ping
//// also measures one TTL for free: its request row's `cachedInputTokens` says
//// whether the cache was still there.

import albedo/daemon/bus
import albedo/daemon/configuration
import albedo/daemon/family
import albedo/daemon/requests
import albedo/daemon/store
import albedo/harness/cache_ttl
import albedo/harness/settings
import albedo/openai_api/types
import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/uri

/// Settings from `extensions.json` under `"warm"`.
pub type Settings {
  Settings(enabled: Bool, min_cached_tokens: Int)
}

/// What the last successful turn call sent, as a ping must repeat it.
pub type Sent {
  Sent(
    request: types.Request,
    prefix: requests.Prefix,
    /// The usage that call reported: its cached tokens are how big the warm
    /// prefix is.
    usage: Option(types.Usage),
    /// Where the request asked the provider to cache, as the call's request
    /// row recorded them: a ping repeats them.
    marks: List(types.CacheMark),
    /// The endpoint the call went to, for cache-table lookups.
    endpoint: String,
    started_ms: Int,
    finished_ms: Int,
  )
}

/// The live warming state of one session: the captured request, a generation
/// counter that any new activity raises (a tick scheduled under an older one
/// is dropped), how many consecutive pings this idle stretch has sent, and
/// the ping now in flight.
pub type Warming {
  Warming(
    sent: Option(Sent),
    generation: Int,
    pings: Int,
    in_flight: Option(#(Int, Plan)),
  )
}

pub fn fresh() -> Warming {
  Warming(None, 0, 0, None)
}

/// The last turn's call succeeded: what it sent is what a ping would repeat,
/// and a new idle stretch's ping budget begins.
pub fn captured(warming: Warming, sent: Sent) -> Warming {
  Warming(..warming, sent: Some(sent), pings: 0)
}

/// Any new activity: pending ticks scheduled under an older generation are
/// dropped when they arrive.
pub fn stirred(warming: Warming) -> Warming {
  Warming(..warming, generation: warming.generation + 1)
}

/// A compaction rewrote the prefix, so nothing the next turn sends is warm
/// yet; the capture is dropped and the generation moves on.
pub fn reset(warming: Warming) -> Warming {
  Warming(None, warming.generation + 1, 0, None)
}

/// The ping is going out now, under `plan`, started at `started_ms`.
pub fn pinging(warming: Warming, started_ms: Int, plan: Plan) -> Warming {
  Warming(
    ..warming,
    pings: warming.pings + 1,
    in_flight: Some(#(started_ms, plan)),
  )
}

/// The ping came back: no ping is in flight any more.
pub fn settled(warming: Warming) -> Warming {
  Warming(..warming, in_flight: None)
}

/// Everything a scheduling decision needs, resolved once: settings re-read
/// from disk, and the plan the last request implies from the cache table.
pub type Decision {
  Decision(settings: Settings, plan: Option(Plan))
}

/// How to keep a prefix warm: how often to ping, how many consecutive pings
/// still pay for themselves, and whether the TTL clock counts from the
/// send's start or its finish.
pub type Plan {
  Plan(interval_ms: Int, cap: Int, from_start: Bool)
}

/// The warm settings of `home`, or their defaults when unset or malformed.
pub fn read_settings(home: String) -> Settings {
  settings.load_at(home, "warm", settings_decoder(), defaults)
  |> result.unwrap(defaults)
}

const defaults = Settings(True, 1024)

fn settings_decoder() -> decode.Decoder(Settings) {
  use enabled <- decode.optional_field("enabled", True, decode.bool)
  use min_cached <- decode.optional_field("minCachedTokens", 1024, decode.int)
  decode.success(Settings(enabled, min_cached))
}

/// Whether work that will wake this idle session is still running: one small
/// test, so persistent agents can add their own reason later.
pub fn wanted(db: store.Store, session: String) -> Bool {
  case family.children(db, session) {
    Ok(children) ->
      list.any(children, fn(child) {
        !child.closed && bus.is_running(child.session)
      })
    Error(_) -> False
  }
}

/// One scheduling moment: settings re-read, the cache table looked up once
/// for the provider this session resolves to, and the plan it implies.
pub fn decision(
  home: String,
  provider: String,
  model: String,
  sent: Sent,
) -> Decision {
  let settings = read_settings(home)
  let extension = case configuration.named(home, provider) {
    Ok(configured) -> configured.extension
    Error(_) -> ""
  }
  Decision(
    settings,
    plan(
      sent,
      cache_ttl.lookup(extension, host(sent.endpoint), model),
      settings.min_cached_tokens,
    ),
  )
}

/// The plan for one sent request, or `None` when no clock can be beat: the
/// shortest TTL its cache marks ask for, or with none (the OpenAI protocols,
/// which cache on their own) the cache table's first tier, and only while
/// the entry's policy is one a ping can extend. A prefix smaller than
/// `min_cached` tokens is not worth a round trip.
pub fn plan(
  sent: Sent,
  entry: Option(cache_ttl.Entry),
  min_cached: Int,
) -> Option(Plan) {
  case resolution(sent, entry) {
    None -> None
    Some(#(ttl_seconds, write, read, from_start)) ->
      case cached_prefix(sent.usage) < min_cached {
        True -> None
        False ->
          case cap(write, read) {
            0 -> None
            pings -> Some(Plan(interval_ms(ttl_seconds), pings, from_start))
          }
      }
  }
}

/// The clock to beat, with the prices of reading it and letting it go cold:
/// `#(ttl seconds, write multiplier, read multiplier, counts from send start)`.
fn resolution(
  sent: Sent,
  entry: Option(cache_ttl.Entry),
) -> Option(#(Int, Float, Float, Bool)) {
  let read = case entry {
    Some(entry) ->
      entry.read
      |> option.map(fn(price) {
        case price >. 0.0 {
          True -> price
          False -> default_read
        }
      })
      |> option.unwrap(default_read)
    None -> default_read
  }
  let from_start = case entry {
    Some(entry) -> entry.clock == cache_ttl.Request
    None -> False
  }
  case marks_ttl(sent) {
    // The request asked for explicit cache entries: the shortest of them is
    // the clock, and its matching tier prices the write.
    Some(ttl_seconds) -> {
      let write = tier_write(entry, ttl_seconds)
      Some(#(ttl_seconds, write, read, from_start))
    }
    // No marks: the provider caches on its own, so only the table knows, and
    // only while its policy is one a ping can extend.
    None ->
      case entry {
        Some(entry) ->
          case extends(entry.policy), entry.tiers {
            True, Some([tier, ..]) ->
              Some(#(
                tier.seconds,
                option.unwrap(tier.write, default_write),
                read,
                from_start,
              ))
            _, _ -> None
          }
        None -> None
      }
  }
}

/// Whether a ping can push the entry's lifetime back: a fixed clock or one
/// every hit restarts. Best-effort eviction has no clock to beat.
fn extends(policy: cache_ttl.Policy) -> Bool {
  case policy {
    cache_ttl.Refresh | cache_ttl.Fixed -> True
    cache_ttl.Evict | cache_ttl.Unknown -> False
  }
}

const default_read = 0.1

const default_write = 1.0

/// The shortest TTL the request's cache marks ask for, when it asked for
/// any: the clock a ping has to beat.
fn marks_ttl(sent: Sent) -> Option(Int) {
  list.fold(sent.marks, None, fn(shortest, mark) {
    case shortest {
      None -> Some(mark.ttl_seconds)
      Some(seconds) -> Some(int.min(seconds, mark.ttl_seconds))
    }
  })
}

/// The write multiplier of the tier matching `ttl_seconds`, when the entry
/// prices one; the default prices a rewrite at parity.
fn tier_write(entry: Option(cache_ttl.Entry), ttl_seconds: Int) -> Float {
  case entry {
    Some(entry) ->
      case entry.tiers {
        Some(tiers) ->
          list.find(tiers, fn(tier) { tier.seconds == ttl_seconds })
          |> result.map(fn(tier) { option.unwrap(tier.write, default_write) })
          |> result.unwrap(default_write)
        None -> default_write
      }
    None -> default_write
  }
}

/// Ping at the smaller of ten percent and ten seconds under the TTL, so the
/// entry is always refreshed with time to spare.
fn interval_ms(ttl_seconds: Int) -> Int {
  let margin = { ttl_seconds - 10 } * 1000
  case ttl_seconds > 10 {
    True -> int.min(ttl_seconds * 900, margin)
    False -> ttl_seconds * 900
  }
}

/// Ski rental: each ping costs about `read × cached` input, letting the cache
/// go cold costs one rewrite of about `write × cached`, so at most
/// `floor(write / read)` consecutive pings pay for themselves. Reading costs
/// at least as much as writing means warming never does.
fn cap(write: Float, read: Float) -> Int {
  case write >=. read {
    False -> 0
    True -> float.floor(write /. read) |> float.truncate
  }
}

/// Tokens the last turn found in the cache: what it read plus what it wrote.
/// An unreported count is zero, which keeps a first write-only turn warmable.
pub fn cached_prefix(usage: Option(types.Usage)) -> Int {
  case usage {
    Some(types.Usage(
      cached_input_tokens: cached,
      cache_creation_tokens: creation,
      ..,
    )) -> option.unwrap(cached, 0) + option.unwrap(creation, 0)
    None -> 0
  }
}

/// Whether the next ping should go out: warming is enabled, work that will
/// wake the session still runs, a plan exists, and pings remain in budget.
pub fn next(decision: Decision, wanted: Bool, pings: Int) -> Option(Plan) {
  case decision.settings.enabled, wanted, decision.plan {
    False, _, _ | _, False, _ | _, _, None -> None
    True, True, Some(plan) ->
      case pings < plan.cap {
        True -> Some(plan)
        False -> None
      }
  }
}

/// When the first ping of an idle stretch is due, if one is: the interval
/// after the turn's send, counted from its start when the entry's clock
/// does. Answers the delay and the generation the tick runs under.
pub fn first_ping(
  home: String,
  provider: String,
  model: String,
  warming: Warming,
  wanted: Bool,
  now_ms: Int,
) -> Option(#(Int, Int)) {
  case warming.sent {
    None -> None
    Some(sent) ->
      case next(decision(home, provider, model, sent), wanted, warming.pings) {
        None -> None
        Some(plan) -> Some(#(delay(sent, plan, now_ms), warming.generation))
      }
  }
}

fn delay(sent: Sent, plan: Plan, now_ms: Int) -> Int {
  let anchor = case plan.from_start {
    True -> sent.started_ms
    False -> sent.finished_ms
  }
  int.max(0, anchor + plan.interval_ms - now_ms)
}

/// Whether and when the next ping is due after one came back: the budget or
/// the cache itself can be gone, a cancelled or failed ping ends the stretch,
/// and a cold ping that should have been warm ends it because the TTL model
/// was wrong — its request row keeps the evidence.
pub fn reschedule(
  warming: Warming,
  cancelled: Bool,
  outcome: Result(Option(types.Usage), String),
  finished_ms: Int,
  now_ms: Int,
) -> Option(#(Int, Int)) {
  case cancelled, outcome, warming.in_flight, warming.sent {
    True, _, _, _ -> None
    False, Error(_), _, _ -> None
    False, _, None, _ -> None
    False, Ok(usage), Some(#(started_ms, plan)), Some(sent) ->
      case cache_lost(sent, usage), warming.pings < plan.cap {
        True, _ | _, False -> None
        False, True -> {
          let anchor = case plan.from_start {
            True -> started_ms
            False -> finished_ms
          }
          Some(#(
            int.max(0, anchor + plan.interval_ms - now_ms),
            warming.generation,
          ))
        }
      }
    _, _, _, None -> None
  }
}

/// Whether a ping found the cache gone although the turn it repeats read or
/// wrote one.
pub fn cache_lost(sent: Sent, ping: Option(types.Usage)) -> Bool {
  let hit = case ping {
    Some(types.Usage(cached_input_tokens: Some(count), ..)) -> count
    _ -> 0
  }
  case hit > 0 {
    True -> False
    False -> cached_prefix(sent.usage) > 0
  }
}

/// The host of an endpoint URL, as the cache table matches it.
fn host(endpoint: String) -> String {
  case uri.parse(endpoint) {
    Ok(uri.Uri(host: Some(host), ..)) -> host
    _ -> ""
  }
}
