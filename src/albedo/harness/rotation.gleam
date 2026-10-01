//// Rate-limit rotation for providers that hold several accounts or keys. A
//// request that hits a limit is recorded against its account and handed to
//// the next one with room; when none has room, a brief limit is waited out
//// and a lasting one fails fast. A 429 arrives before any output, so a retry
//// repeats nothing the model or the user saw.
////
//// A provider supplies a `Pool`: how to find the session's account, how to
//// record a limit against one, and how to stream on one. `albedo_accounts`
//// holds the ordering and limit bookkeeping those usually share.

import albedo/harness/extension
import albedo/openai_api/types
import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// What a 429 said about the account that received it.
pub type Limit {
  /// Seconds to minutes, e.g. a burst or tokens-per-minute cap: worth waiting
  /// for when every account has hit it.
  Brief
  /// Hours, e.g. a spent subscription quota: a sibling may have room, but
  /// waiting is pointless.
  Lasting
}

/// A limit once recorded: its kind, and whether another account still has room.
pub type Marked {
  Marked(limit: Limit, room: Bool)
}

/// A Marked from a provider's own flags: whether the limit lasts, and whether
/// a sibling still has room.
fn marked(lasting: Bool, room: Bool) -> Marked {
  case lasting {
    True -> Marked(Lasting, room)
    False -> Marked(Brief, room)
  }
}

/// A rate or usage limit parsed from an account provider's 429 response.
pub type Limited {
  Limited(account: String, until: String, next: String, lasting: Bool)
}

/// Parses a provider's limit JSON describing when an account resets and its sibling.
pub fn decode_limited(encoded: String) -> Result(Limited, Nil) {
  let decoder = {
    use account <- decode.optional_field("account", "", decode.string)
    use until <- decode.field("until", decode.string)
    use next <- decode.field("next", decode.string)
    use lasting <- decode.optional_field("lasting", True, decode.bool)
    decode.success(Limited(account, until, next, lasting))
  }
  json.parse(encoded, decoder) |> result.replace_error(Nil)
}

/// Marks a successful limit decode against its lasting duration and sibling availability.
pub fn mark_limit(result: Result(Limited, a)) -> Option(Marked) {
  result
  |> result.map(fn(limit) { marked(limit.lasting, limit.next != "") })
  |> option.from_result
}

/// Formats a user-facing rate-limit or quota-exhausted explanation.
pub fn limit_message(head: String, next: String, none_left: String) -> String {
  case next {
    "" -> head <> "; " <> none_left
    _ -> next_turn_message(head, next)
  }
}

/// Explains that a request limit was hit and names the sibling account used next.
pub fn next_turn_message(head: String, next: String) -> String {
  head
  <> "; the next turn will use "
  <> next
  <> ". Send your message again to continue"
}

/// Extracts an error message from an API error response body, or falls back to the body.
pub fn error_message(body: String) -> String {
  json.parse(body, decode.at(["error", "message"], decode.string))
  |> result.unwrap(body)
}

/// Guards upstream resolution against mismatched provider names and protocol requirements.
pub fn require_provider(
  context: extension.ModelContext,
  provider: String,
  label: String,
  protocol: types.Protocol,
  build: fn() -> Result(extension.Upstream, String),
) -> Option(Result(extension.Upstream, String)) {
  case context.provider == provider, context.protocol == protocol {
    False, _ -> None
    True, True -> Some(build())
    True, False ->
      Some(Error(
        label
        <> " provider requires the "
        <> types.protocol_name(protocol)
        <> " protocol",
      ))
  }
}

/// Tests whether two OpenAI client configurations share the same API key.
pub fn same_client(a: types.Client, b: types.Client) -> Bool {
  a.api_key == b.api_key
}

/// An upstream for an OpenAI-compatible client rotating through pool.
/// `label` names an account without naming its credential.
pub fn client_upstream(
  pool: Pool(types.Client),
  first: types.Client,
  explain: fn(types.Client, types.Error) -> Option(String),
  label: fn(types.Client) -> String,
) -> extension.Upstream {
  upstream(first.base_url, first.protocol, pool, first, explain, label)
}

