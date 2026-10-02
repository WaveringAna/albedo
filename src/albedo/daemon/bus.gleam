//// The agents bus: one daemon-wide feed of what every session is doing, for
//// the orchestrator view. It carries small events only; a session's own
//// stream stays the place for whole transcripts, tool output, and resets.

import albedo/daemon/family
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string

/// Forward one of a session's stream events, reduced to what the view shows.
pub fn activity(session: String, event: String) -> Nil {
  case has_subscribers() {
    False -> Nil
    True -> publish_activity(session, event)
  }
}

fn publish_activity(session: String, event: String) -> Nil {
  let kind = kind(event)
  case kind {
    // Deltas and progress are small and frequent: tag them and pass them on.
    "text"
    | "thinking"
    | "arguments_delta"
    | "tool_progress"
    | "turn_started"
    | "interrupted" ->
      publish(
        "{\"session\":" <> quote(session) <> "," <> string.drop_start(event, 1),
      )
    "user" | "message" | "error" | "note" ->
      publish(
        event_json(session, kind, [
          #("text", json.string(field(event, "text") |> string.slice(0, 240))),
          #("source", json.string(field(event, "source"))),
        ]),
      )
    "tool" ->
      publish(
        event_json(session, "tool", [
          #("name", json.string(field(event, "name"))),
          #("callId", json.string(field(event, "callId"))),
          #("output", json.string(tool_output(field(event, "result")))),
        ]),
      )
    _ -> Nil
  }
}

/// A run started or ended. Also recorded, so `is_running` can answer without
/// asking the session.
pub fn running(session: String, running: Bool) -> Nil {
  mark_running(session, running)
  publish(event_json(session, "running", [#("running", json.bool(running))]))
}

/// Whether `session` was running a turn when it last said.
@external(erlang, "albedo_bus", "mark_running")
fn mark_running(session: String, running: Bool) -> Nil

@external(erlang, "albedo_bus", "running")
pub fn is_running(session: String) -> Bool

/// A child session joined the tree.
pub fn spawned(member: family.Member, model: String) -> Nil {
  publish(
    event_json(member.session, "spawn", [
      #("parent", json.string(member.parent)),
      #("name", json.string(member.name)),
      #("depth", json.int(member.depth)),
      #("model", json.string(model)),
    ]),
  )
}

/// A session's name changed; `name` is what the agents view calls it now.
pub fn renamed(session: String, name: String) -> Nil {
  publish(event_json(session, "renamed", [#("name", json.string(name))]))
}

/// A child was closed: its work stays, its kernel goes.
pub fn closed(session: String) -> Nil {
  publish(event_json(session, "closed", []))
}

/// A short note an agent posts about where it is, without starting a turn.
pub fn progress(session: String, text: String) -> Nil {
  publish(event_json(session, "progress", [#("text", json.string(text))]))
}

pub fn gone(session: String) -> Nil {
  forget_running(session)
  publish(event_json(session, "gone", []))
}

@external(erlang, "albedo_bus", "forget")
fn forget_running(session: String) -> Nil

/// A letter was posted: who to whom, what kind, and how big.
pub fn mailed(
  id: String,
  sender: Option(String),
  sender_name: String,
  recipient: String,
  kind: String,
  bytes: Int,
) -> Nil {
  publish(
    json.object([
      #("type", json.string("mail")),
      #("id", json.string(id)),
      #("from", json.nullable(sender, json.string)),
      #("fromName", json.string(sender_name)),
      #("to", json.string(recipient)),
      #("kind", json.string(kind)),
      #("bytes", json.int(bytes)),
    ])
    |> json.to_string,
  )
}

/// One subscriber's bounded queue, removed when its stream process dies.
pub type Subscription

pub type Batch {
  Batch(events: List(String))
  Overflow
}

/// Publishers queue events before sending this payload-free notification.
@external(erlang, "albedo_bus", "subscribe")
pub fn subscribe(owner: process.Pid, notify: fn() -> Nil) -> Subscription

/// Take one bounded batch, keeping notification latched until sending finishes.
@external(erlang, "albedo_bus", "drain")
pub fn drain(subscription: Subscription) -> Batch

/// Rearm after sending. A timer can run before the pending wake was consumed.
@external(erlang, "albedo_bus", "rearm")
pub fn rearm(subscription: Subscription, wake_consumed: Bool) -> Nil

fn event_json(
  session: String,
  kind: String,
  fields: List(#(String, json.Json)),
) -> String {
  json.object([
    #("type", json.string(kind)),
    #("session", json.string(session)),
    ..fields
  ])
  |> json.to_string
}

/// The type of a stream event: they are all built with "type" first.
fn kind(event: String) -> String {
  case string.starts_with(event, "{\"type\":\"") {
    False -> ""
    True ->
      string.drop_start(event, 9)
      |> string.split_once("\"")
      |> result.map(fn(pair) { pair.0 })
      |> result.unwrap("")
  }
}

/// The end of what a tool printed: its last few lines, bounded. Python cells
/// answer JSON with an "output" field; anything else is shown as it came.
fn tool_output(result: String) -> String {
  let text =
    json.parse(result, decode.at(["output"], decode.string))
    |> result.unwrap(result)
  let lines = string.split(string.trim_end(text), "\n")
  let kept = list.drop(lines, int.max(0, list.length(lines) - 6))
  string.join(kept, "\n") |> string.slice(0, 600)
}

fn field(event: String, name: String) -> String {
  json.parse(event, decode.at([name], decode.string))
  |> result.unwrap("")
}

fn quote(value: String) -> String {
  json.string(value) |> json.to_string
}

@external(erlang, "albedo_bus", "publish")
fn publish(event: String) -> Nil

@external(erlang, "albedo_bus", "has_subscribers")
fn has_subscribers() -> Bool
