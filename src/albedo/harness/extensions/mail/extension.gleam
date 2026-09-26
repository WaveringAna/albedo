//// Mail between sessions for the model: one call, `mail.submit`. The daemon
//// derives the sender from the calling session, so python never names one.

import albedo/daemon/mail
import albedo/daemon/store
import albedo/harness/extension
import gleam/dynamic/decode
import gleam/json
import gleam/result

pub fn extension() -> extension.Extension {
  extension.Extension(
    "mail",
    "Letters between sessions: to your parent, your children and siblings by name, or any session by id.",
    ["python"],
    [
      extension.ToolPlugin(
        "await mail.submit(to, body) sends a letter as this session. `to` is \"parent\", the name of a child or sibling, an agent handle, or any session id; names outside your family do not resolve, so use the id. It returns a receipt (id, to, name, status): \"delivered\" started the recipient's turn, \"queued\" waits behind its running turn, \"pending\" is stored and arrives once that session is running. There is no mail.read: letters to you arrive in your conversation as <mail> blocks. Bodies over 1 MiB fail; write big results to a file and send the path.",
        [],
        ["mail"],
        [#("mail", handle)],
      ),
    ],
    mail.initialise,
  )
}

fn handle(db: store.Store, session: String, request: String) -> String {
  let decoder = {
    use method <- decode.field("method", decode.string)
    use to <- decode.subfield(["args", "to"], decode.string)
    use body <- decode.subfield(["args", "body"], decode.string)
    decode.success(#(method, to, body))
  }
  case json.parse(request, decoder) {
    Ok(#("mail.submit", to, body)) ->
      mail.send(db, session, to, body)
      |> result.map(fn(receipt) {
        json.object([
          #("id", json.string(receipt.id)),
          #("to", json.string(receipt.recipient)),
          #("name", json.string(receipt.name)),
          #("status", json.string(receipt.status)),
        ])
      })
      |> answer
    _ -> answer(Error("mail.submit(to, body) takes two strings"))
  }
}

pub fn answer(result: Result(json.Json, String)) -> String {
  case result {
    Ok(value) -> json.object([#("ok", json.bool(True)), #("value", value)])
    Error(message) ->
      json.object([
        #("ok", json.bool(False)),
        #("code", json.string("invalid")),
        #("message", json.string(message)),
      ])
  }
  |> json.to_string
}
