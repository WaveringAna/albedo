//// Bot provisioning with the human's own Discord login: one provisioner run
//// creates the application, its bot user, the Message Content intent and a
//// token, then the bot row; a second run may add the bot to a server. Both
//// may stop for a two-factor code, which arrives over HTTP. Provisions live
//// in memory only: at most four, finished ones for ten minutes.

import albedo/actor_call
import albedo/clock
import albedo/daemon/bus
import albedo/daemon/mail
import albedo/daemon/store
import albedo/harness/extensions/discord/ledger
import albedo/harness/extensions/discord/manager
import albedo/harness/extensions/discord/port
import gleam/dynamic/decode
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result

pub type Provision {
  Provision(
    id: String,
    session: String,
    name: String,
    state: String,
    step: Option(String),
    methods: List(String),
    mfa_error: Option(String),
    error: Option(String),
    code: Option(String),
    /// The bot row, once the application exists.
    bot: Option(String),
  )
}

pub type Failure {
  NotFound
  NotWaiting
  Unavailable
}

pub opaque type Message {
  Start(Request, reply: Subject(Provision))
  Line(id: String, generation: Int, line: String)
  Mfa(id: String, code: String, reply: Subject(Result(Provision, Failure)))
  Cancel(id: String, reply: Subject(Result(Provision, Failure)))
  Get(id: String, reply: Subject(Result(Provision, Failure)))
}

/// What a provision needs: how to reach Discord as the human, whose id becomes
/// the bot's creator and owner.
pub type Request {
  Request(
    session: String,
    name: String,
    guild: Option(String),
    login: ledger.Login,
    owner_id: String,
  )
}

type Phase {
  Creating
  Authorizing(application: String)
}

type Item {
  Item(
    provision: Provision,
    request: Request,
    pid: Option(Pid),
    generation: Int,
    phase: Phase,
    finished_at: Option(Int),
  )
}

type State {
  State(
    db: store.Store,
    self: Subject(Message),
    items: List(Item),
    generation: Int,
  )
}

const kept = 4

const expiry_ms = 600_000

const call_timeout = 15_000

pub const portal_url = "https://discord.com/developers/applications"

pub fn start(
  db: store.Store,
) -> Result(actor.Started(Subject(Message)), actor.StartError) {
  actor.new_with_initialiser(5000, fn(self) {
    Ok(
      actor.initialised(State(db, self, [], 0))
      |> actor.returning(self),
    )
  })
  |> actor.on_message(handle)
  |> actor.named(name())
  |> actor.start
}

fn subject() -> Subject(Message) {
  process.named_subject(name())
}

pub fn begin(request: Request) -> Result(Provision, Failure) {
  actor_call.try_call(subject(), call_timeout, Start(request, _))
  |> result.replace_error(Unavailable)
}

pub fn get(id: String) -> Result(Provision, Failure) {
  ask(Get(id, _))
}

pub fn mfa(id: String, code: String) -> Result(Provision, Failure) {
  ask(Mfa(id, code, _))
}

pub fn cancel(id: String) -> Result(Provision, Failure) {
  ask(Cancel(id, _))
}

