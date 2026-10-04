//// Bounded daemon-wide canonical collection observations. Lifecycle changes
//// invalidate resources; session owners publish one captured activity value.

import albedo/daemon/family
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// Larger changes invalidate the collection scope instead of allocating an
/// unbounded notification. Publication never waits for a subscriber.
pub fn invalidate(
  urls: List(String),
  session_ids: List(String),
  scope_dirty: Bool,
) -> Nil {
  case has_subscribers() {
    False -> Nil
    True -> {
      let truncated = list.length(urls) > 200 || list.length(session_ids) > 200
      publish(
        json.object([
          #("type", json.string("invalidate")),
          #(
            "data",
            json.object([
              #("urls", json.array(list.take(urls, 200), json.string)),
              #(
                "session_ids",
                json.array(list.take(session_ids, 200), json.string),
              ),
              #("scope_dirty", json.bool(scope_dirty || truncated)),
            ]),
          ),
        ])
        |> json.to_string,
      )
    }
  }
}

pub fn activity(session: String, encode: fn() -> String) -> Nil {
  case has_subscribers() {
    False -> Nil
    True -> publish_activity(session, encode())
  }
}

pub fn running(session: String, running: Bool) -> Nil {
  mark_running(session, running)
}

@external(erlang, "albedo_bus", "mark_running")
fn mark_running(session: String, running: Bool) -> Nil

@external(erlang, "albedo_bus", "running")
pub fn is_running(session: String) -> Bool

pub fn spawned(member: family.Member) -> Nil {
  invalidate(
    ["/sessions/" <> member.session, "/sessions/" <> member.parent],
    [member.session, member.parent],
    True,
  )
}

pub fn closed(session: String) -> Nil {
  invalidate(["/sessions/" <> session], [session], True)
}

/// An agent's ephemeral note belongs to its session owner, so the actor's
/// stream, snapshot, and collection tail observe the same publication.
@external(erlang, "albedo_bus", "progress")
pub fn progress(session: String, text: String) -> Nil

@external(erlang, "albedo_bus", "register_progress")
pub fn register_progress(
  session: String,
  owner: process.Pid,
  publish: fn(String) -> Nil,
) -> Nil

pub fn gone(session: String) -> Nil {
  forget_running(session)
  invalidate(["/sessions/" <> session], [session], True)
}

@external(erlang, "albedo_bus", "forget")
fn forget_running(session: String) -> Nil

pub fn mailed(
  id: String,
  sender: Option(String),
  sender_name: String,
  recipient: String,
  kind: String,
  bytes: Int,
) -> Nil {
  let sender_label = case sender_name {
    "" -> None
    name -> Some(scalar_prefix(name, 100))
  }
  publish_mail(
    sender,
    recipient,
    json.object([
      #("type", json.string("mail")),
      #(
        "data",
        json.object([
          #("mail_id", json.string(id)),
          #("sender_session_id", json.nullable(sender, json.string)),
          #("receiver_session_id", json.string(recipient)),
          #("kind", json.string(kind)),
          #("bytes", json.int(bytes)),
          #("sender_label", json.nullable(sender_label, json.string)),
        ]),
      ),
    ])
      |> json.to_string,
  )
}

fn scalar_prefix(value: String, count: Int) -> String {
  string.to_utf_codepoints(value)
  |> list.take(count)
  |> string.from_utf_codepoints
}

/// One subscriber's bounded queue, removed when its stream process dies.
pub type Subscription

pub type Batch {
  Batch(events: List(String))
  Overflow
}

/// Filter activity at producer admission, before a subscriber queue spends
/// its byte/event budget. Invalidation and mail remain visible to the scope.
@external(erlang, "albedo_bus", "subscribe_filtered")
pub fn subscribe_filtered(
  owner: process.Pid,
  notify: fn() -> Nil,
  session_ids: List(String),
) -> Subscription

@external(erlang, "albedo_bus", "set_filter")
pub fn set_filter(subscription: Subscription, session_ids: List(String)) -> Nil

/// Take one bounded batch, keeping notification latched until sending finishes.
@external(erlang, "albedo_bus", "drain")
pub fn drain(subscription: Subscription) -> Batch

/// Rearm after sending. A timer can run before the pending wake was consumed.
@external(erlang, "albedo_bus", "rearm")
pub fn rearm(subscription: Subscription, wake_consumed: Bool) -> Nil

@external(erlang, "albedo_bus", "publish_activity")
fn publish_activity(session: String, event: String) -> Nil

@external(erlang, "albedo_bus", "publish")
fn publish(event: String) -> Nil

@external(erlang, "albedo_bus", "has_subscribers")
fn has_subscribers() -> Bool

@external(erlang, "albedo_bus", "publish_mail")
fn publish_mail(sender: Option(String), recipient: String, event: String) -> Nil
