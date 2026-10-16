//// The `extension_settings` group: every declared section of extensions.json,
//// the daemon's own and each installed extension's, with its saved values,
//// and the one way to change them. A save keeps whatever else the section
//// or file holds, and lands only when the section's owner accepts its whole
//// resulting section.

import albedo/harness/settings.{
  type Declaration, type Field, Capped, Text, Whole,
}
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

/// A declared section, with the description the group shows for it: its
/// extension's, or the daemon's own for a section the daemon declares.
pub type Declared {
  Declared(description: String, declaration: Declaration)
}

/// A refusal as the settings boundary reports it: status, code, detail.
pub type Refusal =
  #(Int, String, String)

@external(erlang, "albedo_settings_read", "json_null")
fn null() -> Dynamic

fn object(fields: List(#(String, Dynamic))) -> Dynamic {
  dynamic.properties(
    list.map(fields, fn(field) { #(dynamic.string(field.0), field.1) }),
  )
}

fn fields_of(value: Dynamic) -> Result(Dict(String, Dynamic), Nil) {
  decode.run(value, decode.dict(decode.string, decode.dynamic))
  |> result.replace_error(Nil)
}

/// The group's value from extensions.json as `document` holds it.
pub fn project(declared: List(Declared), document: Dynamic) -> Dynamic {
  let sections = fields_of(document) |> result.unwrap(dict.new())
  object([
    #(
      "sections",
      dynamic.list(
        list.map(declared, fn(entry) {
          let saved = dict.get(sections, entry.declaration.section)
          let values =
            saved |> result.try(fields_of) |> result.unwrap(dict.new())
          let problem = case
            entry.declaration.accept(
              saved |> result.unwrap(dynamic.properties([])),
            )
          {
            Ok(_) -> null()
            Error(reason) -> dynamic.string(reason)
          }
          object([
            #("name", dynamic.string(entry.declaration.section)),
            #("label", dynamic.string(entry.declaration.label)),
            #(
              "category",
              dynamic.string(settings.category_name(entry.declaration.category)),
            ),
            #("description", dynamic.string(entry.description)),
            #(
              "fields",
              dynamic.list(
                list.map(entry.declaration.fields, field_value(_, values)),
              ),
            ),
            #("problem", problem),
          ])
        }),
      ),
    ),
  ])
}

fn field_value(field: Field, values: Dict(String, Dynamic)) -> Dynamic {
  let saved = dict.get(values, field.key)
  let #(kind, default, minimum, maximum, value) = case field.kind {
    Whole(default, minimum, maximum) -> #(
      "integer",
      optional(default, dynamic.int),
      dynamic.int(minimum),
      dynamic.int(maximum),
      saved_as(saved, decode.int, dynamic.int),
    )
    Text(default) -> #(
      "text",
      optional(default, dynamic.string),
      null(),
      null(),
      saved_as(saved, decode.string, dynamic.string),
    )
    Capped(default, minimum, maximum) -> #(
      "limit",
      dynamic.int(settings.limit_value(default)),
      dynamic.int(minimum),
      dynamic.int(maximum),
      saved_as(saved, decode.int, dynamic.int),
    )
  }
  object([
    #("key", dynamic.string(field.key)),
    #("label", dynamic.string(field.label)),
    #("description", dynamic.string(field.description)),
    #("kind", dynamic.string(kind)),
    #("default", default),
    #("minimum", minimum),
    #("maximum", maximum),
    #("value", value),
  ])
}

/// The saved value when it is of the kind `decoder` reads, else null; the
/// section's problem names one of the wrong kind.
fn saved_as(
  saved: Result(Dynamic, Nil),
  decoder: decode.Decoder(a),
  encode: fn(a) -> Dynamic,
) -> Dynamic {
  saved
  |> result.try(fn(raw) {
    decode.run(raw, decoder) |> result.replace_error(Nil)
  })
  |> option.from_result
  |> optional(encode)
}

fn optional(value: Option(a), encode: fn(a) -> Dynamic) -> Dynamic {
  case value {
    Some(value) -> encode(value)
    None -> null()
  }
}

/// `document` with `values` (section -> key -> value, null to unset) saved,
/// or why not. Nothing changes unless every section it touches is one its
/// owner accepts.
pub fn patch(
  declared: List(Declared),
  document: Dynamic,
  values: Dynamic,
) -> Result(Dynamic, Refusal) {
  use sections <- result.try(
    fields_of(document)
    |> result.replace_error(#(
      400,
      "invalid_settings",
      "extensions.json must contain a JSON object",
    )),
  )
  use changes <- result.try(
    decode.run(
      values,
      decode.dict(decode.string, decode.dict(decode.string, decode.dynamic)),
    )
    |> result.replace_error(invalid(
      "values must map section names to objects of settings",
    )),
  )
  use sections <- result.map(
    list.try_fold(dict.to_list(changes), sections, fn(sections, change) {
      let #(name, entries) = change
      use entry <- result.try(
        list.find(declared, fn(entry) { entry.declaration.section == name })
        |> result.replace_error(invalid("no settings section named " <> name)),
      )
      use section <- result.try(
        list.try_fold(
          dict.to_list(entries),
          dict.get(sections, name)
            |> result.try(fields_of)
            |> result.unwrap(dict.new()),
          fn(section, entry_change) {
            let #(key, value) = entry_change
            use _ <- result.try(
              list.find(entry.declaration.fields, fn(field) { field.key == key })
              |> result.replace_error(invalid(
                name <> " declares no setting " <> key,
              )),
            )
            Ok(case decode.run(value, decode.optional(decode.dynamic)) {
              Ok(None) -> dict.delete(section, key)
              _ -> dict.insert(section, key, value)
            })
          },
        ),
      )
      use _ <- result.try(
        entry.declaration.accept(object(dict.to_list(section)))
        |> result.map_error(fn(reason) { #(400, "invalid_settings", reason) }),
      )
      Ok(case dict.is_empty(section) {
        True -> dict.delete(sections, name)
        False -> dict.insert(sections, name, object(dict.to_list(section)))
      })
    }),
  )
  object(dict.to_list(sections))
}

fn invalid(detail: String) -> Refusal {
  #(400, "invalid_request", detail)
}
