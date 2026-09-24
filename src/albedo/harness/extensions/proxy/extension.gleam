//// An OpenAI-compatible endpoint over every saved profile. Stateless: each
//// request carries its conversation, which is projected onto the profile's
//// upstream and streamed back as Chat Completions.

import albedo/daemon/configuration
import albedo/daemon/projection
import albedo/daemon/store
import albedo/harness/extension
import albedo/harness/extensions/proxy/chat
import albedo/openai_api/types
import gleam/bytes_tree
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http.{Get, Post}
import gleam/http/request
import gleam/http/response
import gleam/json.{type Json}
import gleam/list
import gleam/option
import gleam/otp/actor
import gleam/result
import gleam/string
import gleam/string_tree
import mist

pub fn extension() -> extension.Extension {
  extension.Extension(
    "proxy",
    "OpenAI-compatible Chat Completions at /proxy/v1 for every saved provider profile",
    [],
    [extension.ServicePlugin(extension.Service(handle))],
    initialise,
  )
}

fn initialise(_ledger: store.Store) -> Result(Nil, String) {
  Ok(Nil)
}

fn handle(
  daemon: extension.Daemon,
  path: List(String),
  req: request.Request(mist.Connection),
) -> response.Response(mist.ResponseData) {
  case req.method, path {
    Get, ["v1", "models"] -> respond(200, models(daemon))
    Post, ["v1", "chat", "completions"] ->
      case
        mist.read_body(req, 32_000_000)
        |> result.replace_error("request body is unreadable or too large")
        |> result.try(fn(req) { chat.parse(req.body) })
      {
        Error(message) -> respond(400, chat.error(message))
        Ok(completion) -> complete(daemon, req, completion)
      }
    _, _ -> respond(404, chat.error("no such proxy route"))
  }
}

/// A profile with its own endpoint lists only its saved model: models.dev
/// can only guess what an arbitrary endpoint serves. Every other profile
/// lists its provider's catalog, or its saved model until one is cached.
///
/// Listing only helps clients choose: any `<profile>/<model>` is requested
/// as given. Profiles that cannot be used are named under a nonstandard
/// `errors` field, which clients ignore, instead of failing the list.
fn models(daemon: extension.Daemon) -> Json {
  let #(profiles, errors) = case configuration.profiles(daemon.home) {
    Ok(profiles) -> {
      let #(usable, broken) = result.partition(profiles)
      #(list.reverse(usable), list.reverse(broken))
    }
    Error(message) -> #([], [#("", message)])
  }
  let ids =
    list.flat_map(profiles, fn(profile) {
      case endpoint(daemon, profile) {
        "" ->
          case daemon.models(profile.extension, "") {
            [] -> [profile.model]
            catalog -> catalog
          }
        _ -> [profile.model]
      }
      |> list.map(fn(model) {
        #(profile.name <> "/" <> model, profile.extension)
      })
    })
  let fields = [
    #("object", json.string("list")),
    #(
      "data",
      json.array(ids, fn(pair) {
        json.object([
          #("id", json.string(pair.0)),
          #("object", json.string("model")),
          #("created", json.int(0)),
          #("owned_by", json.string(pair.1)),
        ])
      }),
    ),
  ]
  json.object(case errors {
    [] -> fields
    errors ->
      list.append(fields, [
        #(
          "errors",
          json.array(errors, fn(pair) {
            json.object([
              #("profile", json.string(pair.0)),
              #("message", json.string(pair.1)),
            ])
          }),
        ),
      ])
  })
}

fn endpoint(
  daemon: extension.Daemon,
  profile: configuration.Provider,
) -> String {
  configuration.settings(daemon.home, profile.name, decode_field("baseUrl"))
  |> result.unwrap("")
}

fn decode_field(name: String) -> decode.Decoder(String) {
  decode.optional_field(name, "", decode.string, decode.success)
}

