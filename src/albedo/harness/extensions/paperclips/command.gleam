//// /paperclips: the user's side of the vent channel. Replying records the
//// answer on the vent and queues a note for the session that filed it, so
//// an answer reaches the model at its next step without starting a turn.
//// The ledger is global, so the triaging session is often not the one that
//// vented.

import albedo/harness/command.{
  type Command, Argument, Command, Data, Note, UserCall,
}
import albedo/harness/extensions/paperclips/ledger as paperclips
import albedo/harness/page
import gleam/dict
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
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
    paperclips.review(store, 200) |> result.map_error(describe),
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
  let rows = list.map(vents, row(labels, _))
  let open = list.filter(vents, fn(vent) { vent.status == paperclips.Open })
  Ok(
    Data(
      page.to_json(page.Document(
        "paperclips",
        summary(vents),
        "nothing vented yet · the model files vents with vent()",
        rows,
        [
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
        ],
        Some(page.Glance("open vents", list.map(open, glance_row))),
      )),
    ),
  )
}

/// Open vents first, then acknowledged, then the quietly finished ones —
/// the tone each status wears. `paperclips.review` already orders rows this
/// way, newest within each rank.
fn status_style(status: paperclips.Status) -> #(Int, page.Tone) {
  case status {
    paperclips.Open -> #(0, page.Warning)
    paperclips.Acknowledged -> #(1, page.Active)
    paperclips.Resolved -> #(2, page.Muted)
    paperclips.Dismissed -> #(3, page.Muted)
  }
}

fn title(vent: paperclips.Vent) -> String {
  case vent.title {
    "" -> short_title(vent.message)
    title -> title
  }
}

fn row(labels: dict.Dict(String, String), vent: paperclips.Vent) -> page.Row {
  page.detail_row(
    int.to_string(vent.id),
    title(vent),
    paperclips.status_name(vent.status),
    status_style(vent.status).1,
    detail(labels, vent),
  )
}

/// The glance sidebar shows one short line per open vent; its details wait
/// for the page itself, so the 3-second glance poll never builds them.
fn glance_row(vent: paperclips.Vent) -> page.Row {
  page.detail_row(
    int.to_string(vent.id),
    title(vent),
    paperclips.status_name(vent.status),
    status_style(vent.status).1,
    "",
  )
}

/// The columns of the list a titleless vent's title may take.
const title_columns = 64

/// The list shows one short line per vent even when the model did not set
/// a title; the full text belongs in the detail.
fn short_title(message: String) -> String {
  let flat = string.replace(message, "\n", " ")
  case string.length(flat) <= title_columns {
    True -> flat
    False ->
      flat
      |> string.to_graphemes
      |> list.take(title_columns)
      |> string.concat
      <> "…"
  }
}

/// Everything the detail pane shows for one vent.
fn detail(labels: dict.Dict(String, String), vent: paperclips.Vent) -> String {
  [
    vent.message,
    case vent.suggestion {
      "" -> ""
      suggestion -> "\n\nsuggestion: " <> suggestion
    },
    case vent.reply {
      "" -> ""
      reply -> "\n\nanswered: " <> reply
    },
    case vent.resolution {
      "" -> ""
      resolution ->
        "\n\nresolved by session "
        <> session_label(labels, vent.resolved_by)
        <> ": "
        <> resolution
    },
    "\n\nfiled "
      <> vent.created_at
      <> " by session "
      <> session_label(labels, vent.session)
      <> " in "
      <> vent.cwd,
  ]
  |> string.concat
}

/// The filing session by its name when it has one, else a short id.
fn session_label(
  labels: dict.Dict(String, String),
  session: Option(String),
) -> String {
  case session {
    Some(session) ->
      dict.get(labels, session) |> result.unwrap(string.slice(session, 0, 8))
    None -> "—"
  }
}

fn summary(vents: List(paperclips.Vent)) -> String {
  [
    paperclips.Open, paperclips.Acknowledged, paperclips.Resolved,
    paperclips.Dismissed,
  ]
  |> list.filter_map(fn(status) {
    case list.count(vents, fn(vent) { vent.status == status }) {
      0 -> Error(Nil)
      count -> Ok(int.to_string(count) <> " " <> paperclips.status_name(status))
    }
  })
  |> string.join(" · ")
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
  let note =
    Note(
      "paperclips",
      "answered vent " <> label,
      "<system-note>The user read your vent "
        <> label
        <> " ("
        <> vent.message
        <> ") and answers: "
        <> answer
        <> "</system-note>",
    )
  let queued = case vent.session {
    Some(session) -> command.context(session).state(note)
    None -> Error("the vent records no session to answer")
  }
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
    paperclips.NotFound -> "vent not found"
    paperclips.Storage(message) -> message
  }
}
