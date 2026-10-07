//// Protocol 3 catalog encoding from native discovery facts.

import albedo/daemon/http_api
import albedo/harness/client_api
import albedo/harness/command
import albedo/harness/extension
import albedo/harness/runtime
import albedo/harness/runtime/catalog as session_catalog
import gleam/json
import gleam/list
import gleam/option.{None}

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
    |> list.map(fn(entry) {
      client_command(
        entry.0,
        entry.1,
        entry.2.description,
        entry.2.model_callable,
      )
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

fn client_command(
  owner: String,
  binding: client_api.Command,
  description: String,
  model_callable: Bool,
) -> json.Json {
  json.object([
    #(
      "id",
      json.string(
        owner <> ":" <> binding.slash_name <> ":" <> binding.operation.id,
      ),
    ),
    #("slash_name", json.string(binding.slash_name)),
    #("description", json.string(description)),
    #("arguments", json.array(binding.arguments, client_api.field)),
    #(
      "caller_permissions",
      json.array(
        case model_callable {
          True -> ["human", "model"]
          False -> ["human"]
        },
        json.string,
      ),
    ),
    #(
      "delivery",
      json.string(case binding.delivery {
        client_api.Read -> "read"
        client_api.Mutation -> "mutation"
      }),
    ),
    #("operation", client_api.operation(binding.operation)),
  ])
}

/// Static human HTTP bindings are readable before any composition is prepared.
pub fn native_commands(
  installed: List(extension.Extension),
  discovery: session_catalog.Snapshot,
) -> List(json.Json) {
  installed
  |> list.filter(fn(item) {
    list.any(discovery.candidates, fn(candidate) {
      candidate.kind == "extension"
      && candidate.id == item.name
      && candidate.valid
      && candidate.eligible
      && candidate.effective_enabled
    })
  })
  |> list.flat_map(fn(item) {
    item.plugins
    |> list.flat_map(fn(plugin) {
      case plugin {
        extension.ClientPlugin(bindings) ->
          list.map(bindings, fn(binding) {
            client_command(item.name, binding, item.description, False)
          })
        _ -> []
      }
    })
  })
}
