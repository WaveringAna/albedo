//// An OpenAI-compatible endpoint over every saved profile. Stateless: each
//// request carries its conversation, which is projected onto the profile's
//// upstream and streamed back as Chat Completions.

import albedo/clock

import albedo/daemon/configuration
import albedo/daemon/http_api
import albedo/daemon/projection
import albedo/harness/extension
import albedo/harness/extensions/proxy/chat
import albedo/openai_api/types
import gleam/bytes_tree
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http.{type Method, Get, Post}
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
    "OpenAI-compatible Chat Completions at /extensions/proxy/v1 for every saved provider profile",
    [],
    [
      extension.ServicePlugin(extension.Service(admission, handle)),
    ],
    extension.no_initialise,
  )
}

fn admission(path: List(String), method: Method) -> extension.Admission {
  let authorization = case allow_anonymous() {
    True -> extension.LocalAccess
    False -> extension.DaemonToken
  }
  case method, path {
    Get, ["v1", "models"] -> extension.RelayAdmission(authorization, 65_536)
    Post, ["v1", "chat", "completions"] ->
      extension.RelayAdmission(authorization, 32_000_000)
    _, _ -> extension.Admission(extension.DaemonToken, 65_536)
  }
}

@external(erlang, "albedo_proxy", "allow_anonymous")
fn allow_anonymous() -> Bool

fn handle(
  daemon: extension.Daemon,
  path: List(String),
  req: request.Request(BitArray),
  live: request.Request(mist.Connection),
) -> response.Response(mist.ResponseData) {
  case http_api.parameters(req, []) {
    Error(failure) -> respond(failure.status, chat.error(failure.detail))
    Ok(_) -> dispatch(daemon, path, req, live)
  }
}

fn dispatch(
  daemon: extension.Daemon,
  path: List(String),
  req: request.Request(BitArray),
  live: request.Request(mist.Connection),
) -> response.Response(mist.ResponseData) {
  case req.method, path {
    Get, ["v1", "models"] ->
      case models(daemon) {
        Ok(value) -> respond(200, value)
        Error(message) -> respond(503, chat.error(message))
      }
    Post, ["v1", "chat", "completions"] ->
      case http_api.body(req, chat.request_fields(), chat.request_decoder()) {
        Error(failure) -> respond(failure.status, chat.error(failure.detail))
        Ok(fields) ->
          case chat.from_fields(fields) {
            Error(message) -> respond(400, chat.error(message))
            Ok(completion) -> complete(daemon, live, completion)
          }
      }
    _, ["v1", "models"] | _, ["v1", "chat", "completions"] ->
      respond(405, chat.error("method not allowed"))
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
fn models(daemon: extension.Daemon) -> Result(Json, String) {
  use available <- result.try(configuration.profiles(daemon.home))
  let #(usable, broken) = result.partition(available)
  let #(profiles, errors) = #(
    list.reverse(usable),
    list.take(list.reverse(broken), 200),
  )
  let ids =
    list.flat_map(profiles, fn(profile) {
      let catalog = case endpoint(daemon, profile) {
        option.None -> daemon.models(profile.extension, option.None)
        option.Some(_) -> []
      }
      case catalog {
        [] -> [profile.model]
        models -> models
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
  Ok(
    json.object(case errors {
      [] -> fields
      errors ->
        list.append(fields, [
          #(
            "errors",
            json.array(errors, fn(pair) {
              json.object([
                #("profile", json.string(pair.0)),
                #("message", json.string(http_api.scalar_prefix(pair.1, 4096))),
              ])
            }),
          ),
        ])
    }),
  )
}

fn endpoint(
  daemon: extension.Daemon,
  profile: configuration.Provider,
) -> option.Option(String) {
  configuration.settings(
    daemon.home,
    profile.name,
    decode.optional_field("baseUrl", "", decode.string, decode.success),
  )
  |> result.unwrap("")
  |> extension.clean_endpoint
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
  let reply =
    chat.Reply(chat.id(unique()), clock.system_seconds(), completion.requested)
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
          case
            mist.send_event(connection, mist.event(json.to_string_tree(value)))
          {
            Ok(_) -> actor.continue(state)
            Error(_) -> actor.stop()
          }
        Done -> {
          let _ =
            mist.send_event(
              connection,
              mist.event(string_tree.from_string("[DONE]")),
            )
          actor.stop()
        }
      }
    },
  )
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

@external(erlang, "albedo_proxy", "unique")
fn unique() -> Int
