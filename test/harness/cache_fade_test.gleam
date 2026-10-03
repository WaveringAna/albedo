// What a Claude request's longest-lived cache marks hold is never reported
// by a call that reads them whole: the fade finds it in the request ledger,
// from whichever session last wrote that head, and the E2E fixture provider
// speaks no Claude protocol that could report the TTL-split writes.
import albedo/daemon/conversation
import albedo/daemon/requests
import albedo/harness/cache_fade.{Fade, Step}
import albedo/harness/cache_ttl
import albedo/harness/runtime
import albedo/openai_api/types
import gleam/option.{type Option, None, Some}
import gleeunit/should

@external(erlang, "albedo_runtime_test_support", "temporary_database")
fn temporary_database() -> String

@external(erlang, "albedo_runtime_test_support", "cleanup")
fn cleanup(path: String) -> Nil

/// The marks Claude requests carry: the tools and system prompt for an
/// hour, the moving tail for five minutes.
const marks = [
  types.CacheMark(types.ToolsSpan, 3600),
  types.CacheMark(types.SystemSpan, 3600),
  types.CacheMark(types.InputSpan(3), 300),
]

fn claude() -> cache_ttl.Entry {
  cache_ttl.Entry(
    id: "claude",
    layer: "default",
    match: cache_ttl.Match(None, None, None),
    policy: cache_ttl.Refresh,
    clock: cache_ttl.Request,
    tiers: Some([
      cache_ttl.Tier(300, Some(1.25)),
      cache_ttl.Tier(3600, Some(2.0)),
    ]),
    read: Some(0.1),
    survival: None,
    evidence: cache_ttl.Documented,
    source: "",
    checked: "",
    note: "",
  )
}

fn usage(read: Int, write_5m: Int, write_1h: Int) -> types.Usage {
  types.Usage(
    input_tokens: read + write_5m + write_1h + 10,
    output_tokens: 4,
    cached_input_tokens: Some(read),
    cache_creation_tokens: Some(write_5m + write_1h),
    cache_write_5m_tokens: Some(write_5m),
    cache_write_1h_tokens: Some(write_1h),
    reasoning_tokens: None,
  )
}

fn fade(
  usage: types.Usage,
  measured: fn() -> Option(Int),
) -> Option(cache_fade.Fade) {
  cache_fade.fade(Some(claude()), marks, Some(usage), measured, 1000, 9000)
}

pub fn the_tail_expires_into_the_measured_head_test() -> Nil {
  // The head is read whole with a cached tail after it, as on a fork or a
  // rewound branch: once the tail's five minutes pass, only the head the
  // ledger measured is left to read, counted from the send.
  fade(usage(25_000, 3000, 0), fn() { Some(20_000) })
  |> should.equal(
    Some(
      Fade(1000, True, [Step(300_000, Some(20_000)), Step(3_600_000, Some(0))]),
    ),
  )
  // No call has measured the head: what survives the tail is unknown.
  fade(usage(25_000, 3000, 0), fn() { None })
  |> should.equal(
    Some(Fade(1000, True, [Step(300_000, None), Step(3_600_000, Some(0))])),
  )
}

pub fn a_call_that_writes_the_head_keeps_all_it_read_test() -> Nil {
  // A changed system prompt: the tools were read, the rest of the head
  // written, so every token read survives the tail, whatever the ledger says.
  fade(usage(8000, 5000, 14_000), fn() { panic as "the call measured itself" })
  |> should.equal(
    Some(
      Fade(1000, True, [Step(300_000, Some(8000)), Step(3_600_000, Some(0))]),
    ),
  )
}

pub fn the_ledger_measures_a_head_across_sessions_test() -> Nil {
  let path = temporary_database()
  let assert Ok(host) = runtime.start(path)
  let ledger = runtime.ledger(host)
  let assert Ok(_) = conversation.initialise(ledger)
  let record = fn(session, profile, model, head, usage) {
    let assert Ok(_) =
      requests.record(
        ledger,
        requests.Call(
          session,
          requests.Turn,
          profile,
          "claude",
          None,
          model,
          0,
          1,
          requests.Completed,
          Some(usage),
          requests.Prefix(head, 1, Some(0), None, None),
          marks,
          session <> "-run",
        ),
      )
    Nil
  }
  let assert Ok(_) = conversation.create(ledger, info("parent"))
  let assert Ok(_) = conversation.create(ledger, info("fork"))
  // The parent wrote the head after reading its tools: 2k + 18k.
  record("parent", "claude", "opus", "head", usage(2000, 500, 18_000))
  // The fork reads it whole, tail and all, which measures nothing.
  record("fork", "claude", "opus", "head", usage(26_000, 700, 0))
  requests.head_tokens(ledger, "claude", "opus", "head")
  |> should.equal(Some(20_000))
  // A rewrite of the same head measures it again; the latest one counts.
  record("fork", "claude", "opus", "head", usage(0, 900, 20_500))
  requests.head_tokens(ledger, "claude", "opus", "head")
  |> should.equal(Some(20_500))
  // Another head, model, or profile has its own measure.
  requests.head_tokens(ledger, "claude", "opus", "other head")
  |> should.equal(None)
  requests.head_tokens(ledger, "claude", "sonnet", "head")
  |> should.equal(None)
  requests.head_tokens(ledger, "anthropic-api", "opus", "head")
  |> should.equal(None)
  runtime.stop(host)
  cleanup(path)
}

fn info(id: String) -> conversation.Info {
  conversation.Info(
    id,
    "new session",
    "/tmp",
    "claude",
    "opus",
    types.Responses,
    conversation.Idle,
    None,
    None,
  )
}

pub fn unmarked_providers_fade_by_their_table_entry_test() -> Nil {
  let unmeasured = fn() { None }
  let evict =
    cache_ttl.Entry(
      ..claude(),
      policy: cache_ttl.Evict,
      clock: cache_ttl.Response,
      tiers: None,
      survival: Some(cache_ttl.Survival(450, Some(3600))),
    )
  // Unknown past typical survival, gone past the bound, from the response.
  cache_fade.fade(
    Some(evict),
    [],
    Some(usage(4096, 0, 0)),
    unmeasured,
    1000,
    9000,
  )
  |> should.equal(
    Some(Fade(9000, False, [Step(450_000, None), Step(3_600_000, Some(0))])),
  )
  // A clock a hit restarts: gone when it runs out.
  cache_fade.fade(
    Some(cache_ttl.Entry(..claude(), tiers: Some([cache_ttl.Tier(1800, None)]))),
    [],
    Some(usage(4096, 0, 0)),
    unmeasured,
    1000,
    9000,
  )
  |> should.equal(Some(Fade(1000, True, [Step(1_800_000, Some(0))])))
  // Nothing known: no fading at all.
  cache_fade.fade(None, [], Some(usage(4096, 0, 0)), unmeasured, 1000, 9000)
  |> should.equal(None)
}
