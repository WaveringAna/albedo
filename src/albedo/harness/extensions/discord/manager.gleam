//// The daemon's Discord gateway owner: one bot process per enabled bot while
//// the discord extension is enabled globally. It keeps each bot's live state,
//// restarts a crashed process with backoff, never restarts one that reported
//// a fatal failure until its token or enabled flag changes, and turns the
//// messages a process reports into letters.

import albedo/actor_call
import albedo/clock
import albedo/daemon/bus
import albedo/daemon/mail
import albedo/daemon/store
import albedo/harness/extension/selection
import albedo/harness/extensions/discord/ingest
import albedo/harness/extensions/discord/ledger
import albedo/harness/extensions/discord/port
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result

pub type User {
  User(id: String, username: String)
}

pub type Status {
  Status(
    state: String,
    detail: Option(String),
    user: Option(User),
    application_id: Option(String),
  )
}

pub opaque type Message {
  Tick
  Reconcile(reply: Subject(Nil))
  Line(bot: String, generation: Int, line: String)
  Down(process.Down)
  Lookup(bot: String, reply: Subject(#(Option(Pid), Status)))
  Snapshot(reply: Subject(Dict(String, Status)))
}

type Live {
  Live(
    token: String,
    pid: Option(Pid),
    generation: Int,
    status: Status,
    failures: Int,
    retry_at: Int,
    fatal: Bool,
  )
}

type State {
  State(
    db: store.Store,
    self: Subject(Message),
    bots: Dict(String, Live),
    generation: Int,
  )
}

/// How often the manager rereads bots and the global selection.
const tick_ms = 2000

/// The longest restart pause after repeated crashes.
const backoff_limit_ms = 60_000

/// How long a request to a bot process may wait for its reply.
pub const request_timeout = 15_000

const catch_up_timeout = 60_000

/// Whether the manager runs in this VM.
pub fn running() -> Bool {
  process.named(name()) |> result.is_ok
}

pub fn start(
  db: store.Store,
) -> Result(actor.Started(Subject(Message)), actor.StartError) {
  actor.new_with_initialiser(5000, fn(self) {
    process.send(self, Tick)
    Ok(
      actor.initialised(State(db, self, dict.new(), 0))
      |> actor.returning(self)
      |> actor.selecting(
        process.new_selector()
        |> process.select(self)
        |> process.select_monitors(Down),
      ),
    )
  })
  |> actor.on_message(handle)
  |> actor.named(name())
  |> actor.start
}

fn subject() -> Subject(Message) {
  process.named_subject(name())
}

/// Rereads the bots now, after a change the caller made.
pub fn reconcile() -> Nil {
  let _ = actor_call.try_call(subject(), request_timeout, Reconcile)
  Nil
}

pub fn status(bot: String) -> Status {
  lookup(bot).1
}

pub fn statuses() -> Dict(String, Status) {
  actor_call.try_call(subject(), request_timeout, Snapshot)
  |> result.unwrap(dict.new())
}

/// The status of a bot the manager has not reported on.
pub fn unknown() -> Status {
  Status("disabled", Some("the discord manager is not running"), None, None)
}

fn lookup(bot: String) -> #(Option(Pid), Status) {
  actor_call.try_call(subject(), request_timeout, Lookup(bot, _))
  |> result.unwrap(#(None, unknown()))
}

/// One request to the bot's process; the reply's `result` as JSON text.
pub fn request(bot: String, body: json.Json) -> Result(String, String) {
  case lookup(bot) {
    #(Some(pid), Status(state: "online", ..)) ->
      port.call(pid, json.to_string(body), request_timeout)
    #(_, status) ->
      Error(
        "the bot is not online ("
        <> status.state
        <> option.map(status.detail, fn(detail) { ": " <> detail })
        |> option.unwrap("")
        <> ")",
      )
  }
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Tick -> {
      process.send_after(state.self, tick_ms, Tick)
      actor.continue(reconciled(state))
    }
    Reconcile(reply) -> {
      let state = reconciled(state)
      process.send(reply, Nil)
      actor.continue(state)
    }
    Lookup(bot, reply) -> {
      process.send(reply, case dict.get(state.bots, bot) {
        Ok(live) -> #(live.pid, live.status)
        Error(_) -> #(None, unknown())
      })
      actor.continue(state)
    }
    Snapshot(reply) -> {
      process.send(
        reply,
        dict.map_values(state.bots, fn(_, live) { live.status }),
      )
      actor.continue(state)
    }
    Line(bot, generation, line) ->
      case dict.get(state.bots, bot) {
        Ok(live) if live.generation == generation ->
          actor.continue(line_from(state, bot, live, line))
        _ -> actor.continue(state)
      }
    Down(process.ProcessDown(pid: pid, ..)) -> {
      let crashed =
        dict.to_list(state.bots)
        |> list.find(fn(entry) { { entry.1 }.pid == Some(pid) })
      case crashed {
        Ok(#(bot, live)) ->
          actor.continue(put(
            state,
            bot,
            failed(live, "the bot process stopped unexpectedly"),
          ))
        Error(_) -> actor.continue(state)
      }
    }
    Down(process.PortDown(..)) -> actor.continue(state)
  }
}

fn put(state: State, bot: String, live: Live) -> State {
  case dict.get(state.bots, bot) {
    Ok(old) if old.status == live.status -> Nil
    _ -> changed(bot)
  }
  State(..state, bots: dict.insert(state.bots, bot, live))
}

/// Tells clients the bot list and this bot changed.
pub fn changed(bot: String) -> Nil {
  bus.invalidate(
    ["/extensions/discord/bots", "/extensions/discord/bots/" <> bot],
    [],
    False,
  )
}

/// Whether the discord extension is enabled for sessions without their own
/// choice, which is what mounts its service.
fn globally_enabled(db: store.Store) -> Bool {
  case selection.overrides(db, "") {
    Ok(overrides) ->
      case list.key_find(overrides, "discord") {
        Ok(enabled) -> enabled
        Error(_) ->
          list.contains(selection.resolved_defaults([], []), "discord")
      }
    Error(_) -> False
  }
}

fn reconciled(state: State) -> State {
  case ledger.runnable(state.db) {
    Error(_) -> state
    Ok(rows) -> {
      let global = globally_enabled(state.db)
      let wanted = list.map(rows, fn(row) { row.id })
      let state =
        dict.fold(state.bots, state, fn(state, bot, live) {
          case list.contains(wanted, bot) {
            True -> state
            False -> {
              let _ = stop(live)
              changed(bot)
              State(..state, bots: dict.delete(state.bots, bot))
            }
          }
        })
      list.fold(rows, state, fn(state, row) {
        reconcile_bot(state, global, row)
      })
    }
  }
}

fn reconcile_bot(state: State, global: Bool, row: ledger.Runnable) -> State {
  let live = case dict.get(state.bots, row.id) {
    Ok(live) if live.token == row.token -> live
    Ok(live) -> {
      let _ = stop(live)
      fresh(row.token)
    }
    Error(_) -> fresh(row.token)
  }
  case global, row.enabled {
    False, _ ->
      put(
        state,
        row.id,
        disabled(
          stop(live),
          "the discord extension is off globally; enable it in /extensions",
        ),
      )
    True, False ->
      put(
        state,
        row.id,
        disabled(
          Live(
            ..stop(live),
            fatal: False,
            failures: 0,
            retry_at: clock.monotonic_ms(),
          ),
          "bot is disabled",
        ),
      )
    True, True ->
      case live.pid, live.fatal, clock.monotonic_ms() >= live.retry_at {
        Some(_), _, _ | None, True, _ | None, False, False ->
          put(state, row.id, live)
        None, False, True -> launch(state, row.id, live)
      }
  }
}

fn fresh(token: String) -> Live {
  let now = clock.monotonic_ms()
  Live(token, None, 0, Status("connecting", None, None, None), 0, now, False)
}

fn disabled(live: Live, detail: String) -> Live {
  Live(
    ..live,
    status: Status(..live.status, state: "disabled", detail: Some(detail)),
  )
}

fn stop(live: Live) -> Live {
  case live.pid {
    Some(pid) -> port.close(pid)
    None -> Nil
  }
  Live(..live, pid: None)
}

fn launch(state: State, bot: String, live: Live) -> State {
  let generation = state.generation + 1
  let self = state.self
  let state = State(..state, generation: generation)
  case
    port.open(
      "albedo_discord.py",
      [#("ALBEDO_DISCORD_TOKEN", live.token)],
      fn(line) { process.send(self, Line(bot, generation, line)) },
    )
  {
    Ok(pid) -> {
      let _ = process.monitor(pid)
      put(
        state,
        bot,
        Live(
          ..live,
          pid: Some(pid),
          generation: generation,
          status: Status(..live.status, state: "connecting", detail: None),
        ),
      )
    }
    Error(reason) ->
      put(state, bot, failed(Live(..live, generation: generation), reason))
  }
}

/// A process that died on its own comes back after a doubling pause.
fn failed(live: Live, reason: String) -> Live {
  let failures = live.failures + 1
  let pause =
    int.min(
      backoff_limit_ms,
      1000 * int.bitwise_shift_left(1, int.min(failures - 1, 6)),
    )
  Live(
    ..live,
    pid: None,
    failures: failures,
    retry_at: clock.monotonic_ms() + pause,
    status: Status(
      ..live.status,
      state: "reconnecting",
      detail: Some(
        reason <> "; restarting in " <> int.to_string(pause / 1000) <> "s",
      ),
    ),
  )
}

type Event {
  Reported(Status)
  Fatal(String)
  Seen(ingest.Message)
  Exited(Int)
}

fn event_decoder() -> decode.Decoder(Event) {
  use kind <- decode.field("type", decode.string)
  case kind {
    "status" -> {
      use state <- decode.field("state", decode.string)
      use detail <- decode.optional_field(
        "detail",
        None,
        decode.optional(decode.string),
      )
      use user <- decode.optional_field(
        "user",
        None,
        decode.optional({
          use id <- decode.field("id", decode.string)
          use username <- decode.optional_field("username", "", decode.string)
          decode.success(User(id, username))
        }),
      )
      use application <- decode.optional_field(
        "application_id",
        None,
        decode.optional(decode.string),
      )
      decode.success(Reported(Status(state, detail, user, application)))
    }
    "fatal" -> {
      use detail <- decode.field("detail", decode.string)
      decode.success(Fatal(detail))
    }
    "message" -> {
      use message <- decode.field("message", ingest.decoder())
      decode.success(Seen(message))
    }
    "exited" -> {
      use status <- decode.field("status", decode.int)
      decode.success(Exited(status))
    }
    _ -> decode.failure(Exited(-1), "event")
  }
}

fn line_from(state: State, bot: String, live: Live, line: String) -> State {
  case json.parse(line, event_decoder()) {
    Error(_) -> state
    Ok(Reported(reported)) -> {
      let status =
        Status(
          ..reported,
          user: option.or(reported.user, live.status.user),
          application_id: option.or(
            reported.application_id,
            live.status.application_id,
          ),
        )
      let live = case reported.state {
        "online" -> {
          online(state.db, bot, live, status)
          Live(..live, failures: 0)
        }
        _ -> live
      }
      put(state, bot, Live(..live, status: status))
    }
    Ok(Fatal(detail)) ->
      put(
        state,
        bot,
        Live(
          ..live,
          fatal: True,
          status: Status(..live.status, state: "failed", detail: Some(detail)),
        ),
      )
    Ok(Exited(code)) ->
      case live.fatal {
        True -> put(state, bot, Live(..live, pid: None))
        False ->
          put(
            state,
            bot,
            failed(
              live,
              "the bot process exited with status " <> int.to_string(code),
            ),
          )
      }
    Ok(Seen(message)) -> {
      let self_id = option.map(live.status.user, fn(user) { user.id })
      case ingest.ingest(state.db, bot, self_id, message) {
        Ok(Some(letter)) -> {
          let _ = mail.deliver(letter)
          Nil
        }
        Ok(None) ->
          case message.is_dm {
            True -> changed(bot)
            False -> Nil
          }
        Error(reason) ->
          io.println_error("discord: message " <> message.id <> ": " <> reason)
      }
      state
    }
  }
}

/// READY or RESUMED: record who the bot is, then ask for what it missed.
fn online(db: store.Store, bot: String, live: Live, status: Status) -> Nil {
  case status.user {
    Some(user) -> {
      let _ =
        ledger.record_identity(
          db,
          bot,
          user.id,
          user.username,
          status.application_id,
        )
      Nil
    }
    None -> Nil
  }
  case live.pid {
    Some(pid) -> {
      process.spawn_unlinked(fn() { catch_up(db, bot, pid) })
      Nil
    }
    None -> Nil
  }
}

fn catch_up(db: store.Store, bot: String, pid: Pid) -> Nil {
  case ledger.cursors(db, bot) {
    Ok([_, ..] as cursors) -> {
      let request =
        json.object([
          #("op", json.string("catch_up")),
          #(
            "channels",
            json.array(cursors, fn(cursor) {
              json.object([
                #("channel_id", json.string(cursor.0)),
                #("after", json.string(cursor.1)),
              ])
            }),
          ),
        ])
      let _ = port.call(pid, json.to_string(request), catch_up_timeout)
      Nil
    }
    _ -> Nil
  }
}

@external(erlang, "albedo_discord", "manager_name")
fn name() -> process.Name(Message)
