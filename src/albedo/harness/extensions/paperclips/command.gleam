//// /paperclips: the user's side of the vent channel. Replying records the
//// answer on the vent and queues a note for the session that filed it, so
//// an answer reaches the model at its next step without starting a turn.
//// The ledger is global, so the triaging session is often not the one that
//// vented.

import albedo/harness/command.{type Command, Argument, Command, Data, UserCall}
import albedo/harness/extensions/paperclips/ledger as paperclips
import albedo/harness/extensions/paperclips/notifications
import albedo/harness/extensions/paperclips/service
import albedo/harness/page
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string

pub fn command(store: paperclips.Store) -> Command {
  Command(
    "/paperclips",
    "Review what the model vented about: acknowledge <id>, reply <id> <text>, resolve <id>, dismiss <id>, remove <id>. A reply reaches the model as a note.",
    [
      Argument("action", "what to do; omit to review the vents", False, [
        "acknowledge", "reply", "resolve", "dismiss", "remove",
      ]),
      Argument("details", "reply: <id> <text> · the rest: <id>", False, []),
    ],
    False,
    False,
    True,
    None,
    fn(_ctx, caller, args) {
      let #(action, details) = page.args(args, "")
      case action, caller {
        "", _ -> listing(store)
        _, UserCall -> change(store, action, details)
        _, _ -> Error("only a user triages vents through /paperclips")
      }
    },
  )
}

fn listing(store: paperclips.Store) -> Result(command.Outcome, String) {
  use vents <- result.try(
    paperclips.page(store, 0, 200) |> result.map_error(describe),
  )
  use labels <- result.try(
    paperclips.session_labels(
      store,
      vents
        |> list.flat_map(fn(vent) {
          option.values([vent.session, vent.resolved_by])
        })
        |> list.unique,
    )
    |> result.map_error(describe),
  )
  Ok(
    Data(
      page.legacy(service.page(vents, labels), [
        page.Action(
          "a",
          "acknowledge",
          "acknowledge",
          True,
          page.NoInput,
          False,
        ),
        page.Action(
          "n",
          "reply",
          "reply",
          True,
          page.Text("answer", False),
          False,
        ),
        page.Action("r", "resolve", "resolve", True, page.NoInput, False),
        page.Action("d", "dismiss", "dismiss", True, page.NoInput, False),
        page.Action("x", "remove", "remove", True, page.NoInput, True),
      ]),
    ),
  )
}

fn change(
  store: paperclips.Store,
  action: String,
  details: String,
) -> Result(command.Outcome, String) {
  case action {
    "acknowledge" ->
      triage(store, "acknowledged", paperclips.Acknowledged, details)
    "resolve" -> triage(store, "resolved", paperclips.Resolved, details)
    "dismiss" -> triage(store, "dismissed", paperclips.Dismissed, details)
    "remove" -> remove(store, details)
    "reply" -> reply(store, details)
    _ ->
      Error(
        "unknown action "
        <> action
        <> "; use acknowledge, reply, resolve, dismiss, or remove",
      )
  }
}

fn triage(
  store: paperclips.Store,
  verb: String,
  status: paperclips.Status,
  details: String,
) -> Result(command.Outcome, String) {
  use #(vent, _) <- result.try(target(store, details))
  use updated <- result.try(
    paperclips.set_status(store, vent.id, status)
    |> result.map_error(describe),
  )
  Ok(resulted(verb, updated))
}

fn remove(
  store: paperclips.Store,
  details: String,
) -> Result(command.Outcome, String) {
  use #(vent, _) <- result.try(target(store, details))
  use removed <- result.try(
    paperclips.delete(store, vent.id) |> result.map_error(describe),
  )
  Ok(resulted("removed", removed))
}

/// Records the answer on the vent — acknowledging it — and queues the note
/// for the session that filed it, waiting for that session's next step. The
/// answer is durable either way; only the note is best-effort.
fn reply(
  store: paperclips.Store,
  details: String,
) -> Result(command.Outcome, String) {
  use #(vent, answer) <- result.try(target(store, details))
  use _ <- result.try(case answer == "" {
    True -> Error("a reply needs text: reply <id> <text>")
    False -> Ok(Nil)
  })
  use answered <- result.try(
    paperclips.answer(store, vent.id, answer) |> result.map_error(describe),
  )
  let label = "#" <> int.to_string(vent.id)
  let queued = notifications.reply(vent, answer)
  Ok(
    Data(
      json.object([
        #("vent", paperclips.to_json(answered)),
        #(
          "message",
          json.string(
            "replied to vent "
            <> label
            <> case queued {
              Ok(_) -> "; the model will be told"
              Error(error) ->
                "; could not tell the model: "
                <> error
                <> "; the answer is kept on the vent"
            },
          ),
        ),
      ]),
    ),
  )
}

fn resulted(verb: String, vent: paperclips.Vent) -> command.Outcome {
  Data(
    json.object([
      #("vent", paperclips.to_json(vent)),
      #("message", json.string(verb <> " vent #" <> int.to_string(vent.id))),
    ]),
  )
}

/// `<id> [rest]`: the vent and whatever follows its id.
fn target(
  store: paperclips.Store,
  details: String,
) -> Result(#(paperclips.Vent, String), String) {
  let #(first, rest) = page.split(details)
  use id <- result.try(
    int.parse(string.replace(first, "#", ""))
    |> result.replace_error("expected a vent id, like 3"),
  )
  use vent <- result.try(
    paperclips.get(store, id) |> result.map_error(describe),
  )
  Ok(#(vent, string.trim(rest)))
}

fn describe(error: paperclips.Error) -> String {
  case error {
    paperclips.Invalid(message) -> message
    paperclips.Conflict -> "vent changed"
    paperclips.NotFound -> "vent not found"
    paperclips.Storage(message) -> message
  }
}
