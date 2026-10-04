//// Session HTTP operations preserve admission decisions and session-owned execution.

import albedo/daemon/bus
import albedo/daemon/context_snapshot
import albedo/daemon/conversation
import albedo/daemon/family
import albedo/daemon/http_api
import albedo/daemon/http_catalog
import albedo/daemon/http_configuration
import albedo/daemon/http_session_resource
import albedo/daemon/http_session_stream
import albedo/daemon/http_wire
import albedo/daemon/image
import albedo/daemon/operations
import albedo/daemon/registry.{
  type Config, type Message, CreateIdentified, Existing, Host, Lookup,
  SessionDeleted,
}
import albedo/daemon/requests
import albedo/daemon/session
import albedo/daemon/session_catalog
import albedo/daemon/session_configuration
import albedo/daemon/session_deletion
import albedo/daemon/session_workspace
import albedo/daemon/store
import albedo/daemon/turn
import albedo/daemon/usage
import albedo/harness/cache_ttl
import albedo/harness/command
import albedo/harness/runtime
import albedo/openai_api/types
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import mist

fn creation_failure(
  ledger: store.Store,
  id: String,
  failure: http_api.Failure,
  receipt: Option(operations.Receipt),
) -> Result(response.Response(mist.ResponseData), http_api.Failure) {
  use record <- result.try(
    conversation.creation(ledger, id) |> result.map_error(http_api.failure),
  )
  use creation <- result.try(case record {
    None -> Ok(json.null())
    Some(record) -> http_session_resource.creation(record)
  })
  let status =
    option.map(receipt, fn(receipt) { receipt.http_status })
    |> option.unwrap(201)
  let admission =
    option.map(receipt, fn(receipt) { receipt.status })
    |> option.unwrap("accepted")
  let decision =
    json.object([
      #("kind", json.string("creation")),
      #("session_id", json.string(id)),
      #("admission", json.string(admission)),
      #("http_status", json.int(status)),
      #("creation", creation),
      #(
        "decided_at",
        json.nullable(
          case receipt {
            Some(receipt) -> Some(receipt.created_at)
            None -> option.then(record, fn(record) { record.decided_at })
          },
          http_wire.timestamp,
        ),
      ),
      #(
        "deleted_at",
        json.nullable(
          option.then(record, fn(record) { record.deleted_at }),
          http_wire.timestamp,
        ),
      ),
    ])
  use fields <- result.try(http_api.fields(
    http_api.problem(failure) |> json.to_string,
  ))
  Ok(
    http_api.reply(
      failure.status,
      json.object([#("decision", decision), ..fields]),
    )
    |> response.set_header("content-type", "application/problem+json"),
  )
}

pub fn create(
  config: Config,
  registry: Subject(Message),
  id: String,
  req: request.Request(BitArray),
) -> response.Response(mist.ResponseData) {
  let outcome = {
    use _ <- result.try(http_api.json_parameters(req, []))
    use _ <- result.try(http_api.require_creation(req))
    use submitted <- result.try(http_api.creation(req))
    use host <- result.try(
      actor.call(registry, 5000, Host) |> result.map_error(http_api.failure),
    )
    let ledger = runtime.ledger(host)
    case actor.call(registry, 15_000, CreateIdentified(id, submitted, _)) {
      Error("session_exists") ->
        creation_failure(ledger, id, http_api.failure("session_exists"), None)
      Error("session_deleted") ->
        creation_failure(ledger, id, http_api.failure("session_deleted"), None)
      Error(reason) -> Error(http_api.failure(reason))
      Ok(receipt) if receipt.status != "accepted" ->
        creation_failure(ledger, id, rejection_failure(receipt), Some(receipt))
      Ok(_) -> {
        use worker <- result.try(
          actor.call(registry, 5000, Lookup(id, _))
          |> result.map_error(http_api.failure),
        )
        use captured <- result.try(
          session.capture(worker) |> result.map_error(http_api.failure),
        )
        use value <- result.try(http_session_resource.encode(
          config.token,
          runtime.ledger(host),
          captured,
          100,
        ))
        bus.invalidate(["/sessions", "/sessions/" <> id], [id], True)
        Ok(
          http_api.reply(201, value)
          |> response.set_header("location", "/sessions/" <> id),
        )
      }
    }
  }
  http_api.answer(outcome)
}

fn missing_session_decision(
  ledger: store.Store,
  id: String,
) -> Result(response.Response(mist.ResponseData), http_api.Failure) {
  use creation <- result.try(
    conversation.creation(ledger, id) |> result.map_error(http_api.failure),
  )
  case creation {
    Some(record) if record.deleted_at != None ->
      creation_failure(ledger, id, http_api.failure("session_deleted"), None)
    _ -> {
      use receipt <- result.try(
        operations.lookup(ledger, id) |> result.map_error(http_api.failure),
      )
      case receipt {
        Some(receipt)
          if receipt.operation.kind == "create"
          && receipt.operation.target == id
          && receipt.status != "accepted"
        ->
          creation_failure(
            ledger,
            id,
            rejection_failure(receipt),
            Some(receipt),
          )
        _ -> Error(http_api.failure("session not found"))
      }
    }
  }
}

pub fn read(
  config: Config,
  registry: Subject(Message),
  id: String,
  req: request.Request(BitArray),
  live: request.Request(mist.Connection),
) -> response.Response(mist.ResponseData) {
  let outcome = {
    use parameters <- result.try(
      http_api.parameters(req, ["view", "tail", "after_generation", "after_seq"]),
    )
    use watching <- result.try(http_api.wants_events(req))
    use host <- result.try(
      actor.call(registry, 5000, Host) |> result.map_error(http_api.failure),
    )
    case list.key_find(parameters, "view") {
      Ok("configuration") -> {
        use _ <- result.try(case watching || list.length(parameters) != 1 {
          True ->
            Error(http_api.invalid(
              "configuration view accepts JSON without tail or replay parameters",
            ))
          False -> Ok(Nil)
        })
        case conversation.capture(runtime.ledger(host), id) {
          Error("session not found") ->
            missing_session_decision(runtime.ledger(host), id)
          Error(reason) -> Error(http_api.failure(reason))
          Ok(captured) ->
            Ok(
              http_api.reply(
                200,
                http_configuration.encode(captured.configuration),
              )
              |> response.set_header(
                "etag",
                http_configuration.etag(captured.configuration),
              ),
            )
        }
      }
      Ok(_) -> Error(http_api.invalid("unknown session view"))
      Error(_) -> {
        use tail <- result.try(http_api.integer_parameter(
          parameters,
          "tail",
          100,
          200,
        ))
        use after <- result.try(http_session_stream.cursor(parameters, watching))
        case actor.call(registry, 5000, Lookup(id, _)) {
          Error("session not found") ->
            missing_session_decision(runtime.ledger(host), id)
          Error(reason) -> Error(http_api.failure(reason))
          Ok(worker) ->
            case watching {
              True ->
                http_session_stream.attach(
                  config.token,
                  runtime.ledger(host),
                  worker,
                  tail,
                  after,
                  live,
                )
              False -> {
                use captured <- result.try(
                  session.capture(worker) |> result.map_error(http_api.failure),
                )
                use value <- result.try(http_session_resource.encode(
                  config.token,
                  runtime.ledger(host),
                  captured,
                  tail,
                ))
                Ok(http_api.reply(200, value))
              }
            }
        }
      }
    }
  }
  http_api.answer(outcome)
}

pub fn catalog(
  config: Config,
  registry: Subject(Message),
  id: String,
  req: request.Request(BitArray),
) -> response.Response(mist.ResponseData) {
  let outcome = {
    use parameters <- result.try(
      http_api.json_parameters(req, ["kind", "limit", "next"]),
    )
    use limit <- result.try(http_api.limit_parameter(parameters, 50))
    let kind = list.key_find(parameters, "kind") |> result.unwrap("")
    use _ <- result.try(
      case
        list.contains(
          ["", "extensions", "skills", "instructions", "mcp", "commands"],
          kind,
        )
      {
        True -> Ok(Nil)
        False -> Error(http_api.invalid("unknown catalog kind"))
      },
    )
    use host <- result.try(
      actor.call(registry, 5000, Host) |> result.map_error(http_api.failure),
    )
    use observed <- result.try(
      runtime.observe_catalog(host, config.home, id)
      |> result.map_error(http_api.failure),
    )
    let candidates =
      result.map(observed.discovery, fn(discovery) { discovery.candidates })
      |> result.unwrap([])
      |> list.filter(fn(candidate) {
        case kind {
          "" -> True
          "extensions" -> candidate.kind == "extension"
          "skills" -> candidate.kind == "skill"
          "instructions" -> candidate.kind == "instruction"
          "mcp" -> candidate.kind == "mcp"
          _ -> False
        }
      })
    let commands = case kind {
      "" | "commands" -> http_catalog.commands(observed)
      _ -> []
    }
    use native_commands <- result.try(
      case observed.loaded_revision, observed.discovery {
        None, Ok(discovery) if kind == "" || kind == "commands" -> {
          let commands =
            http_catalog.native_commands(runtime.installed(host), discovery)
          use shown <- result.try(http_api.bounded_catalog(commands, 262_144))
          case
            list.length(commands) <= 200
            && list.length(shown) == list.length(commands)
          {
            True -> Ok(Some(shown))
            False ->
              Error(http_api.Failure(
                503,
                "catalog_item_unavailable",
                "native command declarations exceed the catalog size limit",
              ))
          }
        }
        _, _ -> Ok(None)
      },
    )
    let binding = http_api.page_binding(req, parameters)
    use cursor <- result.try(case list.key_find(parameters, "next") {
      Error(_) -> Ok(#("", 0))
      Ok(token) -> {
        use state <- result.try(
          http_api.page_state(config.token, binding, token)
          |> result.map_error(fn(_) {
            http_api.invalid(
              "catalog continuation does not belong to this query",
            )
          }),
        )
        use cursor <- result.try(
          json.parse(state, {
            use section <- decode.field("section", decode.string)
            use offset <- decode.field("offset", decode.int)
            use revision <- decode.field("revision", decode.string)
            decode.success(#(section, offset, revision))
          })
          |> result.map_error(fn(_) {
            http_api.invalid("invalid catalog continuation")
          }),
        )
        let revision = case cursor.0 {
          "discovery" ->
            result.map(observed.discovery, fn(discovery) { discovery.revision })
            |> result.unwrap("")
          "loaded" -> option.unwrap(observed.loaded_revision, "unloaded")
          _ -> ""
        }
        use _ <- result.try(
          case cursor.1 >= 0 && revision != "" && cursor.2 == revision {
            True -> Ok(Nil)
            False ->
              Error(http_api.Failure(
                409,
                "catalog_changed",
                "catalog continuation belongs to an earlier observation",
              ))
          },
        )
        Ok(#(cursor.0, cursor.1))
      }
    })
    let offset = fn(section) {
      case cursor.0 == section {
        True -> cursor.1
        False -> 0
      }
    }
    use shown_candidates <- result.try(http_api.bounded_catalog(
      list.drop(candidates, offset("discovery"))
        |> list.take(limit)
        |> list.map(http_catalog.encode),
      262_144,
    ))
    use shown_commands <- result.try(http_api.bounded_catalog(
      list.drop(commands, offset("loaded")) |> list.take(limit),
      262_144,
    ))
    let next = fn(section, position, total, revision) {
      case position < total {
        False -> json.null()
        True ->
          json.string(http_api.page_token(
            config.token,
            binding,
            json.to_string(
              json.object([
                #("section", json.string(section)),
                #("offset", json.int(position)),
                #("revision", json.string(revision)),
              ]),
            ),
          ))
      }
    }
    Ok(http_api.reply(
      200,
      json.object(
        list.append(
          [
            #("discovery", case observed.discovery {
              Error(_) -> json.null()
              Ok(discovery) ->
                json.object([
                  #("revision", json.string(discovery.revision)),
                  #("workspace", json.string(discovery.workspace)),
                  #(
                    "candidates",
                    json.array(shown_candidates, fn(value) { value }),
                  ),
                  #(
                    "diagnostics",
                    json.array(
                      list.take(discovery.diagnostics, 200),
                      fn(detail) {
                        http_api.reason(
                          "discovery_diagnostic",
                          http_api.scalar_prefix(detail, 256),
                        )
                      },
                    ),
                  ),
                  #(
                    "next",
                    next(
                      "discovery",
                      offset("discovery") + list.length(shown_candidates),
                      list.length(candidates),
                      discovery.revision,
                    ),
                  ),
                ])
            }),
            #("discovery_failure", case observed.discovery {
              Ok(_) -> json.null()
              Error(reason) -> http_api.reason("discovery_unavailable", reason)
            }),
            #(
              "loaded",
              json.object([
                #(
                  "revision",
                  json.nullable(observed.loaded_revision, json.string),
                ),
                #("commands", json.array(shown_commands, fn(value) { value })),
                #(
                  "next",
                  next(
                    "loaded",
                    offset("loaded") + list.length(shown_commands),
                    list.length(commands),
                    option.unwrap(observed.loaded_revision, "unloaded"),
                  ),
                ),
              ]),
            ),
          ],
          case native_commands {
            None -> []
            Some(commands) -> [
              #("native_commands", json.array(commands, fn(value) { value })),
            ]
          },
        ),
      ),
    ))
  }
  http_api.answer(outcome)
}