fn ask(
  message: fn(Subject(Result(Provision, Failure))) -> Message,
) -> Result(Provision, Failure) {
  actor_call.try_call(subject(), call_timeout, message)
  |> result.replace_error(Unavailable)
  |> result.flatten
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  let state = pruned(state)
  case message {
    Start(request, reply) -> {
      let provision =
        Provision(
          mail.new_id(),
          request.session,
          request.name,
          "running",
          None,
          [],
          None,
          None,
          None,
          None,
        )
      let item = Item(provision, request, None, 0, Creating, None)
      let state = State(..state, items: [item, ..state.items])
      let state =
        launch(
          state,
          item,
          json.object([
            #("op", json.string("create")),
            #("name", json.string(request.name)),
            #("avatar", json.null()),
          ]),
        )
      let #(kept_items, dropped) = list.split(state.items, kept)
      list.each(dropped, stop)
      let state = State(..state, items: kept_items)
      process.send(reply, find(state, provision.id) |> result.unwrap(provision))
      actor.continue(state)
    }
    Get(id, reply) -> {
      process.send(reply, find(state, id))
      actor.continue(state)
    }
    Mfa(id, code, reply) ->
      case item(state, id) {
        Ok(
          Item(pid: Some(pid), provision: Provision(state: "mfa", ..) as p, ..) as found,
        ) -> {
          port.write(
            pid,
            json.to_string(json.object([#("code", json.string(code))])),
          )
          let state =
            put(
              state,
              Item(..found, provision: Provision(..p, state: "running")),
            )
          process.send(reply, find(state, id))
          actor.continue(state)
        }
        Ok(_) -> {
          process.send(reply, Error(NotWaiting))
          actor.continue(state)
        }
        Error(_) -> {
          process.send(reply, Error(NotFound))
          actor.continue(state)
        }
      }
    Cancel(id, reply) ->
      case item(state, id) {
        Ok(found) if found.finished_at == None -> {
          stop(found)
          let state =
            put(
              state,
              finish(
                Item(..found, pid: None),
                Provision(..found.provision, state: "cancelled"),
              ),
            )
          process.send(reply, find(state, id))
          actor.continue(state)
        }
        Ok(found) -> {
          process.send(reply, Ok(found.provision))
          actor.continue(state)
        }
        Error(_) -> {
          process.send(reply, Error(NotFound))
          actor.continue(state)
        }
      }
    Line(id, generation, line) ->
      case item(state, id) {
        Ok(found)
          if found.generation == generation && found.finished_at == None
        -> actor.continue(line_from(state, found, line))
        _ -> actor.continue(state)
      }
  }
}

fn item(state: State, id: String) -> Result(Item, Nil) {
  list.find(state.items, fn(item) { item.provision.id == id })
}

fn find(state: State, id: String) -> Result(Provision, Failure) {
  item(state, id)
  |> result.map(fn(item) { item.provision })
  |> result.replace_error(NotFound)
}

/// Replaces an item in place and tells clients it changed.
fn put(state: State, updated: Item) -> State {
  changed(updated.provision.id)
  State(
    ..state,
    items: list.map(state.items, fn(item) {
      case item.provision.id == updated.provision.id {
        True -> updated
        False -> item
      }
    }),
  )
}

fn changed(id: String) -> Nil {
  bus.invalidate(
    ["/extensions/discord/provisions/" <> id, "/extensions/discord/bots"],
    [],
    False,
  )
}

fn pruned(state: State) -> State {
  let now = clock.monotonic_ms()
  State(
    ..state,
    items: list.filter(state.items, fn(item) {
      case item.finished_at {
        Some(at) -> now - at < expiry_ms
        None -> True
      }
    }),
  )
}

fn stop(item: Item) -> Nil {
  case item.pid {
    Some(pid) -> port.close(pid)
    None -> Nil
  }
}

fn finish(item: Item, provision: Provision) -> Item {
  Item(..item, provision: provision, finished_at: Some(clock.monotonic_ms()))
}

/// Runs one provisioner request for `item`, as a new generation.
fn launch(state: State, item: Item, request: json.Json) -> State {
  let generation = state.generation + 1
  let self = state.self
  let id = item.provision.id
  let state = State(..state, generation: generation)
  let item = Item(..item, generation: generation)
  case
    port.open(
      "albedo_discord_provision.py",
      provisioner_env(item.request.login),
      fn(line) { process.send(self, Line(id, generation, line)) },
    )
  {
    Ok(pid) -> {
      port.write(pid, json.to_string(request))
      put(state, Item(..item, pid: Some(pid)))
    }
    Error(reason) ->
      put(
        state,
        finish(
          item,
          Provision(
            ..item.provision,
            state: "failed",
            error: Some(reason),
            code: Some("http"),
          ),
        ),
      )
  }
}

type Event {
  Progress(String)
  Prompt(methods: List(String), error: Option(String))
  Made(Created)
  Authorized
  Failed(error: String, code: String)
  Exited
}

type Created {
  Created(application: String, user_id: String, username: String, token: String)
}

fn event_decoder(phase: Phase) -> decode.Decoder(Event) {
  use kind <- decode.field("type", decode.string)
  case kind {
    "progress" ->
      decode.field("step", decode.string, fn(step) {
        decode.success(Progress(step))
      })
    "mfa" -> {
      use methods <- decode.optional_field(
        "methods",
        [],
        decode.list(decode.string),
      )
      use error <- decode.optional_field(
        "error",
        None,
        decode.optional(decode.string),
      )
      decode.success(Prompt(methods, error))
    }
    "result" -> {
      use ok <- decode.field("ok", decode.bool)
      case ok, phase {
        True, Creating -> {
          use created <- decode.field("result", {
            use application <- decode.field("application_id", decode.string)
            use user_id <- decode.field("bot_user_id", decode.string)
            use username <- decode.optional_field(
              "username",
              None,
              decode.optional(decode.string),
            )
            use token <- decode.field("token", decode.string)
            decode.success(Created(
              application,
              user_id,
              option.unwrap(username, ""),
              token,
            ))
          })
          decode.success(Made(created))
        }
        True, Authorizing(_) -> decode.success(Authorized)
        False, _ -> {
          use error <- decode.optional_field(
            "error",
            "provisioning failed",
            decode.string,
          )
          use code <- decode.optional_field("code", "http", decode.string)
          decode.success(Failed(error, code))
        }
      }
    }
    _ -> decode.success(Exited)
  }
}

fn line_from(state: State, item: Item, line: String) -> State {
  let p = item.provision
  case json.parse(line, event_decoder(item.phase)) {
    Error(_) -> state
    Ok(Progress(step)) ->
      put(state, Item(..item, provision: Provision(..p, step: Some(step))))
    Ok(Prompt(methods, error)) ->
      put(
        state,
        Item(
          ..item,
          provision: Provision(
            ..p,
            state: "mfa",
            methods: methods,
            mfa_error: error,
          ),
        ),
      )
    Ok(Failed(error, code)) ->
      put(
        state,
        finish(
          Item(..item, pid: None),
          Provision(..p, state: "failed", error: Some(error), code: Some(code)),
        ),
      )
    Ok(Exited) ->
      put(
        state,
        finish(
          Item(..item, pid: None),
          Provision(
            ..p,
            state: "failed",
            error: Some("the provisioner stopped without an answer"),
            code: Some("http"),
          ),
        ),
      )
    Ok(Authorized) ->
      put(state, finish(Item(..item, pid: None), Provision(..p, state: "done")))
    Ok(Made(created)) -> created_bot(state, Item(..item, pid: None), created)
  }
}

/// The application exists: record the bot as POST /bots would, owned by the
/// human, then add it to the chosen server if there is one.
fn created_bot(state: State, item: Item, created: Created) -> State {
  let p = item.provision
  let request = item.request
  let made = {
    use bot <- result.try(ledger.create(
      state.db,
      request.session,
      request.name,
      created.token,
      request.owner_id,
    ))
    use _ <- result.map(ledger.record_identity(
      state.db,
      bot.id,
      created.user_id,
      created.username,
      Some(created.application),
    ))
    bot
  }
  case made {
    Error(error) ->
      put(
        state,
        finish(
          item,
          Provision(
            ..p,
            state: "failed",
            error: Some(describe(error)),
            code: Some("http"),
          ),
        ),
      )
    Ok(bot) -> {
      manager.reconcile()
      manager.changed(bot.id)
      let p = Provision(..p, bot: Some(bot.id), methods: [], mfa_error: None)
      case request.guild {
        None -> put(state, finish(item, Provision(..p, state: "done")))
        Some(guild) -> {
          let item =
            Item(
              ..item,
              phase: Authorizing(created.application),
              provision: Provision(..p, step: Some("authorize")),
            )
          launch(
            put(state, item),
            item,
            json.object([
              #("op", json.string("authorize")),
              #("application_id", json.string(created.application)),
              #("guild_id", json.string(guild)),
            ]),
          )
        }
      }
    }
  }
}

fn describe(error: ledger.Error) -> String {
  case error {
    ledger.Exists -> "this session already has a discord bot"
    ledger.SessionNotFound -> "the session no longer exists"
    ledger.Invalid(detail) | ledger.Storage(detail) -> detail
    ledger.NotFound | ledger.Conflict -> "the bot could not be recorded"
  }
}

/// One provisioner request answered at once (no two-factor prompt), for the
/// account routes. The error is `#(code, message)`.
pub fn run_once(
  login: ledger.Login,
  request: json.Json,
  decoder: decode.Decoder(a),
) -> Result(a, #(String, String)) {
  let lines = process.new_subject()
  use pid <- result.try(
    port.open(
      "albedo_discord_provision.py",
      provisioner_env(login),
      process.send(lines, _),
    )
    |> result.map_error(fn(reason) { #("http", reason) }),
  )
  port.write(pid, json.to_string(request))
  let answer =
    await_result(lines, decoder, clock.monotonic_ms() + once_timeout(login))
  port.close(pid)
  answer
}

fn provisioner_env(login: ledger.Login) -> List(#(String, String)) {
  case login {
    ledger.Token(token) -> [#("ALBEDO_DISCORD_USER_TOKEN", token)]
    ledger.Browser -> [#("ALBEDO_DISCORD_BROWSER", "1")]
  }
}

/// Browser mode waits for a person to sign in in the window it opened; a token
/// run is only as slow as Discord.
fn once_timeout(login: ledger.Login) -> Int {
  case login {
    ledger.Token(_) -> 30_000
    ledger.Browser -> 600_000
  }
}

fn await_result(
  lines: Subject(String),
  decoder: decode.Decoder(a),
  deadline: Int,
) -> Result(a, #(String, String)) {
  case process.receive(lines, int.max(0, deadline - clock.monotonic_ms())) {
    Error(_) -> Error(#("http", "Discord did not answer in time"))
    Ok(line) -> {
      let outcome =
        json.parse(line, {
          use kind <- decode.field("type", decode.string)
          case kind {
            "result" -> {
              use ok <- decode.field("ok", decode.bool)
              case ok {
                True ->
                  decode.field("result", decoder, fn(value) {
                    decode.success(Some(Ok(value)))
                  })
                False -> {
                  use error <- decode.optional_field(
                    "error",
                    "failed",
                    decode.string,
                  )
                  use code <- decode.optional_field(
                    "code",
                    "http",
                    decode.string,
                  )
                  decode.success(Some(Error(#(code, error))))
                }
              }
            }
            "mfa" ->
              decode.success(
                Some(
                  Error(#("mfa_failed", "Discord asked for a two-factor code")),
                ),
              )
            "exited" ->
              decode.success(
                Some(
                  Error(#("http", "the provisioner stopped without an answer")),
                ),
              )
            _ -> decode.success(None)
          }
        })
      case outcome {
        Ok(Some(answer)) -> answer
        Ok(None) -> await_result(lines, decoder, deadline)
        Error(_) -> Error(#("http", "the provisioner answered unexpectedly"))
      }
    }
  }
}

@external(erlang, "albedo_discord", "provisions_name")
fn name() -> process.Name(Message)
