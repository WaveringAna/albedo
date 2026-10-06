//// The prompt-cache warmer. A session that sits idle waiting on work that
//// will wake it (its children or background jobs still running) re-sends the request its last
//// turn actually sent, with only the output budget lowered, just before the
//// provider's cache would expire: the next real turn reads its context from
//// cache instead of rewriting it.
////
//// Each session gets its own warmer process, which hears the session through
//// `observe`, keeps the last sent call in memory only, and pings through the
//// session's background call. Disabling the extension closes the process, so
//// pending pings go with it. A daemon restart loses the call; a session that
//// still waits comes back with it rebuilt (`Restored`). Each ping
//// also measures one TTL for free: its request row's `cachedInputTokens`
//// says whether the cache was still there.

import albedo/daemon/bus
import albedo/daemon/family
import albedo/daemon/requests
import albedo/daemon/store
import albedo/harness/cache_ttl
import albedo/harness/extension
import albedo/harness/settings
import albedo/openai_api/types
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

pub fn extension() -> extension.Extension {
  extension.Extension(
    "warm",
    "Keeps an idle session's prompt cache warm while its children or background jobs run",
    [],
    [extension.ManagedPlugin(prepare)],
    extension.no_initialise,
  )
}

/// One session's warmer: the last turn call and the session to repeat it
/// through, a generation that any new activity raises (a tick scheduled
/// under an older one is dropped), and the pings this idle stretch has sent.
type Warmer {
  Warmer(
    db: store.Store,
    session: String,
    sent: Option(#(extension.Session, extension.SentCall)),
    generation: Int,
    pings: Int,
  )
}

type Message {
  Observed(extension.Session, extension.SessionEvent)
  /// A ping is due. `latest_ms` is the last moment it still beats the cache's
  /// expiry with half its margin to spare.
  Tick(generation: Int, latest_ms: Int)
}

/// How to keep a prefix warm: the cache's lifetime, how often to ping, how
/// many consecutive pings still pay for themselves, and whether the TTL clock
/// counts from the send's start or its finish.
type Plan {
  Plan(ttl_ms: Int, interval_ms: Int, cap: Int, from_start: Bool)
}

/// The warmer runs unlinked: closing it must not take the runtime down, and
/// a crash in it must not either.
fn prepare(
  db: store.Store,
  session: String,
  _workspace: String,
) -> Result(extension.Managed, String) {
  let ready = process.new_subject()
  let pid =
    process.spawn_unlinked(fn() {
      let inbox = process.new_subject()
      process.send(ready, inbox)
      serve(inbox, Warmer(db, session, None, 0, 0))
    })
  use inbox <- result.map(
    process.receive(ready, 5000)
    |> result.replace_error("the warmer did not start"),
  )
  extension.Managed(
    ..extension.empty(),
    observe: fn(handle, event) { process.send(inbox, Observed(handle, event)) },
    close: fn() { process.kill(pid) },
  )
}

fn serve(inbox: Subject(Message), warmer: Warmer) -> Nil {
  serve(inbox, step(inbox, warmer, process.receive_forever(inbox)))
}

fn step(inbox: Subject(Message), warmer: Warmer, message: Message) -> Warmer {
  case message {
    // What a turn call sent is what a ping repeats, and a new idle
    // stretch's budget begins.
    Observed(handle, extension.CallSent(call)) ->
      Warmer(..warmer, sent: Some(#(handle, call)), pings: 0)
    Observed(_, extension.Stirred) ->
      Warmer(..warmer, generation: warmer.generation + 1)
    // Nothing the next turn sends is warm yet.
    Observed(_, extension.Compacted) ->
      Warmer(..warmer, sent: None, generation: warmer.generation + 1, pings: 0)
    // A restart lost the call this warmer kept; the session rebuilt it.
    // Whether work still waits is asked when the ping would go out: children
    // the restart resumes may not run yet.
    Observed(handle, extension.Restored(call, pings)) ->
      case warmer.sent, plan_for(call) {
        None, Some(plan) if pings < plan.cap -> {
          let warmer = Warmer(..warmer, sent: Some(#(handle, call)), pings:)
          schedule(inbox, warmer, plan, call.started_ms, call.finished_ms)
          warmer
        }
        _, _ -> warmer
      }
    Observed(_, extension.TurnEnded(cancelled: True)) -> warmer
    Observed(_, extension.TurnEnded(cancelled: False)) -> {
      case due(warmer) {
        Some(#(_, call, plan)) ->
          schedule(inbox, warmer, plan, call.started_ms, call.finished_ms)
        None -> Nil
      }
      warmer
    }
    // A tick that fires late (a sleeping machine, a blocked scheduler) finds
    // the cache probably gone, so a ping would pay for a rewrite.
    Tick(generation, latest_ms) if generation == warmer.generation ->
      case requests.now() > latest_ms {
        True -> warmer
        False -> ping(inbox, warmer)
      }
    Tick(_, _) -> warmer
  }
}

/// The call to repeat and its plan, when another ping is due: work that will
/// wake the session still runs, the cache table gives a clock to beat, and
/// pings remain in budget. Settings are re-read each time, so an edit to
/// extensions.json takes effect without a restart.
fn due(
  warmer: Warmer,
) -> Option(#(extension.Session, extension.SentCall, Plan)) {
  case warmer.sent {
    None -> None
    // The plan is local arithmetic; asking whether work is still running
    // costs the session a kernel observation, so it is asked last.
    Some(#(handle, call)) ->
      case plan_for(call) {
        Some(plan) if warmer.pings < plan.cap ->
          case wanted(warmer.db, warmer.session, handle) {
            True -> Some(#(handle, call, plan))
            False -> None
          }
        _ -> None
      }
  }
}

/// A ping: the call as sent, with the smallest output budget the protocol
/// accepts. The next one is scheduled only while the stretch still holds:
/// a failed or refused ping ends it, and so does a cold one that should have
/// been warm, since the TTL model was wrong — its request row keeps the
/// evidence.
fn ping(inbox: Subject(Message), warmer: Warmer) -> Warmer {
  case due(warmer) {
    None -> warmer
    Some(#(handle, call, plan)) -> {
      let started = requests.now()
      let request =
        types.Request(
          ..call.request,
          max_output_tokens: Some(ping_budget(call.protocol)),
        )
      let outcome = handle.call(request, call.prefix)
      let warmer = Warmer(..warmer, pings: warmer.pings + 1)
      case outcome {
        Ok(usage) ->
          case cache_lost(call, usage), warmer.pings < plan.cap {
            False, True ->
              schedule(inbox, warmer, plan, started, requests.now())
            _, _ -> Nil
          }
        Error(_) -> Nil
      }
      warmer
    }
  }
}

/// The next tick, the plan's interval after the send it follows, counted
/// from the send's start when the entry's clock does.
fn schedule(
  inbox: Subject(Message),
  warmer: Warmer,
  plan: Plan,
  started_ms: Int,
  finished_ms: Int,
) -> Nil {
  let anchor = case plan.from_start {
    True -> started_ms
    False -> finished_ms
  }
  let at = anchor + plan.interval_ms
  let latest = at + { plan.ttl_ms - plan.interval_ms } / 2
  let delay = int.max(0, at - requests.now())
  let _ = process.send_after(inbox, delay, Tick(warmer.generation, latest))
  Nil
}

/// The smallest output budget a ping may ask for: 1, or 16 on the Responses
/// protocol, whose minimum is higher.
fn ping_budget(protocol: types.Protocol) -> Int {
  case protocol {
    types.Responses -> 16
    types.ChatCompletions -> 1
  }
}

/// Whether work that will wake this idle session is still running: a child,
/// or a background job not started as a service. One small test, so
/// persistent agents can add their own reason later.
fn wanted(db: store.Store, session: String, handle: extension.Session) -> Bool {
  children_running(db, session) || handle.awaiting_jobs()
}

fn children_running(db: store.Store, session: String) -> Bool {
  case family.children(db, session) {
    Ok(children) ->
      list.any(children, fn(child) {
        !child.closed && bus.is_running(child.session)
      })
    Error(_) -> False
  }
}

/// The smallest cached prefix worth a round trip: `minCachedTokens` in
/// `extensions.json` under `"warm"`, 1024 when unset or malformed.
fn min_cached_tokens() -> Int {
  let decoder = {
    use tokens <- decode.optional_field("minCachedTokens", 1024, decode.int)
    decode.success(tokens)
  }
  settings.load("warm", decoder, 1024)
  |> result.unwrap(1024)
}

/// The plan for one call, from the cache-table entry of the provider its
/// profile resolves to.
fn plan_for(call: extension.SentCall) -> Option(Plan) {
  plan(
    call,
    cache_ttl.for_call(call.profile, call.endpoint, call.request.model),
    min_cached_tokens(),
  )
}

/// The plan for one sent request, or `None` when no clock can be beat: the
/// shortest TTL its cache marks ask for, or with none (the OpenAI protocols,
/// which cache on their own) the cache table's first tier, and only while
/// the entry's policy is one a ping can extend. A prefix smaller than
/// `min_cached` tokens is not worth a round trip.
fn plan(
  sent: extension.SentCall,
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
            pings ->
              Some(Plan(
                ttl_seconds * 1000,
                interval_ms(ttl_seconds),
                pings,
                from_start,
              ))
          }
      }
  }
}

/// The clock to beat, with the prices of reading it and letting it go cold:
/// `#(ttl seconds, write multiplier, read multiplier, counts from send start)`.
fn resolution(
  sent: extension.SentCall,
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
  let from_start = cache_ttl.from_start(entry)
  case marks_ttl(sent) {
    // The request asked for explicit cache entries: the shortest of them is
    // the clock, and its matching tier prices the write.
    Some(ttl_seconds) -> {
      let write = tier_write(entry, ttl_seconds)
      Some(#(ttl_seconds, write, read, from_start))
    }
    // No marks: the provider caches on its own, so only the table knows, and
    // only while its policy has a clock a ping can push back.
    None ->
      entry
      |> option.then(cache_ttl.clock_tier)
      |> option.map(fn(tier) {
        #(
          tier.seconds,
          option.unwrap(tier.write, default_write),
          read,
          from_start,
        )
      })
  }
}

const default_read = 0.1

const default_write = 1.0

/// The shortest TTL the request's cache marks ask for, when it asked for
/// any: the clock a ping has to beat.
fn marks_ttl(sent: extension.SentCall) -> Option(Int) {
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

/// Ski rental: a warm cache bills the next turn about `read × cached` input,
/// a cold one about `write × cached`, and each ping costs another
/// `read × cached`. So `n` pings pay for themselves while
/// `(n + 1) × read ≤ write`: at most `floor(write / read) − 1` of them. A
/// write priced under twice the read means warming never does.
fn cap(write: Float, read: Float) -> Int {
  int.max(0, float.truncate(float.floor(write /. read)) - 1)
}

/// Tokens the last turn found in the cache: what it read plus what it wrote.
/// An unreported count is zero, which keeps a first write-only turn warmable.
fn cached_prefix(usage: Option(types.Usage)) -> Int {
  case usage {
    Some(types.Usage(
      cached_input_tokens: cached,
      cache_creation_tokens: creation,
      ..,
    )) -> option.unwrap(cached, 0) + option.unwrap(creation, 0)
    None -> 0
  }
}

/// Whether a ping found the cache gone although the turn it repeats read or
/// wrote one.
fn cache_lost(sent: extension.SentCall, ping: Option(types.Usage)) -> Bool {
  let hit = case ping {
    Some(types.Usage(cached_input_tokens: Some(count), ..)) -> count
    _ -> 0
  }
  case hit > 0 {
    True -> False
    False -> cached_prefix(sent.usage) > 0
  }
}