pub fn input(
  config: Config,
  registry: Subject(Message),
  id: String,
  input_id: String,
  req: request.Request(BitArray),
) -> response.Response(mist.ResponseData) {
  let outcome = {
    use _ <- result.try(http_api.json_parameters(req, []))
    use input <- result.try(http_api.input(req))
    let #(kind, client) = case input {
      http_api.MessageInput(_, _, client) -> #("message", client)
      http_api.ContinueInput(client) -> #("continue", client)
      http_api.SkillInput(_, _, _, client) -> #("skill", client)
      http_api.CommandInput(_, _, client) -> #("command", client)
    }
    let request =
      operations.Request(
        input_id,
        http_api.etag(http_api.input_intent(input) |> json.to_string),
        kind,
        id,
        client,
      )
    use host <- result.try(
      actor.call(registry, 5000, Host) |> result.map_error(http_api.failure),
    )
    let ledger = runtime.ledger(host)
    use prior <- result.try(
      operations.check(ledger, request)
      |> result.map_error(fn(reason) {
        case reason {
          "operation_conflict" -> http_api.failure("input_conflict")
          _ -> http_api.failure(reason)
        }
      }),
    )
    use _ <- result.try(case prior {
      Some(_) -> Ok(Nil)
      None -> {
        let prepared = {
          use worker <- result.try(actor.call(registry, 5000, Lookup(id, _)))
          use prepared <- result.try(prepare_input(
            config,
            host,
            worker,
            input,
            input_id,
          ))
          session.admit_durable(worker, request, prepared)
        }
        case prepared {
          Ok(_) -> Ok(Nil)
          Error(reason) -> {
            let failure = http_api.failure(reason)
            case failure.status >= 500 {
              True -> Error(failure)
              False ->
                operations.reject(
                  ledger,
                  request,
                  operations.Rejection(
                    failure.status,
                    failure.code,
                    failure.detail,
                  ),
                )
                |> result.replace(Nil)
                |> result.map_error(http_api.failure)
            }
          }
        }
      }
    })
    use result <- result.try(input_outcome(ledger, id, input_id))
    Ok(input_decision_response(result))
  }
  http_api.answer(outcome)
}

