import albedo/harness/command.{
  type Command, Argument, Command, Data, ModelCall, UserCall,
}
import albedo/harness/extensions/webhooks/ledger as hooks
import albedo/harness/page
import gleam/dict
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string

pub fn command(db: hooks.Store, session: String) -> Command {
  Command(
    "/webhooks",
    "Manage signed webhooks targeting this session. Agent management requires the human opt-in on the Webhooks page. Generated secrets are returned only on create or rotate.",
    [
      Argument(
        "action",
        "list, create, create_with_secret, rotate, rotate_with_secret, enable, disable, delete",
        False,
        [],
      ),
      Argument(
        "details",
        "hook name or id, optionally followed by a secret",
        False,
        [],
      ),
    ],
    True,
    False,
    True,
    fn(_, caller, args) {
      let action = dict.get(args, "action") |> result.unwrap("")
      let details =
        dict.get(args, "details") |> result.unwrap("") |> string.trim
      let actor = case caller {
        UserCall -> hooks.Human
        ModelCall -> hooks.Agent(session)
      }
      case action, caller {
        "", UserCall -> listing(db, session)
        "", ModelCall | "list", ModelCall ->
          hooks.list(db, actor, session)
          |> result.map(fn(items) { Data(json.array(items, hooks.to_json)) })
          |> result.map_error(describe)
        "list", UserCall -> listing(db, session)
        "agent_on", UserCall | "agent_off", UserCall -> {
          hooks.allow_agent(db, session, action == "agent_on")
          |> result.map(fn(_) {
            done("Agent webhook management " <> if_on(action == "agent_on"))
          })
          |> result.map_error(describe)
        }
        "agent_on", ModelCall | "agent_off", ModelCall ->
          Error("only a human can change the agent permission")
        "create", _ | "create_with_secret", _ -> {
          let #(name, supplied) = case action {
            "create_with_secret" -> split(details)
            _ -> #(details, "")
          }
          let secret = case action {
            "create_with_secret" -> Some(supplied)
            _ -> None
          }
          hooks.create(db, actor, session, name, secret)
          |> result.map(fn(provisioned) {
            receipt(provisioned, action == "create")
          })
          |> result.map_error(describe)
        }
        "header", _ | "prefix", _ -> {
          let #(id, setting) = split(details)
          use hook <- result.try(
            hooks.get(db, actor, session, id) |> result.map_error(describe),
          )
          let #(header, prefix) = case action {
            "header" -> #(setting, hook.signature_prefix)
            _ -> #(hook.signature_header, setting)
          }
          hooks.configure(db, actor, session, id, hook.revision, header, prefix)
          |> result.map(fn(updated) { Data(hooks.to_json(updated)) })
          |> result.map_error(describe)
        }
        "rotate", _ | "rotate_with_secret", _ -> {
          let #(id, supplied) = split(details)
          let secret = case action {
            "rotate_with_secret" -> Some(supplied)
            _ -> None
          }
          use hook <- result.try(
            hooks.get(db, actor, session, id) |> result.map_error(describe),
          )
          hooks.rotate(db, actor, session, id, hook.revision, secret)
          |> result.map(fn(provisioned) {
            receipt(provisioned, action == "rotate")
          })
          |> result.map_error(describe)
        }
        "enable", _ | "disable", _ | "delete", _ -> {
          use hook <- result.try(
            hooks.get(db, actor, session, details) |> result.map_error(describe),
          )
          let result = case action {
            "delete" -> hooks.delete(db, actor, session, details, hook.revision)
            _ ->
              hooks.set_enabled(
                db,
                actor,
                session,
                details,
                hook.revision,
                action == "enable",
              )
          }
          result
          |> result.map(fn(updated) { Data(hooks.to_json(updated)) })
          |> result.map_error(describe)
        }
        _, _ -> Error("unknown webhook action")
      }
    },
  )
}

fn split(text: String) -> #(String, String) {
  string.split_once(text, " ") |> result.unwrap(#(text, ""))
}

