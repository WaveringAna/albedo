//// The kernel's host-call envelope: a request `{"method", "args"}` in, and
//// `{"ok": true, "value"}` or `{"ok": false, "code", "message"}` out.

import albedo/harness/host
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/list
import gleam/result
import gleam/string

/// Hands each call to the route whose namespace prefixes its method.
pub fn handle(
  routes: List(host.Route),
  context: host.Context,
  request: String,
) -> String {
  let found = {
    use method <- result.try(
      json.parse(request, decode.field("method", decode.string, decode.success))
      |> result.replace_error(Nil),
    )
    list.find(routes, fn(route) { string.starts_with(method, route.0 <> ".") })
  }
  case found {
    Ok(#(_, run)) -> run(context, request)
    Error(_) -> refuse("unavailable", "extension capability unavailable")
  }
}

/// One call's method and still-undecoded arguments.
pub fn decode(request: String) -> Result(#(String, Dynamic), Nil) {
  json.parse(request, {
    use method <- decode.field("method", decode.string)
    use args <- decode.field("args", decode.dynamic)
    decode.success(#(method, args))
  })
  |> result.replace_error(Nil)
}

/// Decodes one call's arguments, failing with `invalid` when they do not fit.
pub fn args(
  args: Dynamic,
  decoder: decode.Decoder(a),
  invalid: e,
) -> Result(a, e) {
  decode.run(args, decoder) |> result.replace_error(invalid)
}

/// Serves one call: decodes the envelope, dispatches on its method, and
/// encodes the answer, with `describe` naming each failure's code and message.
pub fn serve(
  request: String,
  invalid: e,
  dispatch: fn(String, Dynamic) -> Result(Json, e),
  describe: fn(e) -> #(String, String),
) -> String {
  case decode(request) {
    Ok(#(method, args)) -> dispatch(method, args)
    Error(_) -> Error(invalid)
  }
  |> result.map_error(describe)
  |> reply
}

pub fn reply(answer: Result(Json, #(String, String))) -> String {
  case answer {
    Ok(value) -> json.object([#("ok", json.bool(True)), #("value", value)])
    Error(#(code, message)) ->
      json.object([
        #("ok", json.bool(False)),
        #("code", json.string(code)),
        #("message", json.string(message)),
      ])
  }
  |> json.to_string
}

pub fn refuse(code: String, message: String) -> String {
  reply(Error(#(code, message)))
}