fn prepare_input(
  config: Config,
  host: runtime.Runtime,
  worker: session.Session,
  input: http_api.Input,
  input_id: String,
) -> Result(turn.Submission, String) {
  let client = case input {
    http_api.MessageInput(_, _, client)
    | http_api.ContinueInput(client)
    | http_api.SkillInput(_, _, _, client)
    | http_api.CommandInput(_, _, client) -> option.unwrap(client, "")
  }
  case input {
    http_api.MessageInput(text, uploaded, _) -> {
      use image <- result.try(case uploaded {
        None -> Ok(None)
        Some(uploaded) -> {
          use inspected <- result.try(
            image.from_base64(uploaded.data)
            |> result.replace_error("image_invalid"),
          )
          case types.image_meta(inspected).0 == uploaded.mime_type {
            True -> Ok(Some(inspected))
            False -> Error("image_invalid")
          }
        }
      })
      use _ <- result.try(case string.trim(text) != "" || image != None {
        True -> Ok(Nil)
        False -> Error("message is empty")
      })
      Ok(turn.Submission(
        text,
        text,
        client,
        turn.Chat,
        image,
        Some(input_id),
        Some(input_id),
      ))
    }
    http_api.ContinueInput(_) -> Ok(session.continuation(client, input_id))
    http_api.SkillInput(candidate_id, revision, arguments, _) -> {
      use capture <- result.try(session.capture(worker))
      use snapshot <- result.try(session_catalog.inspect(
        config.home,
        runtime.inventory(host),
        capture.info.id,
      ))
      use _ <- result.try(case snapshot.revision == revision {
        True -> Ok(Nil)
        False -> Error("catalog_changed")
      })
      use selected <- result.try(
        list.find(snapshot.candidates, fn(candidate) {
          candidate.id == candidate_id
          && candidate.kind == "skill"
          && candidate.valid
          && candidate.eligible
          && candidate.shadowed_by == None
        })
        |> result.replace_error("skill is not eligible"),
      )
      use name <- result.try(option.to_result(
        selected.preference_key,
        "skill has no identity",
      ))
      use #(commands, _) <- result.try(session.commands(worker))
      use command <- result.try(
        list.find(commands, fn(command) { command.name == "/" <> name })
        |> result.replace_error("skill is not loaded"),
      )
      use prepare <- result.try(option.to_result(
        command.skill_activation,
        "skill is not a turn input",
      ))
      use #(display, text) <- result.try(prepare(arguments))
      Ok(turn.Submission(
        display,
        text,
        client,
        turn.Chat,
        None,
        Some(input_id),
        Some(input_id),
      ))
    }
    http_api.CommandInput(command_id, supplied, _) -> {
      use #(commands, context) <- result.try(session.commands(worker))
      use selected <- result.try(
        list.find(commands, fn(command) { command.name == command_id })
        |> result.replace_error("unknown input command"),
      )
      use arguments <- result.try(
        decode.run(supplied, decode.dict(decode.string, decode.string))
        |> result.replace_error("command arguments must be declared strings"),
      )
      use #(display, text) <- result.try(command.prepare_input(
        selected,
        context,
        arguments,
      ))
      Ok(turn.Submission(
        display,
        text,
        client,
        turn.Chat,
        None,
        Some(input_id),
        Some(input_id),
      ))
    }
  }
}

