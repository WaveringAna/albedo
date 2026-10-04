//// Session listing and its bounded invalidation subscription.

import albedo/daemon/bus
import albedo/daemon/http_api
import albedo/daemon/http_stream
import albedo/daemon/http_wire
import albedo/daemon/registry.{type Config, type Message, Existing, Host}
import albedo/daemon/session
import albedo/daemon/session_collection
import albedo/daemon/store
import albedo/daemon/usage
import albedo/harness/runtime
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
import mist

fn collection_filter(
  config: Config,
  host: runtime.Runtime,
  parameters: List(#(String, String)),
) -> Result(session_collection.Filter, http_api.Failure) {
  let value = fn(name) { list.key_find(parameters, name) |> option.from_result }
  let parent = value("parent_id")
  let family = value("family_id")
  let scope =
    option.unwrap(value("scope"), case parent != None || family != None {
      True -> "all"
      False -> "roots"
    })
  let sort = option.unwrap(value("sort"), "activity")
  use _ <- result.try(
    case
      parent != None
      && family != None
      || !list.contains(["roots", "all"], scope)
      || scope == "roots"
      && { parent != None || family != None }
      || !list.contains(["activity", "frequent"], sort)
    {
      True ->
        Error(http_api.invalid(
          "choose roots/all, one parent or family filter, and an activity/frequent sort",
        ))
      False -> Ok(Nil)
    },
  )
  use _ <- result.try(
    list.try_each(parameters, fn(parameter) {
      let maximum = case parameter.0 {
        "search" -> 256
        "workspace" -> 4096
        _ -> 16_384
      }
      case http_api.scalar_prefix(parameter.1, maximum) == parameter.1 {
        True -> Ok(Nil)
        False -> Error(http_api.invalid(parameter.0 <> " is too long"))
      }
    }),
  )
  use archived <- result.try(http_api.boolean_parameter(parameters, "archived"))
  use needs_reload <- result.try(http_api.boolean_parameter(
    parameters,
    "needs_reload",
  ))
  use pending <- result.try(case needs_reload {
    None -> Ok([])
    Some(_) ->
      runtime.needs_reload(host, config.home)
      |> result.map_error(http_api.failure)
  })
  Ok(
    session_collection.Filter(
      scope == "roots",
      parent,
      family,
      value("workspace"),
      value("search"),
      archived,
      sort == "frequent",
      case needs_reload {
        Some(True) -> Some(pending)
        _ -> None
      },
      case needs_reload {
        Some(False) -> pending
        _ -> []
      },
    ),
  )
}

fn collection_key() -> decode.Decoder(session_collection.Key) {
  use opens <- decode.field("opens", decode.int)
  use activity <- decode.field("activity", decode.int)
  use id <- decode.field("id", decode.string)
  decode.success(session_collection.Key(opens, activity, id))
}

pub fn read(
  config: Config,
  registry: Subject(Message),
  req: request.Request(BitArray),
  live: request.Request(mist.Connection),
) -> response.Response(mist.ResponseData) {
  let outcome = {
    use parameters <- result.try(
      http_api.parameters(req, [
        "scope",
        "parent_id",
        "family_id",
        "workspace",
        "search",
        "archived",
        "needs_reload",
        "sort",
        "limit",
        "next",
      ]),
    )
    use watching <- result.try(http_api.wants_events(req))
    use _ <- result.try(
      case
        watching
        && list.any(parameters, fn(parameter) {
          list.contains(["sort", "limit", "next"], parameter.0)
        })
      {
        True ->
          Error(http_api.invalid(
            "collection watch accepts scope filters without sort or pagination",
          ))
        False -> Ok(Nil)
      },
    )
    use host <- result.try(
      actor.call(registry, 5000, Host) |> result.map_error(http_api.failure),
    )
    use filter <- result.try(collection_filter(config, host, parameters))
    case watching {
      True -> {
        use _ <- result.try(
          session_collection.page(runtime.ledger(host), filter, None, 1)
          |> result.map_error(http_api.failure),
        )
        use _ <- result.try(http_stream.configure(live.body))
        Ok(mist.chunked(
          live,
          http_stream.response(live),
          fn(subject) {
            let subscription =
              bus.subscribe_filtered(
                process.self(),
                fn() { process.send(subject, StreamWake) },
                [],
              )
            process.send(subject, StreamWake)
            let _ = process.send_after(subject, 5000, StreamTick)
            CollectionStream(
              config,
              host,
              parameters,
              filter,
              subscription,
              subject,
              True,
            )
          },
          collection_stream_loop,
        ))
      }
      False -> {
        use limit <- result.try(http_api.limit_parameter(parameters, 50))
        let binding = http_api.page_binding(req, parameters)
        use cursor <- result.try(case list.key_find(parameters, "next") {
          Error(_) -> Ok(None)
          Ok(token) -> {
            use state <- result.try(
              http_api.page_state(config.token, binding, token)
              |> result.map_error(fn(_) {
                http_api.invalid(
                  "session continuation does not belong to this query",
                )
              }),
            )
            json.parse(state, collection_key())
            |> result.map(Some)
            |> result.map_error(fn(_) {
              http_api.invalid("invalid session continuation")
            })
          }
        })
        use page <- result.try(
          session_collection.page(runtime.ledger(host), filter, cursor, limit)
          |> result.map_error(http_api.failure),
        )
        use items <- result.try(
          list.try_map(page.items, fn(durable) {
            use live <- result.try(
              actor.call(registry, 5000, Existing(durable.info.id, _))
              |> result.map_error(http_api.failure),
            )
            use live <- result.try(case live {
              None -> Ok(None)
              Some(worker) ->
                session.summary(worker)
                |> result.map(Some)
                |> result.map_error(http_api.failure)
            })
            Ok(http_wire.summary(durable, live, usage.now()))
          }),
        )
        let next =
          json.nullable(page.next, fn(key) {
            json.string(http_api.page_token(
              config.token,
              binding,
              json.to_string(
                json.object([
                  #("opens", json.int(key.opens)),
                  #("activity", json.int(key.activity)),
                  #("id", json.string(key.id)),
                ]),
              ),
            ))
          })
        let family = case page.family {
          None -> []
          Some(family) -> [
            #(
              "family",
              json.object([
                #("root_id", json.string(family.root_id)),
                #(
                  "revision",
                  json.string(
                    "family-"
                    <> family.root_id
                    <> "-"
                    <> int.to_string(family.revision),
                  ),
                ),
              ]),
            ),
          ]
        }
        Ok(http_api.reply(
          200,
          json.object([
            #("items", json.array(items, fn(value) { value })),
            #("next", next),
            ..family
          ]),
        ))
      }
    }
  }
  http_api.answer(outcome)
}

