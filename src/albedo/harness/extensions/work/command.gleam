//// `/work`: the human side of the work ledger. Listing needs nothing; every
//// change a user makes is also queued as a note for the agent, so the agent
//// learns about it at its next step instead of from a stale read.

import albedo/harness/command.{
  type Command, type Context, Argument, Command, Data, Note, UserCall,
}
import albedo/harness/extensions/work/ledger as work
import albedo/harness/page
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string

pub fn command(store: work.Store, cwd: String) -> Command {
  Command(
    "/work",
    "Show the shared work ledger, or change it: add <title>, edit <id> <title>, status <id> <status>, remove <id>. The agent is told about every change.",
    [
      Argument("action", "what to change; omit to list the ledger", False, [
        "add", "edit", "status", "remove",
      ]),
      Argument(
        "details",
        "add: <title> · edit: <id> <title> · status: <id> <open|active|blocked|done|cancelled> · remove: <id>",
        False,
        [],
      ),
    ],
    False,
    False,
    True,
    fn(ctx, caller, args) {
      let #(action, details) = page.args(args, "")
      case action, caller {
        "", _ -> listing(store, cwd)
        _, UserCall -> change(store, cwd, ctx, action, details)
        _, _ -> Error("only a user changes the ledger through /work")
      }
    },
  )
}

fn listing(store: work.Store, cwd: String) -> Result(command.Outcome, String) {
  use items <- result.try(
    work.list(store, cwd, 0, 200) |> result.map_error(describe),
  )
  let ordered = list.sort(items, fn(a, b) { int.compare(rank(a), rank(b)) })
  let rows = list.map(ordered, row)
  let pending = list.filter(ordered, fn(item) { rank(item) < 3 })
  Ok(
    Data(
      page.to_json(page.Document(
        "work",
        summary(items),
        "nothing tracked yet · a adds an item",
        rows,
        [
          page.Action(
            "a",
            "add",
            "add",
            False,
            page.Text("title", False),
            False,
          ),
          page.Action(
            "e",
            "rename",
            "edit",
            True,
            page.Text("title", True),
            False,
          ),
          page.Action("d", "done", "status", True, page.Value("done"), False),
          page.Action(
            "s",
            "status",
            "status",
            True,
            page.Choice(["open", "active", "blocked", "done", "cancelled"]),
            False,
          ),
          page.Action("x", "remove", "remove", True, page.NoInput, True),
        ],
        Some(page.Glance("pending work", list.map(pending, row))),
      )),
    ),
  )
}

/// Rank and tone: active work first, then blocked, open, and finished items last.
fn status_style(status: work.Status) -> #(Int, page.Tone) {
  case status {
    work.Active -> #(0, page.Active)
    work.Blocked -> #(1, page.Warning)
    work.Open -> #(2, page.Plain)
    work.Done -> #(3, page.Muted)
    work.Cancelled -> #(4, page.Muted)
  }
}

fn rank(item: work.Item) -> Int {
  status_style(item.status).0
}

fn row(item: work.Item) -> page.Row {
  page.Row(
    int.to_string(item.id),
    item.title,
    work.status_name(item.status),
    status_style(item.status).1,
  )
}

fn summary(items: List(work.Item)) -> String {
  [work.Active, work.Blocked, work.Open, work.Done]
  |> list.filter_map(fn(status) {
    case list.count(items, fn(item) { item.status == status }) {
      0 -> Error(Nil)
      count -> Ok(int.to_string(count) <> " " <> work.status_name(status))
    }
  })
  |> string.join(" · ")
}

fn applied(
  verb: String,
  op: Result(work.Item, work.Error),
) -> Result(#(String, work.Item), String) {
  op |> result.map(fn(item) { #(verb, item) }) |> result.map_error(describe)
}

fn change(
  store: work.Store,
  cwd: String,
  ctx: Context,
  action: String,
  details: String,
) -> Result(command.Outcome, String) {
  use #(verb, item) <- result.try(case action {
    "add" -> applied("added", work.create(store, cwd, details, "", None))
    "edit" -> {
      use #(current, title) <- result.try(target(store, cwd, details))
      applied(
        "renamed",
        work.update(store, cwd, work.Item(..current, title: title)),
      )
    }
    "status" -> {
      use #(current, name) <- result.try(target(store, cwd, details))
      use status <- result.try(
        work.parse_status(name) |> result.map_error(describe),
      )
      applied(
        "marked " <> name,
        work.update(store, cwd, work.Item(..current, status: status)),
      )
    }
    "remove" -> {
      use #(current, _) <- result.try(target(store, cwd, details))
      applied("removed", work.delete(store, cwd, current.id, current.revision))
    }
    _ ->
      Error("unknown action " <> action <> "; use add, edit, status, or remove")
  })
  let label = "#" <> int.to_string(item.id) <> " · " <> item.title
  let queued =
    ctx.state(Note(
      "work",
      verb <> " " <> label,
      "<system-note>The user "
        <> verb
        <> " work item "
        <> label
        <> " (status "
        <> work.status_name(item.status)
        <> ") in the shared work ledger.</system-note>",
    ))
  Ok(
    Data(
      json.object([
        #("item", work.to_json(item)),
        #(
          "message",
          json.string(
            verb
            <> " "
            <> label
            <> case queued {
              Ok(_) -> "; the agent will be told"
              Error(error) -> "; could not tell the agent: " <> error
            },
          ),
        ),
      ]),
    ),
  )
}

/// `<id> [rest]`: the current item and whatever follows its id.
fn target(
  store: work.Store,
  cwd: String,
  details: String,
) -> Result(#(work.Item, String), String) {
  let #(first, rest) = page.split(details)
  use id <- result.try(
    int.parse(string.replace(first, "#", ""))
    |> result.replace_error("expected a work item id, got " <> first),
  )
  use item <- result.try(work.get(store, cwd, id) |> result.map_error(describe))
  Ok(#(item, string.trim(rest)))
}

fn describe(error: work.Error) -> String {
  case error {
    work.Invalid(message) -> message
    work.NotFound -> "no such work item"
    work.Conflict -> "the item changed meanwhile; list the ledger and retry"
    work.Storage(message) -> message
  }
}
