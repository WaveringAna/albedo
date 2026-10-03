//// Protocol 3 configuration projections. Revisions and preferences come from
//// the durable session owner; these encoders perform no mutation or lookup.

import albedo/daemon/http_api
import albedo/daemon/session_configuration
import gleam/dict
import gleam/dynamic/decode
import gleam/http/request
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

pub type Change {
  Edit(session_configuration.Patch)
  Move(workspace: String, family_revision: String)
}

/// Keep absent and explicit null distinct: merge patch uses null to clear an
/// override, while an omitted field preserves its current value.
fn optional_edit(
  key: String,
  decoder: decode.Decoder(a),
) -> decode.Decoder(Option(a)) {
  decode.optional_field(key, None, decode.map(decoder, Some), decode.success)
}

fn selection_patch() -> decode.Decoder(session_configuration.SelectionPatch) {
  let choices =
    decode.optional(decode.dict(
      http_api.bounded_string(512, True),
      decode.optional(decode.bool),
    ))
  http_api.object(["extensions", "skills", "instructions", "mcp"], {
    use extensions <- decode.then(optional_edit("extensions", choices))
    use skills <- decode.then(optional_edit("skills", choices))
    use instructions <- decode.then(optional_edit("instructions", choices))
    use mcp <- decode.then(optional_edit("mcp", choices))
    decode.success(session_configuration.SelectionPatch(
      extensions,
      skills,
      instructions,
      mcp,
    ))
  })
}

pub fn change(
  req: request.Request(BitArray),
) -> Result(Change, http_api.Failure) {
  use raw <- result.try(http_api.body(
    req,
    [
      "name",
      "provider_profile",
      "model",
      "effort",
      "preferences",
      "selection",
      "catalog_revision",
      "workspace",
      "family_revision",
    ],
    decode.dynamic,
  ))
  let move =
    decode.run(raw, decode.field("workspace", decode.dynamic, decode.success))
  let decoder = case move {
    Ok(_) ->
      http_api.object(["workspace", "family_revision"], {
        use workspace <- decode.field(
          "workspace",
          http_api.bounded_string(4096, True),
        )
        use family_revision <- decode.field(
          "family_revision",
          http_api.bounded_string(512, True),
        )
        decode.success(Move(workspace, family_revision))
      })
    Error(_) ->
      http_api.object(
        [
          "name",
          "provider_profile",
          "model",
          "effort",
          "preferences",
          "selection",
          "catalog_revision",
        ],
        {
          use name <- decode.then(optional_edit(
            "name",
            decode.optional(http_api.bounded_string(4096, False)),
          ))
          use provider <- decode.then(optional_edit(
            "provider_profile",
            http_api.bounded_string(512, True),
          ))
          use model <- decode.then(optional_edit(
            "model",
            http_api.bounded_string(512, True),
          ))
          use effort <- decode.then(optional_edit(
            "effort",
            decode.optional(http_api.bounded_string(100, False)),
          ))
          use preferences <- decode.optional_field(
            "preferences",
            #(None, None),
            http_api.object(["pinned", "archived"], {
              use pinned <- decode.then(optional_edit("pinned", decode.bool))
              use archived <- decode.then(optional_edit("archived", decode.bool))
              decode.success(#(pinned, archived))
            }),
          )
          use selection <- decode.optional_field(
            "selection",
            session_configuration.SelectionPatch(None, None, None, None),
            selection_patch(),
          )
          use catalog_revision <- decode.then(optional_edit(
            "catalog_revision",
            http_api.bounded_string(512, True),
          ))
          decode.success(
            Edit(session_configuration.Patch(
              name,
              provider,
              model,
              effort,
              preferences.0,
              preferences.1,
              selection,
              catalog_revision,
            )),
          )
        },
      )
  }
  decode.run(raw, decoder)
  |> result.map_error(fn(_) {
    http_api.invalid(
      "configuration fields have invalid values or unknown fields",
    )
  })
}

pub fn revision(value: session_configuration.Configuration) -> String {
  "config-" <> value.id <> "-" <> int.to_string(value.revision)
}

pub fn family_revision(value: session_configuration.Configuration) -> String {
  "family-"
  <> value.family.root_id
  <> "-"
  <> int.to_string(value.family.revision)
}

pub fn encode(value: session_configuration.Configuration) -> json.Json {
  json.object([
    #("id", json.string(value.id)),
    #("name", json.string(session_configuration.display_name(value))),
    #("workspace", json.string(value.workspace)),
    #("provider_profile", case value.provider_profile {
      "" -> json.null()
      profile -> json.string(profile)
    }),
    #("model", case value.model {
      "" -> json.null()
      model -> json.string(model)
    }),
    #("effort", json.nullable(value.effort, json.string)),
    #("preferences", preferences(value.preferences, False)),
    #("selection", selection(value.selection)),
    #("revision", json.string(revision(value))),
    #("family_revision", json.string(family_revision(value))),
  ])
}

pub fn etag(value: session_configuration.Configuration) -> String {
  http_api.etag(encode(value) |> json.to_string)
}

pub fn resource(value: session_configuration.Configuration) -> json.Json {
  json.object([
    #("url", json.string("/sessions/" <> value.id <> "?view=configuration")),
    #("etag", json.string(etag(value))),
    #("value", encode(value)),
  ])
}

pub fn preferences(
  value: session_configuration.Preferences,
  include_opens: Bool,
) -> json.Json {
  let fields = [
    #("pinned", json.bool(value.pinned)),
    #("pin_order", json.nullable(value.pin_order, json.int)),
    #("archived", json.bool(value.archived)),
  ]
  json.object(case include_opens {
    True -> [#("opens", json.int(value.opens)), ..fields]
    False -> fields
  })
}

pub fn selection(value: session_configuration.Selection) -> json.Json {
  let choices = fn(values) {
    json.object(
      dict.to_list(values)
      |> list.map(fn(choice) { #(choice.0, json.bool(choice.1)) }),
    )
  }
  json.object([
    #("extensions", choices(value.extensions)),
    #("skills", choices(value.skills)),
    #("instructions", choices(value.instructions)),
    #("mcp", choices(value.mcp)),
  ])
}
