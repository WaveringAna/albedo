//// /paperclips: the user's side of the vent channel. Replying to a vent also
//// queues a note for the model, so an answer reaches it at its next step
//// without starting a turn.

import albedo/harness/command.{
  type Command, type Context, Argument, Command, Data, Note, UserCall,
}
import albedo/harness/extensions/paperclips/ledger as paperclips
import albedo/harness/page
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string

pub fn command(store: paperclips.Store, cwd: String) -> Command {
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
    fn(ctx, caller, args) {
      let #(action, details) = page.args(args, "")
      case action, caller {
        "", _ -> listing(store, cwd)
        _, UserCall -> change(store, cwd, ctx, action, details)
        _, _ -> Error("only a user triages vents through /paperclips")
      }
    },
  )
}

fn listing(
  store: paperclips.Store,
  cwd: String,
) -> Result(command.Outcome, String) {
  use vents <- result.try(
    paperclips.list(store, cwd, 200) |> result.map_error(describe),
  )
  let ordered = list.sort(vents, fn(a, b) { int.compare(rank(a), rank(b)) })
  let rows = list.map(ordered, row)
  let open = list.filter(ordered, fn(vent) { vent.status == paperclips.Open })
  Ok(
    Data(
      page.to_json(page.Document(
        "paperclips",
        summary(ordered),
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
        Some(page.Glance("open vents", list.map(open, row))),
      )),
    ),
  )
}

/// Open vents first, then acknowledged, then the quietly finished ones;
/// newest within a rank.
fn status_style(status: paperclips.Status) -> #(Int, page.Tone) {
  case status {
    paperclips.Open -> #(0, page.Warning)
    paperclips.Acknowledged -> #(1, page.Active)
    paperclips.Resolved -> #(2, page.Muted)
    paperclips.Dismissed -> #(3, page.Muted)
  }
}

fn rank(vent: paperclips.Vent) -> Int {
  status_style(vent.status).0 * 1_000_000 - vent.id
}

fn row(vent: paperclips.Vent) -> page.Row {
  page.detail_row(
    int.to_string(vent.id),
    case vent.title {
      "" -> short_title(vent.message)
      title -> title
    },
    paperclips.status_name(vent.status),
    status_style(vent.status).1,
    detail(vent),
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
fn detail(vent: paperclips.Vent) -> String {
  [
    vent.message,
    case vent.suggestion {
      "" -> ""
      suggestion -> "\n\nsuggestion: " <> suggestion
    },
    "\n\nfiled "
      <> vent.created_at
      <> case vent.session {
      Some(session) -> " by session " <> string.slice(session, 0, 8)
      None -> ""
    },
  ]
  |> string.concat
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
  cwd: String,
  ctx: Context,
  action: String,
  details: String,
) -> Result(command.Outcome, String) {
  case action {
    "acknowledge" ->
      triage(store, cwd, "acknowledged", paperclips.Acknowledged, details)
    "resolve" -> triage(store, cwd, "resolved", paperclips.Resolved, details)
    "dismiss" -> triage(store, cwd, "dismissed", paperclips.Dismissed, details)
    "remove" -> remove(store, cwd, details)
    "reply" -> reply(store, cwd, ctx, details)
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
  cwd: String,
  verb: String,
  status: paperclips.Status,
  details: String,
) -> Result(command.Outcome, String) {
  use #(vent, _) <- result.try(target(store, cwd, details))
  use updated <- result.try(
    paperclips.set_status(store, cwd, vent.id, status)
    |> result.map_error(describe),
  )
  Ok(resulted(verb, updated))
}

fn remove(
  store: paperclips.Store,
  cwd: String,
  details: String,
) -> Result(command.Outcome, String) {
  use #(vent, _) <- result.try(target(store, cwd, details))
  use removed <- result.try(
    paperclips.delete(store, cwd, vent.id) |> result.map_error(describe),
  )
  Ok(resulted("removed", removed))
}

/// Marks the vent acknowledged and queues the answer as a note for the model.
fn reply(
  store: paperclips.Store,
  cwd: String,
  ctx: Context,
  details: String,
) -> Result(command.Outcome, String) {
  use #(vent, answer) <- result.try(target(store, cwd, details))
  use _ <- result.try(case answer == "" {
    True -> Error("a reply needs text: reply <id> <text>")
    False -> Ok(Nil)
  })
  use acknowledged <- result.try(
    paperclips.set_status(store, cwd, vent.id, paperclips.Acknowledged)
    |> result.map_error(describe),
  )
  let label = "#" <> int.to_string(vent.id)
  let queued =
    ctx.state(Note(
      "paperclips",
      "answered vent " <> label,
      "<system-note>The user read your vent "
        <> label
        <> " ("
        <> vent.message
        <> ") and answers: "
        <> answer
        <> "</system-note>",
    ))
  Ok(
    Data(
      json.object([
        #("vent", paperclips.to_json(acknowledged)),
        #(
          "message",
          json.string(
            "replied to vent "
            <> label
            <> case queued {
              Ok(_) -> "; the model will be told"
              Error(error) -> "; could not tell the model: " <> error
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
  cwd: String,
  details: String,
) -> Result(#(paperclips.Vent, String), String) {
  let #(first, rest) = page.split(details)
  use id <- result.try(
    int.parse(string.replace(first, "#", ""))
    |> result.replace_error("expected a vent id, like 3"),
  )
  use vent <- result.try(
    paperclips.get(store, cwd, id) |> result.map_error(describe),
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