/// A non-secret account label for a key-authenticated client: the first
/// eight hex characters of the key's SHA-256, enough to tell siblings apart.
pub fn key_label(key: String) -> String {
  key
  |> bit_array.from_string
  |> crypto.hash(crypto.Sha256, _)
  |> bit_array.base16_encode
  |> string.slice(0, 8)
  |> string.lowercase
}

pub type Pool(account) {
  Pool(
    /// The account the session should use now. Limited accounts come last,
    /// so after a `mark` this names a sibling when one has room.
    current: fn() -> Result(account, String),
    /// Records the limit a 429 `body` reports against `account`. None when the
    /// body is not a limit this provider recognises; it is then treated as
    /// brief and never moves the session.
    mark: fn(account, String) -> Option(Marked),
    same: fn(account, account) -> Bool,
    stream: fn(account, types.Request, fn(types.Event) -> types.Control) ->
      Result(types.Turn, types.Error),
  )
}

/// How far one request may go looking for room: account hops left, waits
/// taken so far, and the sleep it uses (tests replace it).
pub type Budget {
  Budget(hops: Int, waits: Int, pause: fn(Int) -> Nil)
}

/// Accounts one request may move through after limits, beyond the first.
fn budget() -> Budget {
  Budget(8, 0, sleep)
}

/// Backoff when every account is briefly limited: about a minute in all.
const waits = [4000, 8000, 15_000, 30_000]

/// An upstream that rotates through `pool` starting from `first`. `explain`
/// is given the account the failing attempt went to, not necessarily `first`;
/// `label` names the account that served, without naming its credential.
pub fn upstream(
  endpoint: String,
  protocol: types.Protocol,
  pool: Pool(account),
  first: account,
  explain: fn(account, types.Error) -> Option(String),
  label: fn(account) -> String,
) -> extension.Upstream {
  let slot = new_slot()
  extension.Upstream(
    endpoint,
    protocol,
    fn(request, on_event) {
      served(slot, first)
      stream(pool, first, request, on_event, budget(), fn(account) {
        served(slot, account)
      })
    },
    fn(error) { explain(last_served(slot, first), error) },
    fn() {
      case string.trim(label(last_served(slot, first))) {
        "" -> None
        account -> Some(account)
      }
    },
    fn(_) { [] },
    types.any_images,
  )
}

/// Streams on `account`, moving to siblings or waiting as limits allow.
/// `on_account` hears each account an attempt is sent to after the first.
pub fn stream(
  pool: Pool(account),
  account: account,
  request: types.Request,
  on_event: fn(types.Event) -> types.Control,
  budget: Budget,
  on_account: fn(account) -> Nil,
) -> Result(types.Turn, types.Error) {
  case pool.stream(account, request, on_event) {
    Error(types.HttpError(429, body)) as failed -> {
      let marked = pool.mark(account, body)
      let next = case budget.hops > 0, marked {
        True, Some(Marked(_, True)) ->
          case pool.current() {
            Ok(next) ->
              case pool.same(next, account) {
                True -> None
                False -> Some(next)
              }
            Error(_) -> None
          }
        _, _ -> None
      }
      case next, list.drop(waits, budget.waits), marked {
        Some(next), _, _ -> {
          on_account(next)
          stream(
            pool,
            next,
            request,
            on_event,
            Budget(..budget, hops: budget.hops - 1),
            on_account,
          )
        }
        None, _, Some(Marked(Lasting, _)) -> failed
        None, [delay, ..], _ ->
          case pool.current() {
            Ok(retry) -> {
              budget.pause(delay)
              on_account(retry)
              stream(
                pool,
                retry,
                request,
                on_event,
                Budget(..budget, waits: budget.waits + 1),
                on_account,
              )
            }
            Error(_) -> failed
          }
        None, [], _ -> failed
      }
    }
    other -> other
  }
}

type Slot

@external(erlang, "erlang", "make_ref")
fn new_slot() -> Slot

@external(erlang, "albedo_accounts", "served")
fn served(slot: Slot, account: account) -> Nil

@external(erlang, "albedo_accounts", "last_served")
fn last_served(slot: Slot, first: account) -> account

@external(erlang, "albedo_retry", "sleep")
fn sleep(milliseconds: Int) -> Nil