fn input_outcome(
  ledger: store.Store,
  session_id: String,
  id: String,
) -> Result(operations.InputOutcome, http_api.Failure) {
  use known <- result.try(
    operations.input_outcome(ledger, id) |> result.map_error(http_api.failure),
  )
  case known {
    Some(outcome)
      if outcome.receipt.operation.target == session_id
      && outcome.receipt.operation.kind != "create"
    -> Ok(outcome)
    Some(_) ->
      Error(http_api.Failure(
        409,
        "input_conflict",
        "identity belongs to another resource",
      ))
    None -> {
      use _ <- result.try(
        operations.validate_id(id, usage.now())
        |> result.map_error(http_api.failure),
      )
      Error(http_api.Failure(
        404,
        "input_unknown",
        "input decision is not known",
      ))
    }
  }
}

fn input_decision_response(
  outcome: operations.InputOutcome,
) -> response.Response(mist.ResponseData) {
  case outcome.receipt.status {
    "accepted" ->
      http_api.reply(outcome.receipt.http_status, http_wire.input(outcome))
    _ -> {
      let fields =
        http_api.problem(rejection_failure(outcome.receipt))
        |> json.to_string
        |> http_api.fields
        |> result.unwrap([])
      http_api.reply(
        outcome.receipt.http_status,
        json.object([
          #(
            "decision",
            json.object([
              #("kind", json.string("input")),
              #("input", http_wire.input(outcome)),
            ]),
          ),
          ..fields
        ]),
      )
      |> response.set_header("content-type", "application/problem+json")
    }
  }
}

fn rejection_failure(receipt: operations.Receipt) -> http_api.Failure {
  case receipt.rejection {
    Some(reason) -> http_api.Failure(reason.status, reason.code, reason.detail)
    None ->
      http_api.Failure(
        receipt.http_status,
        "rejection_unavailable",
        "the retained decision has no recorded rejection detail",
      )
  }
}

pub fn input_read(
  registry: Subject(Message),
  id: String,
  input_id: String,
  req: request.Request(BitArray),
) -> response.Response(mist.ResponseData) {
  let outcome = {
    use _ <- result.try(http_api.json_parameters(req, []))
    use host <- result.try(
      actor.call(registry, 5000, Host) |> result.map_error(http_api.failure),
    )
    use input <- result.try(input_outcome(runtime.ledger(host), id, input_id))
    Ok(http_api.reply(200, http_wire.input(input)))
  }
  http_api.answer(outcome)
}

pub fn visit(
  _config: Config,
  registry: Subject(Message),
  id: String,
  visit_id: String,
  req: request.Request(BitArray),
) -> response.Response(mist.ResponseData) {
  let outcome = {
    use _ <- result.try(http_api.json_parameters(req, []))
    use _ <- result.try(http_api.empty_body(req))
    use host <- result.try(
      actor.call(registry, 5000, Host) |> result.map_error(http_api.failure),
    )
    use visit <- result.try(
      session_configuration.visit(runtime.ledger(host), id, visit_id)
      |> result.map_error(http_api.failure),
    )
    case visit.1 {
      True -> bus.invalidate(["/sessions", "/sessions/" <> id], [id], True)
      False -> Nil
    }
    Ok(http_api.reply(
      200,
      json.object([
        #("visit_id", json.string(visit.0.visit_id)),
        #("session_id", json.string(visit.0.session_id)),
        #("opens", json.int(visit.0.opens)),
      ]),
    ))
  }
  http_api.answer(outcome)
}

