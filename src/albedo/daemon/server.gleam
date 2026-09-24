import albedo/daemon/configuration
import albedo/daemon/conversation
import albedo/daemon/history
import albedo/daemon/image
import albedo/daemon/reaper
import albedo/daemon/session
import albedo/harness/command
import albedo/harness/extension
import albedo/harness/runtime
import albedo/openai_api/types
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
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import gleam/string_tree
import mist
import sqlight

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
  Models(String, String, Subject(List(String)))
  ReadTree(String, Int, Int, Subject(Result(history.Page, String)))
  Fork(String, Int, Subject(Result(conversation.Info, String)))
  SetWorkspace(String, String, Subject(Result(conversation.Info, String)))
  WorkerDown(process.Down)
  Sweep
  Shutdown
}

type State {
  State(
    host: runtime.Runtime,
    config: Config,
    sessions: Dict(String, #(conversation.Info, Option(session.Session))),
    self: Subject(Message),
  )
}

type Stream {
  Tick
  Wake
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
        list.map(saved, fn(info) {
          let worker = case conversation.resumable(info.stage) {
            True ->
              case session.start(host, info, config.home) {
                Ok(worker) -> {
                  watch(worker)
                  Some(worker)
                }
                Error(_) -> {
                  io.println(
                    "session unavailable: "
                    <> info.id
                    <> "; recovery will retry when opened",
                  )
                  None
                }
              }
            False -> None
          }
          #(info.id, #(info, worker))
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
            conversation.Idle,
            None,
          )
        case
          directory(cwd)
          && string.trim(info.model) != ""
          && string.byte_size(info.model) <= 512
          && !string.contains(info.model, "\r")
          && !string.contains(info.model, "\n")
        {
          False -> Error("expected an existing absolute workspace and a model")
          True ->
            conversation.create(runtime.ledger(state.host), info)
            |> result.replace(info)
        }
      }
      process.send(reply, created)
      case created {
        Ok(info) ->
          actor.continue(
            State(
              ..state,
              sessions: dict.insert(state.sessions, info.id, #(info, None)),
            ),
          )
        Error(_) -> actor.continue(state)
      }
    }
    Lookup(id, reply) -> {
      let #(state, found) = activate(state, id)
      process.send(reply, found)
      actor.continue(state)
    }
    SetWorkspace(id, cwd, reply) -> {
      let #(state, worker) = activate(state, id)
      let changed = worker |> result.try(session.set_workspace(_, cwd))
      process.send(reply, changed)
      case changed, worker {
        Ok(info), Ok(active) ->
          actor.continue(
            State(
              ..state,
              sessions: dict.insert(state.sessions, id, #(info, Some(active))),
            ),
          )
        _, _ -> actor.continue(state)
      }
    }
    List(reply) -> {
      process.send(
        reply,
        conversation.list(runtime.ledger(state.host)) |> result.unwrap([]),
      )
      actor.continue(state)
    }
    Models(provider, endpoint, reply) -> {
      process.send(reply, runtime.model_names(state.host, provider, endpoint))
      actor.continue(state)
    }
    ReadTree(id, after, limit, reply) -> {
      process.send(
        reply,
        history.page(runtime.ledger(state.host), id, after, limit),
      )
      actor.continue(state)
    }
    Fork(id, checkpoint, reply) -> {
      let forked =
        history.fork(runtime.ledger(state.host), id, new_id(), checkpoint)
      process.send(reply, forked)
      case forked {
        Ok(info) ->
          actor.continue(
            State(
              ..state,
              sessions: dict.insert(state.sessions, info.id, #(info, None)),
            ),
          )
        Error(_) -> actor.continue(state)
      }
    }
    WorkerDown(process.ProcessDown(_, pid, _)) -> {
      let entry =
        dict.values(state.sessions)
        |> list.find(fn(pair) {
          case pair.1 {
            Some(worker) -> process.subject_owner(worker) == Ok(pid)
            None -> False
          }
        })
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
                  sessions: dict.insert(state.sessions, info.id, #(
                    info,
                    Some(worker),
                  )),
                ),
              )
            }
            Error(_) ->
              actor.continue(
                State(
                  ..state,
                  sessions: dict.insert(state.sessions, info.id, #(info, None)),
                ),
              )
          }
        }
      }
    }
    WorkerDown(_) -> actor.continue(state)
    Sweep -> {
      // Off the registry: saving Python state and dropping reloadable history
      // must not make API calls wait behind filesystem or database work.
      let workers =
        dict.values(state.sessions)
        |> list.filter_map(fn(pair) {
          case pair.1 {
            Some(worker) -> Ok(worker)
            None -> Error(Nil)
          }
        })
      let config = state.config
      let _ = process.spawn_unlinked(fn() { reap(workers, config) })
      let _ =
        process.send_after(state.self, sweep_interval(state.config), Sweep)
      actor.continue(state)
    }
    Shutdown -> {
      dict.each(state.sessions, fn(_, pair) {
        case pair.1 {
          Some(worker) -> session.close(worker)
          None -> Nil
        }
      })
      runtime.stop(state.host)
      shutdown()
      actor.stop()
    }
  }
}

