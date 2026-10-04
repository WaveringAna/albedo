import albedo/harness/extensions/paperclips/ledger as paperclips
import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

const title_columns = 64

pub fn title(vent: paperclips.Vent) -> String {
  case vent.title {
    "" -> short_title(vent.message)
    title -> title
  }
}

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
pub fn detail(
  labels: dict.Dict(String, String),
  vent: paperclips.Vent,
) -> String {
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