pub fn cancel(
  registry: Subject(Message),
  id: String,
  input_id: String,
  req: request.Request(BitArray),
) -> response.Response(mist.ResponseData) {
  let outcome = {
    use _ <- result.try(http_api.json_parameters(req, []))
    use _ <- result.try(http_api.empty_body(req))
    use host <- result.try(
      actor.call(registry, 5000, Host) |> result.map_error(http_api.failure),
    )
    use known <- result.try(input_outcome(runtime.ledger(host), id, input_id))
    let terminal =
      known.receipt.status == "rejected"
      || known.receipt.delivery == Some("cancelled")
      || case known.turn {
        Some(turn) -> turn.ended_at != None
        None -> False
      }
    use cancelled <- result.try(case terminal {
      True -> Ok(session.NotPending)
      False -> {
        use worker <- result.try(
          actor.call(registry, 5000, Lookup(id, _))
          |> result.map_error(http_api.failure),
        )
        session.cancel_input(worker, input_id)
        |> result.map_error(http_api.failure)
      }
    })
    let result = case cancelled {
      session.Cancelled -> "cancelled"
      session.InterruptRequested -> "interrupt_requested"
      session.SharedRunning -> "shared_running"
      session.NotPending -> "not_pending"
    }
    use input <- result.try(input_outcome(runtime.ledger(host), id, input_id))
    Ok(http_api.reply(
      200,
      json.object([
        #("result", json.string(result)),
        #("input", http_wire.input(input)),
      ]),
    ))
  }
  http_api.answer(outcome)
}

pub fn interrupt(
  registry: Subject(Message),
  id: String,
  req: request.Request(BitArray),
) -> response.Response(mist.ResponseData) {
  let outcome = {
    use _ <- result.try(http_api.json_parameters(req, []))
    use captured <- result.try(http_api.interrupt(req))
    use worker <- result.try(
      actor.call(registry, 5000, Lookup(id, _))
      |> result.map_error(http_api.failure),
    )
    use result <- result.try(
      session.interrupt_captured(
        worker,
        captured.run_id,
        captured.through_input_order,
      )
      |> result.map_error(http_api.failure),
    )
    Ok(http_api.reply(
      200,
      json.object([
        #("run_id", json.nullable(result.run_id, json.string)),
        #(
          "state",
          json.string(case result.requested {
            True -> "requested"
            False -> "already_ended"
          }),
        ),
        #(
          "cancelled_input_ids",
          json.array(result.cancelled_input_ids, json.string),
        ),
        #("warnings", json.array([], fn(value) { value })),
      ]),
    ))
  }
  http_api.answer(outcome)
}

pub fn context(
  config: Config,
  registry: Subject(Message),
  id: String,
  req: request.Request(BitArray),
) -> response.Response(mist.ResponseData) {
  let outcome = {
    use parameters <- result.try(
      http_api.json_parameters(req, [
        "view",
        "snapshot_id",
        "section_id",
        "page",
        "after",
        "limit",
        "next",
      ]),
    )
    let view = list.key_find(parameters, "view") |> result.unwrap("summary")
    case view {
      "requests" -> {
        use _ <- result.try(
          case
            list.any(parameters, fn(pair) {
              list.contains(["snapshot_id", "section_id", "page"], pair.0)
            })
          {
            True ->
              Error(http_api.invalid(
                "request view does not accept section parameters",
              ))
            False -> Ok(Nil)
          },
        )
        use _ <- result.try(
          case
            list.key_find(parameters, "after"),
            list.key_find(parameters, "next")
          {
            Ok(_), Ok(_) ->
              Error(http_api.invalid("choose after or next, not both"))
            _, _ -> Ok(Nil)
          },
        )
        use host <- result.try(
          actor.call(registry, 5000, Host) |> result.map_error(http_api.failure),
        )
        use _ <- result.try(
          conversation.get(runtime.ledger(host), id)
          |> result.map_error(http_api.failure),
        )
        use limit <- result.try(http_api.limit_parameter(parameters, 50))
        use after <- result.try(http_api.integer_parameter(
          parameters,
          "after",
          0,
          9_007_199_254_740_991,
        ))
        use after <- result.try(http_api.page_offset(
          config.token,
          req,
          parameters,
          "",
          after,
        ))
        use page <- result.try(
          requests.page(runtime.ledger(host), id, after, limit + 1)
          |> result.map_error(http_api.failure),
        )
        let shown = list.take(page.0, limit)
        let next = case list.length(page.0) > limit, list.last(shown) {
          True, Ok(last) ->
            http_api.continuation(config.token, req, parameters, "", last.id)
          _, _ -> json.null()
        }
        Ok(http_api.reply(
          200,
          json.object([
            #("items", json.array(shown, http_wire.request)),
            #("next", next),
          ]),
        ))
      }
      "summary" | "section" -> {
        use _ <- result.try(
          case
            list.any(parameters, fn(pair) {
              list.contains(["after", "limit", "next"], pair.0)
            })
          {
            True ->
              Error(http_api.invalid(
                "prepared context does not accept request pagination",
              ))
            False -> Ok(Nil)
          },
        )
        use worker <- result.try(
          actor.call(registry, 5000, Lookup(id, _))
          |> result.map_error(http_api.failure),
        )
        let expected =
          list.key_find(parameters, "snapshot_id") |> option.from_result
        use _ <- result.try(
          case
            view,
            expected,
            list.key_find(parameters, "section_id"),
            list.key_find(parameters, "page")
          {
            "section", Some(_), Ok(_), Ok(_) -> Ok(Nil)
            "section", _, _, _ ->
              Error(http_api.invalid(
                "section view requires snapshot_id, section_id and page",
              ))
            "summary", None, Error(_), Error(_) -> Ok(Nil)
            _, _, _, _ ->
              Error(http_api.invalid("section parameters require section view"))
          },
        )
        use snapshot <- result.try(
          session.prepared_context(worker, expected)
          |> result.map_error(fn(reason) {
            case reason {
              "context_changed" ->
                http_api.Failure(
                  410,
                  "context_changed",
                  "prepared context changed; refresh the summary",
                )
              _ -> http_api.failure(reason)
            }
          }),
        )
        case view {
          "section" -> {
            use section <- result.try(
              list.key_find(parameters, "section_id")
              |> result.map_error(fn(_) {
                http_api.invalid("section_id is required")
              }),
            )
            use page <- result.try(http_api.integer_parameter(
              parameters,
              "page",
              0,
              9_007_199_254_740_991,
            ))
            use section <- result.try(
              context_snapshot.page(snapshot, section, page)
              |> result.map_error(fn(reason) {
                http_api.Failure(404, "context_section_unknown", reason)
              }),
            )
            Ok(http_api.reply(200, http_wire.context_page(section)))
          }
          _ -> Ok(http_api.reply(200, http_wire.context(snapshot)))
        }
      }
      _ -> Error(http_api.invalid("unknown context view"))
    }
  }
  http_api.answer(outcome)
}

