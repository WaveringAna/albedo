import albedo/daemon/store
import albedo/harness/client_api
import albedo/harness/command.{Argument, Command, Data}
import albedo/harness/extension
import albedo/harness/extensions/schedule/ledger
import albedo/harness/extensions/schedule/migrations/revision
import albedo/harness/page
import gleam/http
import gleam/int
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

import albedo/harness/extensions/schedule/service

pub fn extension() -> extension.Extension {
  extension.Extension(
    "schedule",
    "Durable session prompts, recurring reminders, and idle heartbeats.",
    ["python"],
    [
      extension.ClientPlugin([
        client_api.Command(
          "/schedule",
          client_api.Read,
          [],
          client_api.Operation(
            "listSchedule",
            http.Get,
            "/extensions/schedule/jobs",
            [],
            [#("session_id", client_api.Session("/id"))],
            [],
            [],
            json.object([]),
            Some(200),
          ),
        ),
      ]),
      extension.MigrationPlugin(extension.SchemaMigration(revision.apply)),
      extension.ServicePlugin(extension.Service(
        fn(_, _) { extension.Admission(extension.DaemonToken, 65_536) },
        service.handle,
      )),
      extension.CleanPlugin(fn(db, session) {
        store.forget_session(db, ["schedules"], session)
      }),
      extension.ManagedPlugin(fn(db, session, _) {
        Ok(
          extension.Managed(..extension.empty(), commands: [
            command(db, session),
          ]),
        )
      }),
    ],
    ledger.initialise,
  )
}

fn command(db: store.Store, session: String) -> command.Command {
  Command(
    "/schedule",
    "List or manage scheduled prompts in this session: add <in:seconds|every:seconds> <prompt>, heartbeat <every:seconds> <prompt>, edit <id> <in:seconds|every:seconds> <prompt>, delete <id>. Intervals are 60–31536000 seconds. Heartbeats skip busy sessions; recurring prompts queue behind a running turn.",
    [
      Argument("action", "list, add, heartbeat, edit, delete", False, []),
      Argument("details", "schedule or id and prompt", False, []),
    ],
    True,
    False,
    False,
    None,
    fn(_, _, args) {
      let #(action, details) = page.args(args, "list")
      use value <- result.try(case action {
        "list" ->
          ledger.list(db, session)
          |> result.map(fn(jobs) { json.array(jobs, ledger.to_json) })
        "delete" -> {
          use id <- result.try(parse_id(details))
          ledger.delete(db, session, id)
          |> result.map(fn(deleted) {
            json.object([#("deleted", json.bool(deleted))])
          })
        }
        "add" | "heartbeat" -> {
          use #(kind, delay, every, prompt) <- result.try(parse(
            details,
            action == "heartbeat",
          ))
          ledger.save(db, session, None, kind, prompt, delay, every)
          |> result.map(ledger.to_json)
        }
        "edit" -> {
          let #(id_text, rest) = page.split(details)
          use id <- result.try(parse_id(id_text))
          use current <- result.try(ledger.get(db, session, id))
          use #(kind, delay, every, prompt) <- result.try(parse(
            rest,
            current.kind == "heartbeat",
          ))
          ledger.save(db, session, Some(id), kind, prompt, delay, every)
          |> result.map(ledger.to_json)
        }
        _ -> Error("use list, add, heartbeat, edit, or delete")
      })
      Ok(Data(value))
    },
  )
}

fn parse_id(text: String) -> Result(Int, String) {
  int.parse(string.trim(text))
  |> result.replace_error("expected a schedule id")
}

fn parse(
  text: String,
  heartbeat: Bool,
) -> Result(#(String, Int, Option(Int), String), String) {
  let #(timing, prompt) = page.split(text)
  use #(mode, seconds_text) <- result.try(
    string.split_once(timing, ":")
    |> result.replace_error("expected in:seconds or every:seconds"),
  )
  use seconds <- result.try(
    int.parse(seconds_text)
    |> result.replace_error("seconds must be an integer"),
  )
  case seconds < 60 || seconds > 31_536_000 || string.trim(prompt) == "" {
    True -> Error("interval must be 60–31536000 seconds and prompt nonempty")
    False ->
      case mode, heartbeat {
        "in", False -> Ok(#("once", seconds, None, prompt))
        "every", True -> Ok(#("heartbeat", seconds, Some(seconds), prompt))
        "every", False -> Ok(#("recurring", seconds, Some(seconds), prompt))
        _, _ ->
          Error(
            "use in:seconds or every:seconds; heartbeat requires every:seconds",
          )
      }
  }
}
