//// Resource bindings for the built-in human commands. The model command
//// implementations remain trusted calls through the session bridge.

import albedo/harness/client_api as client
import gleam/http.{Get, Patch, Post}
import gleam/json
import gleam/list
import gleam/option.{None, Some}

fn object_schema(required: List(String)) -> json.Json {
  json.object([
    #("type", json.string("object")),
    #("required", json.array(required, json.string)),
  ])
}

fn field(
  name: String,
  label: String,
  required: Bool,
  choices: List(String),
  description: String,
) -> client.Field {
  client.Field(
    name,
    label,
    case choices {
      [] -> "text"
      _ -> "choice"
    },
    required,
    json.null(),
    list.map(choices, fn(value) { #(json.string(value), value) }),
    description,
    None,
  )
}

fn configuration_read(slash_name: String) -> client.Command {
  client.Command(
    slash_name,
    client.Read,
    [],
    client.Operation(
      "getSession",
      Get,
      "/sessions/{session_id}",
      [#("session_id", client.Session("/id"))],
      [#("view", client.Literal(json.string("configuration")))],
      [],
      [],
      object_schema(["id", "model", "effort", "revision"]),
      Some(200),
    ),
  )
}

fn configuration_edit(
  slash_name: String,
  fields: List(client.Field),
  body: List(#(String, client.Binding)),
) -> client.Command {
  client.Command(
    slash_name,
    client.Mutation,
    fields,
    client.Operation(
      "patchSession",
      Patch,
      "/sessions/{session_id}",
      [#("session_id", client.Session("/id"))],
      [#("view", client.Literal(json.string("configuration")))],
      [#("If-Match", client.Session("/configuration_resource/etag"))],
      body,
      object_schema(["resource", "session", "move"]),
      Some(200),
    ),
  )
}

pub fn commands() -> List(client.Command) {
  [
    configuration_read("/model"),
    configuration_edit(
      "/model",
      [
        field("model", "Model", True, [], "Select a model for this session."),
        field(
          "provider_profile",
          "Provider profile",
          False,
          [],
          "Select a saved profile when changing providers.",
        ),
        field(
          "effort",
          "Reasoning effort",
          False,
          [],
          "Choose a level supported by this model.",
        ),
      ],
      [
        #("/model", client.Form("/model")),
        #("/provider_profile", client.Form("/provider_profile")),
        #("/effort", client.Form("/effort")),
      ],
    ),
    configuration_read("/effort"),
    configuration_edit(
      "/effort",
      [
        field(
          "effort",
          "Reasoning effort",
          True,
          [],
          "Choose a level supported by this model.",
        ),
      ],
      [#("/effort", client.Form("/effort"))],
    ),
    client.Command(
      "/context",
      client.Read,
      [],
      client.Operation(
        "getContext",
        Get,
        "/sessions/{session_id}/context",
        [#("session_id", client.Session("/id"))],
        [],
        [],
        [],
        object_schema(["state", "snapshot_id", "sections"]),
        Some(200),
      ),
    ),
    client.Command(
      "/reload",
      client.Mutation,
      [
        client.Field(
          "target",
          "Reload",
          "choice",
          False,
          json.string("both"),
          [
            #(json.string("session"), "Session composition"),
            #(json.string("models"), "Model catalogs"),
            #(json.string("both"), "Both"),
          ],
          "Apply saved session choices or refetch model catalogs.",
          None,
        ),
      ],
      client.Operation(
        "reloadSession",
        Post,
        "/sessions/{session_id}/reload",
        [#("session_id", client.Session("/id"))],
        [],
        [],
        [#("/target", client.Form("/target"))],
        object_schema(["session", "models"]),
        Some(200),
      ),
    ),
    client.Command(
      "/compact",
      client.Mutation,
      [
        field(
          "strategy",
          "Compaction strategy",
          False,
          [],
          "Omit to use the selected strategy.",
        ),
      ],
      client.Operation(
        "compactSession",
        Post,
        "/sessions/{session_id}/compaction",
        [#("session_id", client.Session("/id"))],
        [],
        [],
        [#("/strategy", client.Form("/strategy"))],
        object_schema([
          "selection_applied",
          "effective_strategy",
          "state",
          "observation",
          "failure",
        ]),
        Some(200),
      ),
    ),
    client.Command(
      "/raise-cap",
      client.Read,
      [],
      client.Operation(
        "getModels",
        Get,
        "/models",
        [],
        [#("provider_profile", client.Session("/provider_profile"))],
        [],
        [],
        object_schema(["items", "next"]),
        Some(200),
      ),
    ),
  ]
}
