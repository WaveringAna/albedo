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
import gleam/list
import gleam/option.{type Option, None, Some}

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
pub fn marked(lasting: Bool, room: Bool) -> Marked {
  case lasting {
    True -> Marked(Lasting, room)
    False -> Marked(Brief, room)
  }
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
pub fn budget() -> Budget {
  Budget(8, 0, sleep)
}

/// Backoff when every account is briefly limited: about a minute in all.
const waits = [4000, 8000, 15_000, 30_000]

/// An upstream that rotates through `pool` starting from `first`. `explain`
/// is given the account the failing attempt went to, not necessarily `first`.
pub fn upstream(
  endpoint: String,
  protocol: types.Protocol,
  pool: Pool(account),
  first: account,
  explain: fn(account, types.Error) -> Option(String),
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

pub type Slot

@external(erlang, "erlang", "make_ref")
fn new_slot() -> Slot

@external(erlang, "albedo_accounts", "served")
fn served(slot: Slot, account: account) -> Nil

@external(erlang, "albedo_accounts", "last_served")
fn last_served(slot: Slot, first: account) -> account

@external(erlang, "albedo_retry", "sleep")
fn sleep(milliseconds: Int) -> Nil
