//// The kernel's host calls: a method and native arguments in, and
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
  method: String,
  args: Dynamic,
) -> String {
  let found =
    list.find(routes, fn(route) { string.starts_with(method, route.0 <> ".") })
  case found {
    Ok(#(_, run)) -> run(context, method, args)
    Error(_) -> Error(#("unavailable", "extension capability unavailable"))
  }
  |> reply
}

/// Decodes one call's arguments, failing with `invalid` when they do not fit.
pub fn args(
  args: Dynamic,
  decoder: decode.Decoder(a),
  invalid: e,
) -> Result(a, e) {
  decode.run(args, decoder) |> result.replace_error(invalid)
}

/// Serves one call: dispatches on its method, mapping errors to their code and message.
pub fn serve(
  method: String,
  args: Dynamic,
  dispatch: fn(String, Dynamic) -> Result(Json, e),
  describe: fn(e) -> #(String, String),
) -> Result(Json, #(String, String)) {
  dispatch(method, args)
  |> result.map_error(describe)
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