type StreamMessage {
  StreamWake
  StreamTick
}

type CollectionStream {
  CollectionStream(
    config: Config,
    host: runtime.Runtime,
    parameters: List(#(String, String)),
    filter: session_collection.Filter,
    subscription: bus.Subscription,
    subject: Subject(StreamMessage),
    initial: Bool,
  )
}

fn collection_ids(
  ledger: store.Store,
  filter: session_collection.Filter,
  after: Option(session_collection.Key),
  ids: List(String),
) -> Result(List(String), http_api.Failure) {
  use page <- result.try(
    session_collection.page(ledger, filter, after, 200)
    |> result.map_error(http_api.failure),
  )
  let ids = list.fold(page.items, ids, fn(ids, item) { [item.info.id, ..ids] })
  case page.next {
    None -> Ok(ids)
    Some(next) -> collection_ids(ledger, filter, Some(next), ids)
  }
}

fn collection_overflow(connection: mist.Connection) -> mist.ChunkNext(a) {
  let _ =
    http_stream.send(
      connection,
      json.object([
        #(
          "events",
          json.array(
            [
              json.object([
                #("type", json.string("overflow")),
                #("data", json.object([])),
              ]),
            ],
            fn(value) { value },
          ),
        ),
      ])
        |> json.to_string,
    )
  mist.ChunkStop
}

fn collection_refresh(
  state: CollectionStream,
) -> Result(CollectionStream, http_api.Failure) {
  use filter <- result.try(collection_filter(
    state.config,
    state.host,
    state.parameters,
  ))
  use ids <- result.try(
    collection_ids(runtime.ledger(state.host), filter, None, []),
  )
  bus.set_filter(state.subscription, ids)
  Ok(CollectionStream(..state, filter: filter))
}

fn collection_stream_loop(
  state: CollectionStream,
  message: StreamMessage,
  connection: mist.Connection,
) -> mist.ChunkNext(CollectionStream) {
  case state.initial {
    True ->
      case collection_refresh(state) {
        Error(_) -> collection_overflow(connection)
        Ok(state) -> {
          let sent =
            http_stream.send(
              connection,
              json.object([
                #(
                  "events",
                  json.array(
                    [
                      json.object([
                        #("type", json.string("ready")),
                        #("data", json.object([])),
                      ]),
                      json.object([
                        #("type", json.string("reset")),
                        #(
                          "data",
                          json.object([#("reason", json.string("initial"))]),
                        ),
                      ]),
                    ],
                    fn(value) { value },
                  ),
                ),
              ])
                |> json.to_string,
            )
          case sent {
            Error(_) -> mist.ChunkStop
            Ok(_) -> {
              process.send(state.subject, StreamWake)
              mist.ChunkContinue(CollectionStream(..state, initial: False))
            }
          }
        }
      }
    False ->
      case bus.drain(state.subscription) {
        bus.Overflow -> collection_overflow(connection)
        bus.Batch(encoded) -> {
          let outcome = {
            use events <- result.try(list.try_map(encoded, http_api.event_value))
            use state <- result.try(
              case
                list.any(events, fn(event) { event.1 == Some("invalidate") })
              {
                True -> collection_refresh(state)
                False -> Ok(state)
              },
            )
            Ok(#(state, list.map(events, fn(event) { event.0 })))
          }
          case outcome {
            Error(_) -> collection_overflow(connection)
            Ok(#(state, events)) -> {
              let sent = case events, message {
                [], StreamWake -> Ok(Nil)
                [], StreamTick -> http_stream.keepalive(connection)
                _, _ ->
                  http_stream.send(
                    connection,
                    json.object([
                      #("events", json.array(events, fn(value) { value })),
                    ])
                      |> json.to_string,
                  )
              }
              case sent {
                Error(_) -> mist.ChunkStop
                Ok(_) -> {
                  bus.rearm(state.subscription, message == StreamWake)
                  case message {
                    StreamWake -> Nil
                    StreamTick -> {
                      let _ =
                        process.send_after(state.subject, 5000, StreamTick)
                      Nil
                    }
                  }
                  mist.ChunkContinue(state)
                }
              }
            }
          }
        }
      }
  }
}