pub fn patch(
  config: Config,
  registry: Subject(Message),
  id: String,
  req: request.Request(BitArray),
) -> response.Response(mist.ResponseData) {
  let outcome = {
    use parameters <- result.try(http_api.json_parameters(req, ["view"]))
    use _ <- result.try(case parameters {
      [#("view", "configuration")] -> Ok(Nil)
      _ ->
        Error(http_api.invalid(
          "configuration changes require view=configuration",
        ))
    })
    use change <- result.try(http_configuration.change(req))
    use host <- result.try(
      actor.call(registry, 5000, Host) |> result.map_error(http_api.failure),
    )
    use observed <- result.try(
      conversation.capture(runtime.ledger(host), id)
      |> result.map_error(http_api.failure),
    )
    use _ <- result.try(http_api.require_match(
      req,
      http_configuration.etag(observed.configuration),
    ))
    let version =
      session_configuration.Version(
        observed.configuration.revision,
        observed.family.revision,
      )
    use worker <- result.try(
      actor.call(registry, 5000, Lookup(id, _))
      |> result.map_error(http_api.failure),
    )
    use changed <- result.try(case change {
      http_configuration.Edit(patch) ->
        session.change_configuration(worker, version, patch)
        |> result.map(fn(capture) { #(capture, json.null()) })
        |> result.map_error(http_api.failure)
      http_configuration.Move(workspace, revision) -> {
        use _ <- result.try(
          case
            revision
            == http_configuration.family_revision(observed.configuration)
          {
            True -> Ok(Nil)
            False -> Error(http_api.failure("family_changed"))
          },
        )
        use recorded <- result.try(
          session.change_workspace(
            worker,
            session_workspace.Request(id, version, workspace),
          )
          |> result.map_error(fn(failure) {
            case failure {
              session_workspace.Destination(failure) ->
                http_api.workspace_failure(failure)
              session_workspace.Native(reason) -> http_api.failure(reason)
            }
          }),
        )
        use warnings <- result.try(
          apply_move_members(
            registry,
            runtime.ledger(host),
            recorded.move_id,
            None,
            [],
          ),
        )
        use report <- result.try(
          session_workspace.report(runtime.ledger(host), recorded)
          |> result.map_error(http_api.failure),
        )
        let warnings = case report.superseded_count {
          0 -> warnings
          _ -> [
            http_api.reason(
              "workspace_superseded",
              int.to_string(report.superseded_count)
                <> " affected sessions were moved again or deleted",
            ),
            ..warnings
          ]
        }
        use capture <- result.try(
          session.capture(worker) |> result.map_error(http_api.failure),
        )
        Ok(#(
          capture,
          json.object([
            #("applied_count", json.int(report.applied_count)),
            #("deferred_count", json.int(report.deferred_count)),
            #("applied_ids", json.array(report.applied_ids, json.string)),
            #("deferred_ids", json.array(report.deferred_ids, json.string)),
            #("truncated", json.bool(report.truncated)),
            #(
              "warnings",
              json.array(list.take(warnings, 100), fn(value) { value }),
            ),
          ]),
        ))
      }
    })
    use value <- result.try(http_session_resource.encode(
      config.token,
      runtime.ledger(host),
      changed.0,
      100,
    ))
    Ok(
      http_api.reply(
        200,
        json.object([
          #("resource", http_configuration.resource(changed.0.configuration)),
          #("session", value),
          #("move", changed.1),
        ]),
      )
      |> response.set_header(
        "etag",
        http_configuration.etag(changed.0.configuration),
      ),
    )
  }
  http_api.answer(outcome)
}

pub fn delete(
  config: Config,
  registry: Subject(Message),
  id: String,
  req: request.Request(BitArray),
) -> response.Response(mist.ResponseData) {
  let outcome = {
    use parameters <- result.try(
      http_api.json_parameters(req, ["view", "scope", "family_revision"]),
    )
    use _ <- result.try(case list.key_find(parameters, "view") {
      Ok("configuration") -> Ok(Nil)
      _ -> Error(http_api.invalid("deletion requires view=configuration"))
    })
    let scope = list.key_find(parameters, "scope") |> result.unwrap("leaf")
    use _ <- result.try(case scope {
      "leaf" | "subtree" -> Ok(Nil)
      _ -> Error(http_api.invalid("scope must be leaf or subtree"))
    })
    use host <- result.try(
      actor.call(registry, 5000, Host) |> result.map_error(http_api.failure),
    )
    use observed <- result.try(
      conversation.capture(runtime.ledger(host), id)
      |> result.map_error(http_api.failure),
    )
    use _ <- result.try(http_api.require_match(
      req,
      http_configuration.etag(observed.configuration),
    ))
    use _ <- result.try(
      case scope, list.key_find(parameters, "family_revision") {
        "subtree", Error(_) ->
          Error(http_api.invalid("subtree deletion requires family_revision"))
        _, Ok(revision) ->
          case
            revision
            == http_configuration.family_revision(observed.configuration)
          {
            True -> Ok(Nil)
            False -> Error(http_api.failure("family_changed"))
          }
        _, _ -> Ok(Nil)
      },
    )
    use deleted <- result.try(
      session_deletion.execute(
        host,
        config.home,
        family.DeletionRequest(
          id,
          observed.configuration.revision,
          observed.family.revision,
          scope == "subtree",
        ),
        fn(deleted) { process.send(registry, SessionDeleted(deleted)) },
      )
      |> result.map_error(http_api.failure),
    )
    Ok(http_api.reply(
      200,
      json.object([
        #(
          "state",
          json.string(case deleted.remaining_count {
            0 -> "complete"
            _ -> "partial"
          }),
        ),
        #("deleted_count", json.int(deleted.deleted_count)),
        #("remaining_count", json.int(deleted.remaining_count)),
        #("deleted_ids", json.array(deleted.deleted_ids, json.string)),
        #(
          "remaining",
          json.array(deleted.remaining, fn(item) {
            json.object([
              #("id", json.string(item.0)),
              #("reason", http_api.reason("deletion_failed", item.1)),
            ])
          }),
        ),
        #("truncated", json.bool(deleted.truncated)),
      ]),
    ))
  }
  http_api.answer(outcome)
}