fn if_on(enabled: Bool) -> String {
  case enabled {
    True -> "on"
    False -> "off"
  }
}

fn done(message: String) -> command.Outcome {
  Data(json.object([#("message", json.string(message))]))
}

fn receipt(provisioned: hooks.Provisioned, generated: Bool) -> command.Outcome {
  let fields = [
    #("hook", hooks.to_json(provisioned.hook)),
    #(
      "message",
      json.string(
        "/webhooks/"
        <> provisioned.hook.id
        <> case generated {
          True -> " · secret (copy now): " <> provisioned.secret
          False -> " · secret saved"
        },
      ),
    ),
  ]
  Data(
    json.object(case generated {
      True -> [#("secret", json.string(provisioned.secret)), ..fields]
      False -> fields
    }),
  )
}

fn listing(
  db: hooks.Store,
  session: String,
) -> Result(command.Outcome, String) {
  use items <- result.try(
    hooks.list(db, hooks.Human, session) |> result.map_error(describe),
  )
  use agent <- result.try(
    hooks.agent_management(db, session) |> result.map_error(describe),
  )
  use rows <- result.try(
    list.try_map(items, fn(hook) {
      use waiting <- result.try(
        hooks.pending_count(db, session, hook.id) |> result.map_error(describe),
      )
      use failure <- result.try(
        hooks.last_failure(db, session, hook.id) |> result.map_error(describe),
      )
      let badge =
        if_on(hook.enabled)
        <> case waiting {
          0 -> ""
          n -> " · " <> int.to_string(n) <> " queued"
        }
      Ok(
        page.Row(
          hook.id,
          hook.name
            <> " · /webhooks/"
            <> hook.id
            <> case failure {
            None -> ""
            Some(reason) -> " · delivery deferred: " <> reason
          },
          badge,
          case hook.enabled {
            True -> page.Active
            False -> page.Muted
          },
        ),
      )
    }),
  )
  Ok(
    Data(
      page.to_json(page.Document(
        "webhooks · this session",
        "POST /webhooks/<id> · HMAC-SHA256 · agent management " <> if_on(agent),
        "no hooks yet · a adds a signed endpoint",
        rows,
        [
          page.Action(
            "a",
            "add with generated secret",
            "create",
            False,
            page.Text("hook name", False),
            False,
          ),
          page.Action(
            "p",
            "add with your secret",
            "create_with_secret",
            False,
            page.Secret("name then secret (space separated)"),
            False,
          ),
          page.Action(
            "r",
            "rotate generated secret",
            "rotate",
            True,
            page.NoInput,
            True,
          ),
          page.Action(
            "k",
            "rotate to your secret",
            "rotate_with_secret",
            True,
            page.Secret("replacement secret"),
            True,
          ),
          page.Action(
            "h",
            "signature header",
            "header",
            True,
            page.Text("header name", False),
            False,
          ),
          page.Action(
            "f",
            "signature prefix",
            "prefix",
            True,
            page.Text("prefix (e.g. sha256=)", False),
            False,
          ),
          page.Action("e", "enable", "enable", True, page.NoInput, False),
          page.Action("d", "disable", "disable", True, page.NoInput, False),
          page.Action("x", "delete", "delete", True, page.NoInput, True),
          page.Action(
            "m",
            "allow agent to manage",
            "agent_on",
            False,
            page.NoInput,
            False,
          ),
          page.Action(
            "n",
            "disallow agent management",
            "agent_off",
            False,
            page.NoInput,
            False,
          ),
        ],
        None,
      )),
    ),
  )
}

fn describe(error: hooks.Error) -> String {
  case error {
    hooks.Invalid(message) -> message
    hooks.Denied ->
      "agent webhook management is disabled or this session does not own the hook"
    hooks.NotFound -> "webhook not found"
    hooks.Conflict -> "webhook changed; reload and retry"
    hooks.Unauthorized -> "invalid webhook signature"
    hooks.Overloaded -> "webhook inbox full"
    hooks.Storage(message) -> message
  }
}
