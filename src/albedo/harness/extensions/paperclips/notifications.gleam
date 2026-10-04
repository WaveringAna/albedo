import albedo/harness/command
import albedo/harness/extensions/paperclips/ledger
import gleam/int
import gleam/json
import gleam/option.{None, Some}

/// Persistence precedes this best-effort notification in both adapters.
pub fn reply(vent: ledger.Vent, answer: String) -> Result(json.Json, String) {
  case vent.session {
    None -> Error("the vent records no session to answer")
    Some(session) ->
      command.context(session).state(command.Note(
        "paperclips",
        "answered vent #" <> int.to_string(vent.id),
        "<system-note>The user read your vent #"
          <> int.to_string(vent.id)
          <> " ("
          <> vent.message
          <> ") and answers: "
          <> answer
          <> "</system-note>",
      ))
  }
}