fn complete(
  daemon: extension.Daemon,
  req: request.Request(mist.Connection),
  completion: chat.Completion,
) -> response.Response(mist.ResponseData) {
  let resolved = {
    use profiles <- result.try(configuration.profiles(daemon.home))
    use profile <- result.try(
      list.find_map(profiles, fn(profile) {
        case profile {
          Ok(profile) if profile.name == completion.profile -> Ok(Ok(profile))
          Error(#(name, reason)) if name == completion.profile ->
            Ok(Error(completion.profile <> ": " <> reason))
          _ -> Error(Nil)
        }
      })
      |> result.replace_error("unknown model " <> completion.requested)
      |> result.flatten,
    )
    let model = case completion.model {
      "" -> profile.model
      model -> model
    }
    use upstream <- result.try(daemon.upstream(
      profile.name,
      model,
      conversation(completion.conversation),
    ))
    // Carried turns replay verbatim only to the profile that produced them.
    // Projection takes and returns history newest first.
    use input <- result.map(
      completion.history
      |> list.reverse
      |> projection.for_model(profile.name, upstream.protocol)
      |> result.map(list.reverse),
    )
    #(
      profile.name,
      upstream,
      types.Request(..completion.request, model: model, input: input),
    )
  }
  let reply = chat.Reply(chat.id(unique()), now(), completion.requested)
  case resolved, completion.stream {
    Error(message), _ -> respond(400, chat.error(message))
    Ok(#(profile, upstream, request)), False ->
      case upstream.stream(request, fn(_) { types.Continue }) {
        Ok(turn) ->
          respond(
            200,
            chat.completion(reply, chat.carry(turn, profile, upstream.protocol)),
          )
        Error(error) -> respond(502, chat.error(describe(upstream, error)))
      }
    Ok(#(profile, upstream, request)), True ->
      stream(req, profile, upstream, request, reply, completion.include_usage)
  }
}

type Out {
  Chunk(Json)
  Done
}

fn stream(
  req: request.Request(mist.Connection),
  profile: String,
  upstream: extension.Upstream,
  request: types.Request,
  reply: chat.Reply,
  include_usage: Bool,
) -> response.Response(mist.ResponseData) {
  mist.server_sent_events(
    req,
    response.new(200) |> response.set_header("cache-control", "no-cache"),
    fn(self) {
      let sink = process.self()
      // Linked, so a crash ends the response; a gone client is noticed by the
      // next event and stops the upstream through its callback.
      process.spawn(fn() {
        let send = fn(chunk) {
          case process.is_alive(sink) {
            True -> {
              process.send(self, Chunk(chunk))
              types.Continue
            }
            False -> types.Stop
          }
        }
        let _ = send(chat.opening(reply))
        let outcome =
          upstream.stream(request, fn(event) {
            chat.delta(reply, event)
            |> option.map(send)
            |> option.unwrap(types.Continue)
          })
        case outcome {
          Ok(turn) ->
            chat.carry(turn, profile, upstream.protocol)
            |> chat.closing(reply, _, include_usage)
            |> list.each(send)
          Error(error) -> {
            let _ = send(chat.error(describe(upstream, error)))
            Nil
          }
        }
        process.send(self, Done)
      })
      Nil
    },
    fn(state, message, connection) {
      case message {
        Chunk(value) ->
          case mist.send_event(connection, event(json.to_string_tree(value))) {
            Ok(_) -> actor.continue(state)
            Error(_) -> actor.stop()
          }
        Done -> {
          let _ =
            mist.send_event(
              connection,
              event(string_tree.from_string("[DONE]")),
            )
          actor.stop()
        }
      }
    },
  )
}

fn event(data: string_tree.StringTree) {
  mist.event(data)
}

fn describe(upstream: extension.Upstream, error: types.Error) -> String {
  upstream.explain(error) |> option.lazy_unwrap(fn() { string.inspect(error) })
}

fn respond(status: Int, value: Json) -> response.Response(mist.ResponseData) {
  response.new(status)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(mist.Bytes(
    value |> json.to_string_tree |> bytes_tree.from_string_tree,
  ))
}

@external(erlang, "albedo_proxy", "conversation")
fn conversation(seed: String) -> String

@external(erlang, "albedo_proxy", "now")
fn now() -> Int

@external(erlang, "albedo_proxy", "unique")
fn unique() -> Int
