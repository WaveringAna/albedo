import albedo/daemon/configuration
import albedo/daemon/conversation
import albedo/daemon/reaper
import albedo/daemon/session
import albedo/harness/runtime
import gleam/bytes_tree
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/http.{Get, Post}
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import gleam/string_tree
import mist

pub type Config {
  Config(home: String, token: String, idle_ms: Int, budget_kb: Int)
}

/// How long without a word from any client counts as detached. An attached
/// client reads its session every 100ms, so silence is a reliable signal.
const detached_ms = 30_000

/// Examine idleness often enough to honour the limit, never more than once a minute.
fn sweep_interval(config: Config) -> Int {
  int.clamp(config.idle_ms / 4, 2000, 60_000)
}

type Message {
  Create(String, String, Subject(Result(conversation.Info, String)))
  Lookup(String, Subject(Result(session.Session, String)))
  List(Subject(List(conversation.Info)))
  WorkerDown(process.Down)
  Sweep
  Shutdown
}

type State {
  State(
    host: runtime.Runtime,
    config: Config,
    sessions: Dict(String, #(conversation.Info, session.Session)),
    self: Subject(Message),
  )
}

type Stream {
  Tick
}

pub fn start(config: Config, port: Int) -> Result(Int, String) {
  use registry <- result.try(
    actor.new_with_initialiser(30_000, fn(self) {
      use host <- result.try(
        runtime.start(config.home <> "/albedo.sqlite")
        |> result.replace_error("could not start runtime"),
      )
      use _ <- result.try(conversation.initialise(runtime.ledger(host)))
      use _ <- result.try(case configuration.legacy(config.home) {
        Ok(provider) ->
          conversation.assign_provider(runtime.ledger(host), provider.name)
        Error(_) -> Ok(Nil)
      })
      use saved <- result.try(conversation.list(runtime.ledger(host)))
      let sessions =
        list.filter_map(saved, fn(info) {
          case session.start(host, info, config.home) {
            Ok(worker) -> {
              watch(worker)
              Ok(#(info.id, #(info, worker)))
            }
            Error(_) -> {
              io.println(
                "session unavailable: "
                <> info.id
                <> "; check its workspace and saved state",
              )
              Error(Nil)
            }
          }
        })
      let _ = process.send_after(self, sweep_interval(config), Sweep)
      Ok(
        actor.initialised(State(host, config, dict.from_list(sessions), self))
        |> actor.returning(self)
        |> actor.selecting(
          process.new_selector()
          |> process.select(self)
          |> process.select_monitors(WorkerDown),
        ),
      )
    })
    |> actor.on_message(handle)
    |> actor.start
    |> result.map_error(string.inspect),
  )
  let selected_port = process.new_subject()
  use _ <- result.try(
    mist.new(route(config, registry.data, _))
    |> mist.bind("127.0.0.1")
    |> mist.port(port)
    |> mist.after_start(fn(actual, _, _) { process.send(selected_port, actual) })
    |> mist.start
    |> result.map_error(string.inspect),
  )
  process.receive(selected_port, 1000)
  |> result.replace_error("listener did not report its port")
}

fn handle(state: State, message: Message) {
  case message {
    Create(cwd, model, reply) -> {
      let created = {
        use provider <- result.try(configuration.active(state.config.home))
        let info =
          conversation.Info(
            new_id(),
            "new session",
            cwd,
            provider.name,
            case model {
              "" -> provider.model
              _ -> model
            },
            provider.protocol,
            "idle",
            None,
          )
        case
          directory(cwd)
          && string.trim(info.model) != ""
          && string.byte_size(info.model) <= 512
        {
          False -> Error("expected an existing absolute workspace and a model")
          True -> {
            use _ <- result.try(conversation.create(
              runtime.ledger(state.host),
              info,
            ))
            use worker <- result.try(
              session.start(state.host, info, state.config.home)
              |> result.map_error(string.inspect),
            )
            Ok(#(info, worker))
          }
        }
      }
      case created {
        Ok(#(info, worker)) -> {
          watch(worker)
          process.send(reply, Ok(info))
          actor.continue(
            State(
              ..state,
              sessions: dict.insert(state.sessions, info.id, #(info, worker)),
            ),
          )
        }
        Error(error) -> {
          process.send(reply, Error(error))
          actor.continue(state)
        }
      }
    }
    Lookup(id, reply) -> {
      process.send(
        reply,
        dict.get(state.sessions, id)
          |> result.map(fn(pair) { pair.1 })
          |> result.replace_error("session not found"),
      )
      actor.continue(state)
    }
    List(reply) -> {
      process.send(
        reply,
        conversation.list(runtime.ledger(state.host)) |> result.unwrap([]),
      )
      actor.continue(state)
    }
    WorkerDown(process.ProcessDown(_, pid, _)) -> {
      let entry =
        dict.values(state.sessions)
        |> list.find(fn(pair) { process.subject_owner(pair.1) == Ok(pid) })
      case entry {
        Error(_) -> actor.continue(state)
        Ok(#(previous, _)) -> {
          runtime.reset_session(state.host, previous.id)
          let info =
            conversation.list(runtime.ledger(state.host))
            |> result.replace_error(Nil)
            |> result.try(list.find(_, fn(info) { info.id == previous.id }))
            |> result.unwrap(previous)
          case session.start(state.host, info, state.config.home) {
            Ok(worker) -> {
              watch(worker)
              actor.continue(
                State(
                  ..state,
                  sessions: dict.insert(state.sessions, info.id, #(info, worker)),
                ),
              )
            }
            Error(_) ->
              actor.continue(
                State(..state, sessions: dict.delete(state.sessions, info.id)),
              )
          }
        }
      }
    }
    WorkerDown(_) -> actor.continue(state)
    Sweep -> {
      // Off the registry: releasing a kernel writes its variables to disk, and
      // no API call should wait behind that.
      let workers = dict.values(state.sessions) |> list.map(fn(pair) { pair.1 })
      let config = state.config
      let _ = process.spawn_unlinked(fn() { reap(workers, config) })
      let _ =
        process.send_after(state.self, sweep_interval(state.config), Sweep)
      actor.continue(state)
    }
    Shutdown -> {
      dict.each(state.sessions, fn(_, pair) { session.close(pair.1) })
      runtime.stop(state.host)
      shutdown()
      actor.stop()
    }
  }
}

/// Release kernels that nobody is attached to: first those idle past the limit,
/// then, while the pool is over budget, the ones unattended longest. A session
/// that is attached or running is never a candidate, though its memory counts.
fn reap(workers: List(session.Session), config: Config) -> Nil {
  let held =
    list.filter_map(workers, fn(worker) {
      let report = session.report(worker)
      case report.kernel {
        Some(pid) -> Ok(#(pid, worker, report))
        None -> Error(Nil)
      }
    })
  let usage = rss(list.map(held, fn(entry) { entry.0 }))
  let candidates =
    list.map(held, fn(entry) {
      let #(pid, _, report) = entry
      reaper.Candidate(
        pid,
        report.idle_ms,
        report.running,
        list.key_find(usage, pid) |> result.unwrap(0),
      )
    })
  let workers = list.map(held, fn(entry) { #(entry.0, entry.1) })
  reaper.victims(
    candidates,
    reaper.Limits(config.idle_ms, config.budget_kb, detached_ms),
  )
  |> list.each(fn(victim) {
    case list.key_find(workers, victim.pid) {
      Ok(worker) -> {
        let _ = session.release(worker)
        Nil
      }
      Error(_) -> Nil
    }
  })
}

@external(erlang, "albedo_daemon", "rss")
fn rss(pids: List(Int)) -> List(#(Int, Int))

fn info_json(info: conversation.Info) -> json.Json {
  json.object([
    #("id", json.string(info.id)),
    #("title", json.string(info.title)),
    #("workspace", json.string(info.cwd)),
    #("provider", json.string(info.provider)),
    #("model", json.string(info.model)),
    #("protocol", json.string(conversation.protocol(info.protocol))),
    #("last_assistant_at", case info.last_assistant_at {
      Some(timestamp) -> json.int(timestamp)
      None -> json.null()
    }),
  ])
}

fn reply(status: Int, value: json.Json) {
  response.new(status)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(mist.Bytes(
    value |> json.to_string_tree |> bytes_tree.from_string_tree,
  ))
}

fn error(status: Int, message: String) {
  reply(status, json.object([#("error", json.string(message))]))
}

fn body(req, decoder) {
  mist.read_body(req, 1_100_000)
  |> result.replace_error("invalid request body")
  |> result.try(fn(req) {
    json.parse_bits(req.body, decoder)
    |> result.replace_error("invalid request JSON")
  })
}

fn route(
  config: Config,
  registry: Subject(Message),
  req: request.Request(mist.Connection),
) -> response.Response(mist.ResponseData) {
  let authorised =
    request.get_header(req, "authorization") == Ok("Bearer " <> config.token)
  // Local API is authenticated and not a cross-origin browser endpoint.
  case authorised && request.get_header(req, "origin") == Error(Nil) {
    False -> error(403, "forbidden")
    True ->
      case req.method, request.path_segments(req) {
        Get, ["health"] ->
          reply(
            200,
            json.object([#("ok", json.bool(True)), #("version", json.int(2))]),
          )
        Get, ["sessions"] ->
          reply(200, json.array(actor.call(registry, 5000, List), info_json))
        Post, ["sessions"] -> {
          let decoder = {
            use cwd <- decode.field("workspace", decode.string)
            use model <- decode.optional_field("model", "", decode.string)
            decode.success(#(cwd, model))
          }
          case
            body(req, decoder)
            |> result.try(fn(pair) {
              actor.call(registry, 15_000, Create(pair.0, pair.1, _))
            })
          {
            Ok(info) -> reply(201, info_json(info))
            Error(e) -> error(400, e)
          }
        }
        Post, ["shutdown"] -> {
          let _ = process.send_after(registry, 100, Shutdown)
          reply(200, json.object([#("ok", json.bool(True))]))
        }
        _, ["sessions", id, operation] ->
          case actor.call(registry, 5000, Lookup(id, _)) {
            Error(e) -> error(404, e)
            Ok(worker) ->
              case req.method, operation {
                Get, "status" ->
                  response.new(200)
                  |> response.set_header("content-type", "application/json")
                  |> response.set_body(
                    mist.Bytes(bytes_tree.from_string(session.status(worker))),
                  )
                Post, "events" -> {
                  let decoder = {
                    use text <- decode.field("content", decode.string)
                    use client_id <- decode.optional_field(
                      "clientId",
                      "",
                      decode.string,
                    )
                    decode.success(#(text, client_id))
                  }
                  case
                    body(req, decoder)
                    |> result.try(fn(pair) {
                      session.submit(worker, pair.0, pair.1)
                    })
                  {
                    Ok(_) -> reply(202, json.object([#("ok", json.bool(True))]))
                    Error(e) -> error(409, e)
                  }
                }
                Post, "model" -> {
                  case
                    body(
                      req,
                      decode.field("model", decode.string, decode.success),
                    )
                    |> result.try(session.set_model(worker, _))
                  {
                    Ok(_) -> reply(200, json.object([#("ok", json.bool(True))]))
                    Error(e) -> error(409, e)
                  }
                }
                Post, "interrupt" ->
                  reply(
                    200,
                    json.object([
                      #("interrupted", json.bool(session.interrupt(worker))),
                    ]),
                  )
                Get, "stream" -> stream(req, worker)
                _, _ -> error(404, "unknown session operation")
              }
          }
        _, _ -> error(404, "not found")
      }
  }
}

fn stream(req, worker) {
  let after =
    request.get_query(req)
    |> result.unwrap([])
    |> list.key_find("after_seq")
    |> result.try(int.parse)
    |> result.unwrap(-1)
  mist.server_sent_events(
    req,
    response.new(200),
    fn(self) {
      process.send(self, Tick)
      #(self, after)
    },
    fn(state, _, connection) {
      let page = session.read(worker, state.1)
      let events =
        string_tree.from_strings([
          "{\"cursor\":",
          int.to_string(page.cursor),
          ",\"events\":[",
        ])
        |> string_tree.append_tree(
          page.events
          |> list.map(string_tree.from_string)
          |> string_tree.join(","),
        )
        |> string_tree.append("]}")
      case mist.send_event(connection, mist.event(events)) {
        Error(_) -> actor.stop()
        Ok(_) -> {
          let _ = process.send_after(state.0, 100, Tick)
          actor.continue(#(state.0, page.cursor))
        }
      }
    },
  )
}

pub fn main() -> Nil {
  let home = env("ALBEDO_HOME")
  let token = env("ALBEDO_TOKEN")
  let config =
    Config(
      home,
      token,
      setting("ALBEDO_IDLE_SECONDS", 31 * 60, 10, 604_800) * 1000,
      setting("ALBEDO_KERNEL_BUDGET_MB", 2048, 64, 1_048_576) * 1024,
    )
  let assert True = string.byte_size(token) >= 32 && home != ""
    as "start albedo through its CLI"
  let assert Ok(port) = start(config, 0)
  let assert Ok(_) = ready(home, port, token)
  process.sleep_forever()
}

/// An operator's limit, clamped to a range this daemon can honour.
fn setting(name: String, fallback: Int, low: Int, high: Int) -> Int {
  case int.parse(string.trim(env(name))) {
    Ok(value) -> int.clamp(value, low, high)
    Error(_) -> fallback
  }
}

@external(erlang, "albedo_daemon", "env")
fn env(name: String) -> String

@external(erlang, "albedo_daemon", "ready")
fn ready(home: String, port: Int, token: String) -> Result(Nil, String)

@external(erlang, "albedo_daemon", "directory")
fn directory(path: String) -> Bool

@external(erlang, "albedo_daemon", "shutdown")
fn shutdown() -> Nil

@external(erlang, "albedo_native", "new_id")
fn new_id() -> String

fn watch(worker: session.Session) -> Nil {
  case process.subject_owner(worker) {
    Ok(pid) -> {
      let _ = process.monitor(pid)
      Nil
    }
    Error(_) -> Nil
  }
}
