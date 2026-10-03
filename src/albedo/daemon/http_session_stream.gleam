//// Session SSE ownership: replay cursors, durable resets, and delivery acknowledgement.

import albedo/daemon/http_api
import albedo/daemon/http_session_resource
import albedo/daemon/http_stream
import albedo/daemon/session
import albedo/daemon/store
import albedo/harness/protect
import gleam/erlang/process.{type Subject}
import gleam/http/request
import gleam/http/response
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import mist

type StreamMessage {
  StreamWake
  StreamTick
}

type State {
  State(
    secret: String,
    ledger: store.Store,
    worker: session.Session,
    owner: process.Pid,
    subject: Subject(StreamMessage),
    cursor: session.Cursor,
    initial: Option(String),
    tail: Int,
  )
}

fn session_batch(
  secret: String,
  ledger: store.Store,
  page: session.Page,
  after: Option(session.Cursor),
  tail: Int,
) -> Result(String, http_api.Failure) {
  let events = page.events
  let fields = [
    #("generation", json.string(page.cursor.generation)),
    #("cursor", json.int(page.cursor.sequence)),
  ]
  let batch = case page.snapshot {
    None ->
      Ok(
        json.object([
          #("events", json.array(events, fn(value) { value })),
          ..fields
        ]),
      )
    Some(capture) -> {
      use snapshot <- result.try(http_session_resource.encode(
        secret,
        ledger,
        capture,
        tail,
      ))
      let reason = case after {
        None -> "initial"
        Some(cursor) if cursor.generation != page.cursor.generation ->
          "generation_changed"
        _ -> "replay_unavailable"
      }
      let reset =
        json.object([
          #("type", json.string("reset")),
          #("data", json.object([#("reason", json.string(reason))])),
        ])
      Ok(
        json.object([
          #("snapshot", snapshot),
          #("events", json.array([reset, ..events], fn(value) { value })),
          ..fields
        ]),
      )
    }
  }
  result.map(batch, json.to_string)
}

pub fn attach(
  secret: String,
  ledger: store.Store,
  worker: session.Session,
  tail: Int,
  after: Option(session.Cursor),
  req: request.Request(mist.Connection),
) -> Result(response.Response(mist.ResponseData), http_api.Failure) {
  use _ <- result.try(http_stream.configure(req.body))
  use first <- result.try(
    session.read(worker, after)
    |> result.map_error(http_api.failure),
  )
  use initial <- result.try(session_batch(secret, ledger, first, after, tail))
  use _ <- result.try(
    case string.byte_size(initial) <= http_api.response_limit {
      True -> Ok(Nil)
      False ->
        Error(http_api.Failure(
          503,
          "snapshot_too_large",
          "captured session exceeds the response budget",
        ))
    },
  )
  Ok(mist.chunked(
    req,
    http_stream.response(req),
    fn(subject) {
      let owner = process.self()
      session.watch(worker, owner, fn() { process.send(subject, StreamWake) })
      process.send(subject, StreamWake)
      let _ = process.send_after(subject, 5000, StreamTick)
      State(
        secret,
        ledger,
        worker,
        owner,
        subject,
        first.cursor,
        Some(initial),
        tail,
      )
    },
    session_stream_loop,
  ))
}

fn stream_failure(
  connection: mist.Connection,
  cursor: session.Cursor,
  failure: http_api.Failure,
) -> mist.ChunkNext(a) {
  let _ =
    http_stream.send(
      connection,
      json.object([
        #("generation", json.string(cursor.generation)),
        #("cursor", json.int(cursor.sequence)),
        #(
          "events",
          json.array(
            [
              json.object([
                #("type", json.string("failure")),
                #("data", http_api.reason(failure.code, failure.detail)),
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

fn session_stream_loop(
  state: State,
  message: StreamMessage,
  connection: mist.Connection,
) -> mist.ChunkNext(State) {
  case state.initial {
    Some(batch) ->
      case http_stream.send(connection, batch) {
        Error(_) -> mist.ChunkStop
        Ok(_) -> {
          session.consumed(
            state.worker,
            state.owner,
            state.cursor,
            message == StreamWake,
          )
          process.send(state.subject, StreamWake)
          mist.ChunkContinue(State(..state, initial: None))
        }
      }
    None -> {
      let captured =
        protect.attempt(fn() { session.read(state.worker, Some(state.cursor)) })
        |> result.replace_error("daemon is shutting down")
        |> result.flatten
        |> result.map_error(http_api.failure)
      let outcome = {
        use page <- result.try(captured)
        use batch <- result.try(session_batch(
          state.secret,
          state.ledger,
          page,
          Some(state.cursor),
          state.tail,
        ))
        Ok(#(page, batch))
      }
      case outcome {
        Error(failure) -> stream_failure(connection, state.cursor, failure)
        Ok(#(page, batch)) -> {
          let sent = case
            page.snapshot == None
            && list.is_empty(page.events)
            && message == StreamTick
          {
            True -> http_stream.keepalive(connection)
            False -> http_stream.send(connection, batch)
          }
          case sent {
            Error(_) -> mist.ChunkStop
            Ok(_) -> {
              session.consumed(
                state.worker,
                state.owner,
                page.cursor,
                message == StreamWake,
              )
              case message {
                StreamTick -> {
                  let _ = process.send_after(state.subject, 5000, StreamTick)
                  Nil
                }
                StreamWake -> Nil
              }
              mist.ChunkContinue(State(..state, cursor: page.cursor))
            }
          }
        }
      }
    }
  }
}

pub fn cursor(
  parameters: List(#(String, String)),
  watching: Bool,
) -> Result(Option(session.Cursor), http_api.Failure) {
  case
    watching,
    list.key_find(parameters, "after_generation"),
    list.key_find(parameters, "after_seq")
  {
    _, Error(_), Error(_) -> Ok(None)
    False, _, _ -> Error(http_api.invalid("replay parameters require SSE"))
    True, Ok(generation), Ok(_) -> {
      use sequence <- result.try(http_api.integer_parameter(
        parameters,
        "after_seq",
        0,
        9_007_199_254_740_991,
      ))
      use _ <- result.try(
        case
          string.byte_size(generation) == 22
          && list.all(string.to_graphemes(generation), fn(character) {
            string.contains(
              "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_",
              character,
            )
          })
        {
          True -> Ok(Nil)
          False -> Error(http_api.invalid("invalid replay generation"))
        },
      )
      Ok(Some(session.Cursor(generation, sequence)))
    }
    True, Error(_), Ok(_) -> {
      use _ <- result.try(http_api.integer_parameter(
        parameters,
        "after_seq",
        0,
        9_007_199_254_740_991,
      ))
      Ok(None)
    }
    _, _, _ -> Error(http_api.invalid("after_generation requires after_seq"))
  }
}