pub fn upgrade(
  registry: Subject(Message),
  id: String,
  req: request.Request(BitArray),
) -> response.Response(mist.ResponseData) {
  let outcome = {
    use _ <- result.try(http_api.json_parameters(req, []))
    use _ <- result.try(http_api.body(req, [], decode.success(Nil)))
    use host <- result.try(
      actor.call(registry, 5000, Host) |> result.map_error(http_api.failure),
    )
    use _ <- result.try(
      conversation.get(runtime.ledger(host), id)
      |> result.map_error(http_api.failure),
    )
    use worker <- result.try(
      actor.call(registry, 5000, Lookup(id, _))
      |> result.map_error(http_api.failure),
    )
    use report <- result.try(
      session.upgrade_kernel(worker) |> result.map_error(http_api.failure),
    )
    Ok(http_api.reply(
      200,
      json.object([
        #(
          "old_build",
          json.nullable(
            option.then(report.old, fn(value) { value.build }),
            json.string,
          ),
        ),
        #(
          "new_build",
          json.nullable(
            option.then(report.new, fn(value) { value.build }),
            json.string,
          ),
        ),
        #("state", json.string(report.state)),
        #(
          "old_kernel_id",
          json.nullable(
            option.map(report.old, fn(value) { value.instance_id }),
            json.string,
          ),
        ),
        #(
          "new_kernel_id",
          json.nullable(
            option.map(report.new, fn(value) { value.instance_id }),
            json.string,
          ),
        ),
        #(
          "stopped_jobs",
          json.array(report.stopped_jobs, fn(id) {
            json.object([
              #("id", json.string(id)),
              #(
                "reason",
                http_api.reason(
                  "kernel_upgrade",
                  "the previous kernel was stopped during upgrade",
                ),
              ),
            ])
          }),
        ),
        #(
          "warnings",
          json.array(list.take(report.warnings, 200), http_api.reason(
            "kernel_upgrade_warning",
            _,
          )),
        ),
        #(
          "failure",
          json.nullable(report.failure, http_api.reason(
            "kernel_upgrade_failed",
            _,
          )),
        ),
      ]),
    ))
  }
  http_api.answer(outcome)
}

