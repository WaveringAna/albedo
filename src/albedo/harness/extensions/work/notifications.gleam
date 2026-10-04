import albedo/harness/command
import albedo/harness/extensions/work/ledger
import gleam/int
import gleam/json

pub fn queue(
  item: ledger.Item,
  verb: String,
  send: fn(command.StateOp) -> Result(json.Json, String),
) -> Result(json.Json, String) {
  send(command.Note(
    "work",
    verb <> " work item " <> item.title,
    "<system-note>The user "
      <> verb
      <> " work item #"
      <> int.to_string(item.id)
      <> " · "
      <> item.title
      <> " (status "
      <> ledger.status_name(item.status)
      <> ") in the shared work ledger.</system-note>",
  ))
}