fn activate(
  state: State,
  id: String,
) -> #(State, Result(session.Session, String)) {
  case dict.get(state.sessions, id) {
    Error(_) -> #(state, Error("session not found"))
    Ok(#(_, Some(worker))) -> #(state, Ok(worker))
    Ok(#(info, None)) ->
      case session.start(state.host, info, state.config.home) {
        Error(error) -> #(state, Error(string.inspect(error)))
        Ok(worker) -> {
          watch(worker)
          #(
            State(
              ..state,
              sessions: dict.insert(state.sessions, id, #(info, Some(worker))),
            ),
            Ok(worker),
          )
        }
      }
  }
}

/// Release kernels that nobody is attached to: first those idle past the limit,
/// then, while the pool is over budget, the ones unattended longest. A session
/// that is attached or running is never a candidate, though its memory counts.
fn reap(workers: List(session.Session), config: Config) -> Nil {
  let reports =
    list.map(workers, fn(worker) { #(worker, session.report(worker)) })
  let held =
    list.filter_map(reports, fn(entry) {
      let #(worker, report) = entry
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
        report.jobs,
        list.key_find(usage, pid) |> result.unwrap(0),
      )
    })
  let held_workers = list.map(held, fn(entry) { #(entry.0, entry.1) })
  reaper.victims(
    candidates,
    reaper.Limits(config.idle_ms, config.budget_kb, detached_ms),
  )
  |> list.each(fn(victim) {
    case list.key_find(held_workers, victim.pid) {
      Ok(worker) -> {
        let _ = session.release(worker)
        Nil
      }
      Error(_) -> Nil
    }
  })
  // Transcript state is durable and cheap to reload. Keep it only while a
  // client is polling or a run owns its prepared request.
  reports
  |> list.each(fn(entry) {
    let #(worker, report) = entry
    case
      report.history_loaded && !report.running && report.idle_ms >= detached_ms
    {
      True -> {
        let _ = session.evict_history(worker)
        Nil
      }
      False -> Nil
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

fn tree_item_json(item: history.Item) -> json.Json {
  json.object([
    #("id", json.int(item.id)),
    #("type", json.string(history.kind_name(item.kind))),
    #("preview", json.string(item.preview)),
    #("timestamp", case item.timestamp {
      Some(timestamp) -> json.int(timestamp)
      None -> json.null()
    }),
  ])
}

fn tree_page_json(page: history.Page) -> json.Json {
  json.object([
    #("items", json.array(page.items, tree_item_json)),
    #("nextCursor", case page.next_cursor {
      Some(cursor) -> json.int(cursor)
      None -> json.null()
    }),
    #("hasMore", json.bool(page.has_more)),
  ])
}

fn extension_json(summary: extension.Summary) -> json.Json {
  json.object([
    #("name", json.string(summary.name)),
    #("description", json.string(summary.description)),
    #("enabled", json.bool(summary.enabled)),
    #("overridden", json.bool(summary.overridden)),
    #("global_enabled", json.bool(summary.global_enabled)),
    #("context", json.bool(summary.context)),
    #("tools", json.array(summary.tools, json.string)),
    #("python_modules", json.array(summary.python_modules, json.string)),
    #("requires", json.array(summary.requires, json.string)),
    #("plugins", json.array(summary.plugins, json.string)),
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

type SubmittedImage {
  SubmittedImage(
    mime_type: String,
    data: String,
    width: Int,
    height: Int,
    bytes: Int,
  )
}

fn submitted_image_decoder() -> decode.Decoder(SubmittedImage) {
  use mime_type <- decode.field("mimeType", decode.string)
  use data <- decode.field("data", decode.string)
  use width <- decode.field("width", decode.int)
  use height <- decode.field("height", decode.int)
  use bytes <- decode.field("bytes", decode.int)
  decode.success(SubmittedImage(mime_type, data, width, height, bytes))
}

fn validate_submitted_image(
  submitted: Option(SubmittedImage),
) -> Result(Option(types.Image), String) {
  case submitted {
    None -> Ok(None)
    Some(SubmittedImage(mime_type, data, width, height, bytes)) ->
      image.validate(mime_type, data, width, height, bytes)
      |> result.map(Some)
  }
}

fn body(req, decoder) {
  mist.read_body(req, 9_200_000)
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
            json.object([
              #("ok", json.bool(True)),
              #("version", json.int(2)),
              #(
                "capabilities",
                json.array(
                  [
                    "session_provider",
                    "session_workspace",
                    "session_extensions",
                    "global_extensions",
                    "session_tree",
                    "session_context",
                    "session_commands",
                  ],
                  json.string,
                ),
              ),
            ]),
          )
        Get, ["sessions"] ->
          reply(200, json.array(actor.call(registry, 5000, List), info_json))
        Get, ["models", provider] -> {
          let endpoint =
            request.get_query(req)
            |> result.unwrap([])
            |> list.key_find("endpoint")
            |> result.unwrap("")
          reply(
            200,
            json.array(
              actor.call(registry, 5000, Models(provider, endpoint, _)),
              json.string,
            ),
          )
        }
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
        Get, ["sessions", id, "tree"] -> {
          let query = request.get_query(req) |> result.unwrap([])
          let after =
            query
            |> list.key_find("after")
            |> result.try(int.parse)
            |> result.unwrap(0)
          let limit =
            query
            |> list.key_find("limit")
            |> result.try(int.parse)
            |> result.unwrap(50)
          case actor.call(registry, 10_000, ReadTree(id, after, limit, _)) {
            Ok(page) -> reply(200, tree_page_json(page))
            Error(e) -> error(400, e)
          }
        }
        Get, ["sessions", id, "context", section, page] ->
          case
            int.parse(page)
            |> result.replace_error("invalid context page")
            |> result.try(fn(page) {
              actor.call(registry, 5000, Lookup(id, _))
              |> result.try(session.context_page(_, section, page))
            })
          {
            Ok(content) -> reply(200, content)
            Error(e) -> error(404, e)
          }
        Post, ["sessions", id, "fork"] -> {
          let decoder = decode.field("checkpoint", decode.int, decode.success)
          case
            body(req, decoder)
            |> result.try(fn(checkpoint) {
              actor.call(registry, 15_000, Fork(id, checkpoint, _))
            })
          {
            Ok(info) -> reply(201, info_json(info))
            Error(e) -> error(409, e)
          }
        }
        _, ["sessions", id, operation] ->
          case actor.call(registry, 5000, Lookup(id, _)) {
            Error(e) -> error(404, e)
            Ok(worker) ->
              case req.method, operation {
                Get, "context" -> reply(200, session.context(worker))
                Get, "commands" ->
                  case session.commands(worker) {
                    Ok(#(commands, _)) ->
                      reply(200, command.catalog_json(commands))
                    Error(e) -> error(409, e)
                  }
                Get, "extensions" ->
                  case session.extensions(worker) {
                    Ok(summaries) ->
                      reply(200, json.array(summaries, extension_json))
                    Error(e) -> error(409, e)
                  }
                Post, "extensions" -> {
                  // `scope` "global" changes the default every session
                  // without its own choice follows; "inherit" drops this
                  // session's choice. Omitted, it is a session choice.
                  let decoder = {
                    use name <- decode.field("name", decode.string)
                    use scope <- decode.optional_field(
                      "scope",
                      "session",
                      decode.string,
                    )
                    use enabled <- decode.optional_field(
                      "enabled",
                      None,
                      decode.optional(decode.bool),
                    )
                    case scope, enabled {
                      "session", Some(value) ->
                        decode.success(extension.SetSession(name, value))
                      "global", Some(value) ->
                        decode.success(extension.SetGlobal(name, value))
                      "inherit", _ -> decode.success(extension.Inherit(name))
                      _, _ ->
                        decode.failure(
                          extension.Inherit(name),
                          "scope session or global with enabled, or inherit",
                        )
                    }
                  }
                  case
                    body(req, decoder)
                    |> result.try(session.set_extension(worker, _))
                  {
                    Ok(summaries) ->
                      reply(200, json.array(summaries, extension_json))
                    Error(e) -> error(409, e)
                  }
                }
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
                    use submitted_image <- decode.optional_field(
                      "image",
                      None,
                      decode.optional(submitted_image_decoder()),
                    )
                    decode.success(#(text, client_id, submitted_image))
                  }
                  case
                    body(req, decoder)
                    |> result.map_error(session.Rejected)
                    |> result.try(fn(submission) {
                      use image <- result.try(
                        validate_submitted_image(submission.2)
                        |> result.map_error(session.Rejected),
                      )
                      session.submit(worker, submission.0, submission.1, image)
                    })
                  {
                    Ok(queued) ->
                      reply(
                        202,
                        json.object([
                          #("ok", json.bool(True)),
                          #("queued", json.bool(queued)),
                        ]),
                      )
                    Error(session.Rejected(e)) -> error(409, e)
                    Error(session.Busy) ->
                      error(409, "session is busy or message queue is full")
                    Error(session.WorkspaceMissing(path)) ->
                      reply(
                        409,
                        json.object([
                          #("code", json.string("workspace_missing")),
                          #("workspace", json.string(path)),
                          #(
                            "error",
                            json.string("workspace not found: " <> path),
                          ),
                        ]),
                      )
                  }
                }
                Post, "workspace" -> {
                  case
                    body(
                      req,
                      decode.field("workspace", decode.string, decode.success),
                    )
                    |> result.try(fn(cwd) {
                      actor.call(registry, 20_000, SetWorkspace(id, cwd, _))
                    })
                  {
                    Ok(info) -> reply(200, info_json(info))
                    Error(e) -> error(409, e)
                  }
                }
                Post, "commands" -> {
                  case
                    body(req, decode.dynamic)
                    |> result.try(fn(fields) {
                      use #(name, supplied, raw, client) <- result.try(
                        command.decode_run(
                          ["name", "args", "arguments", "clientId"],
                          fields,
                        ),
                      )
                      use #(commands, context) <- result.try(session.commands(
                        worker,
                      ))
                      command.call(
                        commands,
                        context,
                        command.UserCall,
                        client,
                        name,
                        supplied,
                        raw,
                      )
                    })
                  {
                    Ok(command.Data(value)) ->
                      reply(200, json.object([#("result", value)]))
                    Ok(command.Turn(_, _)) ->
                      reply(202, json.object([#("submitted", json.bool(True))]))
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

fn when_running(
  worker: session.Session,
  continue_: fn() -> actor.Next(state, message),
) -> actor.Next(state, message) {
  case process.subject_owner(worker) {
    Ok(pid) ->
      case process.is_alive(pid) {
        True -> continue_()
        False -> actor.stop()
      }
    Error(_) -> actor.stop()
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
      // The session wakes this stream per event; the tick is only a keepalive
      // and the way a dropped connection is noticed while nothing is streaming.
      case process.subject_owner(self) {
        Ok(owner) ->
          session.watch(worker, owner, fn() { process.send(self, Wake) })
        Error(_) -> Nil
      }
      process.send(self, Tick)
      #(self, after)
    },
    fn(state, message, connection) {
      // A closing daemon stops session workers while clients are still attached,
      // so a dead worker ends this stream instead of failing a call into it.
      use <- when_running(worker)
      let page = session.read(worker, state.1)
      case message, page.events {
        Wake, [] -> actor.continue(state)
        _, _ -> {
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
              case message {
                Tick -> {
                  let _ = process.send_after(state.0, 1000, Tick)
                  Nil
                }
                Wake -> Nil
              }
              actor.continue(#(state.0, page.cursor))
            }
          }
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
  let assert Ok(_) = claim_home(home)
    as "another albedo daemon is already running for this ALBEDO_HOME"
  let assert Ok(port) = start(config, 0)
  let assert Ok(_) = ready(home, port, token)
  inspect(home)
  watch_parent(env("ALBEDO_PARENT_PID"))
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

/// Takes an exclusive SQLite lock on `home` for the life of the calling
/// process. Startup resumes saved sessions, so a second daemon on the same home
/// would run every in-flight turn twice. The OS drops the lock when the process
/// exits, so a crashed daemon never leaves it stale.
pub fn claim_home(home: String) -> Result(Nil, Nil) {
  use connection <- result.try(
    sqlight.open(home <> "/daemon.lock") |> result.replace_error(Nil),
  )
  case
    // The transaction is never committed: holding it open keeps the exclusive
    // lock, and a refused BEGIN leaves no lock behind on its connection.
    sqlight.exec("BEGIN EXCLUSIVE;", connection)
  {
    Ok(_) -> Ok(hold(connection))
    Error(_) -> {
      let _ = sqlight.close(connection)
      Error(Nil)
    }
  }
}

@external(erlang, "albedo_daemon", "hold")
fn hold(connection: sqlight.Connection) -> Nil

@external(erlang, "albedo_daemon", "ready")
fn ready(home: String, port: Int, token: String) -> Result(Nil, String)

@external(erlang, "albedo_daemon", "directory")
fn directory(path: String) -> Bool

@external(erlang, "albedo_daemon", "shutdown")
fn shutdown() -> Nil

@external(erlang, "albedo_inspect", "start")
fn inspect(home: String) -> Nil

@external(erlang, "albedo_daemon", "watch_parent")
fn watch_parent(pid: String) -> Nil

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