pub fn compaction(
  registry: Subject(Message),
  id: String,
  req: request.Request(BitArray),
) -> response.Response(mist.ResponseData) {
  let outcome = {
    use _ <- result.try(http_api.json_parameters(req, []))
    use strategy <- result.try(
      http_api.body(req, ["strategy"], {
        decode.optional_field(
          "strategy",
          None,
          decode.map(http_api.bounded_string(256, True), Some),
          decode.success,
        )
      }),
    )
    use host <- result.try(
      actor.call(registry, 5000, Host) |> result.map_error(http_api.failure),
    )
    use _ <- result.try(
      conversation.get(runtime.ledger(host), id)
      |> result.map_error(http_api.failure),
    )
    use worker <- result.try(
      actor.call(registry, 5000, Lookup(id, _))
      |> result.map_error(http_api.failure),
    )
    use compacted <- result.try(
      session.compact_session(worker, strategy)
      |> result.map_error(http_api.failure),
    )
    Ok(http_api.reply(
      200,
      json.object([
        #("selection_applied", json.bool(compacted.selection_applied)),
        #(
          "effective_strategy",
          json.nullable(compacted.effective_strategy, json.string),
        ),
        #("state", json.string(compacted.state)),
        #(
          "observation",
          json.nullable(compacted.observation, fn(value) {
            json.object([
              #(
                "strategy",
                json.nullable(
                  option.map(value.observed, fn(observed) { observed.strategy }),
                  json.string,
                ),
              ),
              #("before_tokens", json.null()),
              #("after_tokens", json.null()),
              #("evicted_entries", json.int(value.evicted)),
              #(
                "summary",
                json.string(http_api.scalar_prefix(value.summary, 32_768)),
              ),
            ])
          }),
        ),
        #(
          "failure",
          json.nullable(compacted.failure, http_api.reason(
            "compaction_failed",
            _,
          )),
        ),
      ]),
    ))
  }
  http_api.answer(outcome)
}

pub fn reload(
  registry: Subject(Message),
  id: String,
  req: request.Request(BitArray),
) -> response.Response(mist.ResponseData) {
  let outcome = {
    use _ <- result.try(http_api.json_parameters(req, []))
    use target <- result.try(http_api.body(
      req,
      ["target"],
      decode.optional_field("target", "both", decode.string, decode.success),
    ))
    use _ <- result.try(
      case list.contains(["session", "models", "both"], target) {
        True -> Ok(Nil)
        False ->
          Error(http_api.invalid(
            "reload target must be session, models or both",
          ))
      },
    )
    use host <- result.try(
      actor.call(registry, 5000, Host) |> result.map_error(http_api.failure),
    )
    use _ <- result.try(
      conversation.get(runtime.ledger(host), id)
      |> result.map_error(http_api.failure),
    )
    use session_result <- result.try(case target {
      "models" -> Ok(json.null())
      _ -> {
        use worker <- result.try(
          actor.call(registry, 5000, Lookup(id, _))
          |> result.map_error(http_api.failure),
        )
        let changed = session.reload(worker)
        use loaded <- result.try(
          runtime.observe_loaded(host, id) |> result.map_error(http_api.failure),
        )
        Ok(
          json.object([
            #(
              "state",
              json.string(case changed {
                Ok(_) -> "applied"
                Error(_) -> "failed"
              }),
            ),
            #(
              "loaded_revision",
              json.nullable(loaded.loaded_revision, json.string),
            ),
            #(
              "restart_required",
              json.bool(
                option.map(loaded.kernel, fn(kernel) { kernel.stale != None })
                |> option.unwrap(False),
              ),
            ),
            #(
              "warnings",
              json.array(
                case changed {
                  Ok(value) -> list.take(value.warnings, 100)
                  Error(_) -> []
                },
                http_api.reason("reload_warning", _),
              ),
            ),
            #("failure", case changed {
              Ok(_) -> json.null()
              Error(reason) -> http_api.reason("session_reload_failed", reason)
            }),
          ]),
        )
      }
    })
    use models <- result.try(case target {
      "session" -> Ok([])
      _ ->
        runtime.reload_catalogs(host, id) |> result.map_error(http_api.failure)
    })
    let cache_policy = case target {
      "session" -> json.null()
      _ -> {
        let reloaded = cache_ttl.reload()
        json.object([
          #(
            "state",
            json.string(case reloaded {
              Ok(_) -> "refreshed"
              Error(_) -> "failed"
            }),
          ),
          #("failure", case reloaded {
            Ok(_) -> json.null()
            Error(reason) ->
              http_api.reason("cache_policy_reload_failed", reason)
          }),
        ])
      }
    }
    Ok(http_api.reply(
      200,
      json.object([
        #("session", session_result),
        #("cache_policy", cache_policy),
        #(
          "models",
          json.array(list.take(models, 200), fn(model) {
            json.object([
              #("provider", json.string(model.0)),
              #(
                "state",
                json.string(case model.1 {
                  Ok(_) -> "refreshed"
                  Error(_) -> "failed"
                }),
              ),
              #("observed_at", case model.1 {
                Ok(_) -> http_wire.timestamp(usage.now())
                Error(_) -> json.null()
              }),
              #("failure", case model.1 {
                Ok(_) -> json.null()
                Error(reason) -> http_api.reason("model_reload_failed", reason)
              }),
            ])
          }),
        ),
      ]),
    ))
  }
  http_api.answer(outcome)
}

fn apply_move_members(
  registry: Subject(Message),
  ledger: store.Store,
  move_id: String,
  after: Option(String),
  warnings: List(json.Json),
) -> Result(List(json.Json), http_api.Failure) {
  use members <- result.try(
    session_workspace.pending_members(ledger, move_id, after, 200)
    |> result.map_error(http_api.failure),
  )
  let warnings =
    list.fold(members, warnings, fn(warnings, id) {
      let applied = {
        use existing <- result.try(actor.call(registry, 5000, Existing(id, _)))
        case existing {
          None -> Ok(False)
          Some(existing) -> session.apply_workspace(existing)
        }
      }
      case applied {
        Error(reason) ->
          list.take(
            [http_api.reason("workspace_deferred", reason), ..warnings],
            100,
          )
        _ -> warnings
      }
    })
  case list.length(members) == 200 {
    False -> Ok(warnings)
    True ->
      apply_move_members(
        registry,
        ledger,
        move_id,
        list.last(members) |> option.from_result,
        warnings,
      )
  }
}
