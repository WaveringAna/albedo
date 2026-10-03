//// Protocol 3 catalog encoding from native discovery facts.

import albedo/daemon/http_api
import albedo/daemon/session_catalog
import albedo/harness/client_api
import albedo/harness/command
import albedo/harness/runtime
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/result

pub fn encode(candidate: session_catalog.Candidate) -> json.Json {
  json.object([
    #("id", json.string(candidate.id)),
    #("kind", json.string(candidate.kind)),
    #("title", json.string(candidate.title)),
    #("description", json.string(candidate.description)),
    #("source", json.string(candidate.source)),
    #("resolved_source", json.nullable(candidate.resolved_source, json.string)),
    #("preference_key", json.nullable(candidate.preference_key, json.string)),
    #("valid", json.bool(candidate.valid)),
    #("eligible", json.bool(candidate.eligible)),
    #("effective_enabled", json.bool(candidate.effective_enabled)),
    #(
      "global_preference",
      json.nullable(candidate.global_preference, json.bool),
    ),
    #("session_override", json.nullable(candidate.session_override, json.bool)),
    #("shadowed_by", json.nullable(candidate.shadowed_by, json.string)),
    #("dependencies", json.array(candidate.dependencies, json.string)),
    #(
      "quarantined",
      json.bool(
        option.then(candidate.metadata, fn(metadata) { metadata.quarantined })
        != None,
      ),
    ),
    #(
      "diagnostic",
      json.nullable(candidate.diagnostic, http_api.reason(
        "candidate_unavailable",
        _,
      )),
    ),
    #(
      "extension",
      json.nullable(candidate.metadata, fn(summary) {
        json.object([
          #("context", json.bool(summary.context)),
          #("tools", json.array(summary.tools, json.string)),
          #("python_modules", json.array(summary.python_modules, json.string)),
          #("plugins", json.array(summary.plugins, json.string)),
        ])
      }),
    ),
  ])
}

fn argument(argument: command.Argument) -> json.Json {
  client_api.field(client_api.Field(
    argument.name,
    argument.name,
    case argument.choices {
      [] -> "text"
      _ -> "choice"
    },
    argument.required,
    json.null(),
    list.map(argument.choices, fn(value) { #(json.string(value), value) }),
    argument.description,
    None,
  ))
}

pub fn commands(observed: runtime.CatalogObservation) -> List(json.Json) {
  let declared =
    observed.client_commands
    |> list.filter_map(fn(entry) {
      use command <- result.map(
        list.find(observed.commands, fn(command) {
          command.0 == entry.0 && command.1.name == entry.1.slash_name
        }),
      )
      let command = command.1
      json.object([
        #(
          "id",
          json.string(
            entry.0 <> ":" <> entry.1.slash_name <> ":" <> entry.1.operation.id,
          ),
        ),
        #("slash_name", json.string(command.name)),
        #("description", json.string(command.description)),
        #("arguments", json.array(entry.1.arguments, client_api.field)),
        #(
          "caller_permissions",
          json.array(
            case command.model_callable {
              True -> ["human", "model"]
              False -> ["human"]
            },
            json.string,
          ),
        ),
        #(
          "delivery",
          json.string(case entry.1.delivery {
            client_api.Read -> "read"
            client_api.Mutation -> "mutation"
          }),
        ),
        #("operation", client_api.operation(entry.1.operation)),
      ])
    })
  let inputs =
    observed.commands
    |> list.filter(fn(entry) { entry.1.user_turn })
    |> list.map(fn(entry) {
      let id = entry.0 <> ":" <> entry.1.name
      json.object([
        #("id", json.string(id)),
        #("slash_name", json.string(entry.1.name)),
        #("description", json.string(entry.1.description)),
        #("arguments", json.array(entry.1.arguments, argument)),
        #(
          "caller_permissions",
          json.array(
            case entry.1.model_callable {
              True -> ["human", "model"]
              False -> ["human"]
            },
            json.string,
          ),
        ),
        #("delivery", json.string("input")),
        #("command_id", json.string(entry.1.name)),
      ])
    })
  list.append(declared, inputs)
}
