import albedo/harness/command.{
  type Command, Argument, Command, Data, ModelCall, UserCall,
}
import albedo/harness/extensions/webhooks/ledger as hooks
import albedo/harness/page
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
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
    None,
    fn(_, caller, args) {
      let #(action, details) = page.args(args, "")
      let actor = case caller {
        UserCall -> hooks.Human
        ModelCall -> hooks.Agent(session)
      }
      case action, caller {
        "", UserCall | "list", UserCall -> listing(db, session)
        "", ModelCall | "list", ModelCall ->
          check(hooks.list(db, actor, session))
          |> result.map(fn(items) { Data(json.array(items, hooks.to_json)) })
        "agent_on", UserCall | "agent_off", UserCall -> {
          let on = action == "agent_on"
          check(hooks.allow_agent(db, session, on))
          |> result.map(fn(_) { done("Agent webhook management " <> if_on(on)) })
        }
        "agent_on", ModelCall | "agent_off", ModelCall ->
          Error("only a human can change the agent permission")
        "create", _ | "create_with_secret", _ -> {
          let #(name, secret) = secret_args(action, details)
          check(hooks.create(db, actor, session, name, secret))
          |> result.map(fn(p) { receipt(p, secret == None) })
        }
        "create_in", UserCall -> {
          let #(target_session, rest) = page.split(details)
          let #(name, supplied) = page.split(rest)
          let secret = case supplied {
            "" -> None
            _ -> Some(supplied)
          }
          check(hooks.create(db, actor, target_session, name, secret))
          |> result.map(fn(p) { receipt(p, secret == None) })
        }
        "create_in", ModelCall ->
          Error("an agent can only create hooks for its own session")
        "signature", _ -> {
          let #(id, setting) = page.split(details)
          let #(header, prefix) = page.split(setting)
          use hook <- result.try(target(db, actor, session, id))
          check(hooks.configure(
            db,
            actor,
            hook.session,
            id,
            hook.revision,
            header,
            prefix,
          ))
          |> result.map(fn(updated) { Data(hooks.to_json(updated)) })
        }
        "rotate", _ | "rotate_with_secret", _ -> {
          let #(id, secret) = secret_args(action, details)
          use hook <- result.try(target(db, actor, session, id))
          check(hooks.rotate(db, actor, hook.session, id, hook.revision, secret))
          |> result.map(fn(p) { receipt(p, secret == None) })
        }
        "enable", _ | "disable", _ | "delete", _ -> {
          use hook <- result.try(target(db, actor, session, details))
          case action {
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
          |> check
          |> result.map(fn(updated) { Data(hooks.to_json(updated)) })
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
  |> check
}

fn with_secret(action: String) -> Bool {
  string.ends_with(action, "_with_secret")
}

fn secret_args(action: String, details: String) -> #(String, Option(String)) {
  case with_secret(action) {
    True -> {
      let #(item, supplied) = page.split(details)
      #(item, Some(supplied))
    }
    False -> #(details, None)
  }
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
  use items <- result.try(check(hooks.list_all(db)))
  use agent <- result.try(check(hooks.agent_management(db, session)))
  use entries <- result.try(
    list.try_map(items, fn(hook) {
      use queued <- result.try(
        check(hooks.pending_count(db, hook.session, hook.id)),
      )
      use failure <- result.try(
        check(hooks.last_failure(db, hook.session, hook.id)),
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

fn check(op: Result(a, hooks.Error)) -> Result(a, String) {
  result.map_error(op, describe)
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
