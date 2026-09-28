import albedo/daemon/mail
import albedo/harness/extension
import albedo/harness/extensions/webhooks/ledger
import gleam/bytes_tree
import gleam/http.{Post}
import gleam/http/request
import gleam/http/response
import gleam/json
import gleam/option
import gleam/result
import mist

pub fn handle(
  daemon: extension.Daemon,
  path: List(String),
  req: request.Request(mist.Connection),
) -> response.Response(mist.ResponseData) {
  case req.method, path {
    Post, [id] -> {
      let accepted = {
        use raw <- result.try(
          mist.read_body(req, 65_536)
          |> result.replace_error(ledger.Invalid(
            "body unreadable or exceeds 64 KiB",
          )),
        )
        let event_key =
          request.get_header(req, "x-albedo-event-id") |> option.from_result
        ledger.accept(daemon.ledger, id, req.headers, raw.body, event_key)
      }
      case accepted {
        Ok(delivery) -> {
          mail.waiting()
          respond(
            202,
            json.object([
              #("accepted", json.bool(True)),
              #("deliveryId", json.string(delivery)),
            ]),
          )
        }
        Error(ledger.NotFound) -> respond(404, message("hook not found"))
        Error(ledger.Unauthorized) -> respond(401, message("invalid signature"))
        Error(ledger.Overloaded) -> respond(429, message("webhook queue full"))
        Error(ledger.Conflict) ->
          respond(409, message("event id already used for a different body"))
        Error(ledger.Invalid("webhook body exceeds 64 KiB" as reason))
        | Error(ledger.Invalid("body unreadable or exceeds 64 KiB" as reason)) ->
          respond(413, message(reason))
        Error(ledger.Invalid(reason)) -> respond(400, message(reason))
        Error(_) -> respond(503, message("webhook unavailable"))
      }
    }
    _, _ -> respond(404, message("hook not found"))
  }
}

fn message(text: String) -> json.Json {
  json.object([#("error", json.string(text))])
}

fn respond(
  status: Int,
  body: json.Json,
) -> response.Response(mist.ResponseData) {
  response.new(status)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(json.to_string(body))))
}
