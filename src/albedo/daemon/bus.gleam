//// The agents bus: one daemon-wide feed of what every session is doing, for
//// the orchestrator view. It carries small events only — a session's own
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
  case kind(event) {
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
        event_json(session, kind(event), [
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

/// A run started or ended.
pub fn running(session: String, running: Bool) -> Nil {
  publish(event_json(session, "running", [#("running", json.bool(running))]))
}

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

/// A child was closed: its work stays, its kernel goes.
pub fn closed(session: String) -> Nil {
  publish(event_json(session, "closed", []))
}

/// A short note an agent posts about where it is, without starting a turn.
pub fn progress(session: String, text: String) -> Nil {
  publish(event_json(session, "progress", [#("text", json.string(text))]))
}

pub fn gone(session: String) -> Nil {
  publish(event_json(session, "gone", []))
}

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

/// Receive every bus event while `owner` lives. `deliver` must only send.
pub fn subscribe(owner: process.Pid, deliver: fn(String) -> Nil) -> Nil {
  bus_subscribe(owner, deliver)
}

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

@external(erlang, "albedo_bus", "subscribe")
fn bus_subscribe(owner: process.Pid, deliver: fn(String) -> Nil) -> Nil
