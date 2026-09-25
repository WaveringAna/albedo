import albedo/harness/command.{
  type Command, Argument, Command, Data, ModelCall, UserCall,
}
import albedo/harness/extensions/webhooks/ledger as hooks
import gleam/dict
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string

pub fn command(db: hooks.Store, session: String) -> Command {
  Command(
    "/webhooks",
    "Manage signed webhooks targeting this session. Agent management requires the human opt-in on the Webhooks screen. Generated secrets are returned only on create or rotate.",
    [
      Argument(
        "action",
        "list, create, create_with_secret, rotate, rotate_with_secret, signature, enable, disable, delete",
        False,
        [],
      ),
      Argument(
        "details",
        "hook name or id, then a secret (create/rotate_with_secret) or a header and prefix (signature)",
        False,
        [],
      ),
    ],
    True,
    False,
    False,
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
        "create_in", UserCall -> {
          let #(target_session, rest) = split(details)
          let #(name, supplied) = split(rest)
          let secret = case supplied {
            "" -> None
            _ -> Some(supplied)
          }
          hooks.create(db, actor, target_session, name, secret)
          |> result.map(fn(provisioned) { receipt(provisioned, secret == None) })
          |> result.map_error(describe)
        }
        "create_in", ModelCall ->
          Error("an agent can only create hooks for its own session")
        "signature", _ -> {
          let #(id, setting) = split(details)
          let #(header, prefix) = split(setting)
          use hook <- result.try(target(db, actor, session, id))
          hooks.configure(
            db,
            actor,
            hook.session,
            id,
            hook.revision,
            header,
            prefix,
          )
          |> result.map(fn(updated) { Data(hooks.to_json(updated)) })
          |> result.map_error(describe)
        }
        "rotate", _ | "rotate_with_secret", _ -> {
          let #(id, supplied) = split(details)
          let secret = case action {
            "rotate_with_secret" -> Some(supplied)
            _ -> None
          }
          use hook <- result.try(target(db, actor, session, id))
          hooks.rotate(db, actor, hook.session, id, hook.revision, secret)
          |> result.map(fn(provisioned) {
            receipt(provisioned, action == "rotate")
          })
          |> result.map_error(describe)
        }
        "enable", _ | "disable", _ | "delete", _ -> {
          use hook <- result.try(target(db, actor, session, details))
          let result = case action {
            "delete" ->
              hooks.delete(db, actor, hook.session, details, hook.revision)
            _ ->
              hooks.set_enabled(
                db,
                actor,
                hook.session,
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

/// The hook an id names. A human may manage any session's hooks; an agent
/// only its own.
fn target(
  db: hooks.Store,
  actor: hooks.Actor,
  session: String,
  id: String,
) -> Result(hooks.Hook, String) {
  case actor {
    hooks.Human -> hooks.find(db, id)
    hooks.Agent(_) -> hooks.get(db, actor, session, id)
  }
  |> result.map_error(describe)
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

/// What the Webhooks screen shows: every session's hooks with their inboxes,
/// and whether this session's agent may manage its own. Secrets are never
/// listed.
fn listing(
  db: hooks.Store,
  session: String,
) -> Result(command.Outcome, String) {
  use items <- result.try(hooks.list_all(db) |> result.map_error(describe))
  use agent <- result.try(
    hooks.agent_management(db, session) |> result.map_error(describe),
  )
  use entries <- result.try(
    list.try_map(items, fn(hook) {
      use queued <- result.try(
        hooks.pending_count(db, hook.session, hook.id)
        |> result.map_error(describe),
      )
      use failure <- result.try(
        hooks.last_failure(db, hook.session, hook.id)
        |> result.map_error(describe),
      )
      Ok(
        json.object([
          #("hook", hooks.to_json(hook)),
          #("queued", json.int(queued)),
          #("deferred", json.nullable(failure, json.string)),
        ]),
      )
    }),
  )
  Ok(
    Data(
      json.object([
        #("session", json.string(session)),
        #("agentManagement", json.bool(agent)),
        #("hooks", json.preprocessed_array(entries)),
      ]),
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
