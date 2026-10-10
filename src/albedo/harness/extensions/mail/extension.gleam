//// Mail between sessions for the model: one call, `mail.submit`. The daemon
//// derives the sender from the calling session, so python never names one.

import albedo/daemon/mail
import albedo/daemon/store
import albedo/harness/extension
import albedo/harness/host
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
        "await mail.submit(to, body) sends a letter as this session. `to` is \"parent\", the name of a child or sibling, an agent handle, or any session id; names outside your family do not resolve, so use the id. It returns a receipt (id, to, name, status): \"delivered\" was accepted by an idle recipient (its kernel may still be booting), \"queued\" waits behind its running turn, \"pending\" is stored and arrives once that session is running. There is no mail.read: letters to you arrive in your conversation as <mail> blocks. Bodies over 1 MiB fail; write big results to a file and send the path.",
        [],
        ["mail"],
        [
          #("mail", fn(context: host.Context, method, args) {
            handle(context.store, context.session, method, args)
          }),
        ],
      ),
    ],
    mail.initialise,
  )
}

fn handle(
  db: store.Store,
  session: String,
  method: String,
  args: decode.Dynamic,
) -> Result(json.Json, #(String, String)) {
  case method {
    "mail.submit" -> {
      let decoder = {
        use to <- decode.field("to", decode.string)
        use body <- decode.field("body", decode.string)
        decode.success(#(to, body))
      }
      case decode.run(args, decoder) {
        Ok(#(to, body)) ->
          mail.send(db, session, to, body)
          |> result.map(mail.receipt_json)
          |> result.map_error(fn(m) { #("invalid", m) })
        Error(_) ->
          Error(#("invalid", "mail.submit(to, body) takes two strings"))
      }
    }
    _ -> Error(#("invalid", "mail.submit(to, body) takes two strings"))
  }
}
