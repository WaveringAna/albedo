//// Settings in `$ALBEDO_HOME/extensions.json`, one section per extension
//// and one per part of the daemon that declares its own. Each declares the
//// settings it reads (`Section`), so the daemon can list, check and save
//// them; `load` reads a section nothing declares. Credentials never appear
//// in decoder diagnostics.

import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// The longest text setting, in bytes.
pub const text_limit = 4096

/// One setting as a person sees it: the key it is saved under in its
/// section, a label, what it does, and what it accepts.
pub type Field {
  Field(key: String, label: String, description: String, kind: Kind)
}

/// What a setting accepts. A `None` default means leaving it unset has a
/// meaning of its own, which the description gives.
pub type Kind {
  /// A whole number from `minimum` to `maximum`.
  Whole(default: Option(Int), minimum: Int, maximum: Int)
  /// Text that is not blank, at most `text_limit` bytes.
  Text(default: Option(String))
  /// A whole number from `minimum` to `maximum`, or `no_limit`.
  Capped(default: Limit, minimum: Int, maximum: Int)
}

/// A cap on how many of something, or none at all.
pub type Limit {
  Limited(Int)
  Unlimited
}

/// What a `Capped` setting is saved as when it has no cap.
pub const no_limit = -1

/// A declared setting, typed: the decoder its owner reads it with and the
/// field it declares come from one value, so they cannot disagree.
pub opaque type Setting(a) {
  Setting(field: Field, decoder: decode.Decoder(a), default: a)
}

pub fn whole(
  key: String,
  label: String,
  description: String,
  default: Int,
  minimum: Int,
  maximum: Int,
) -> Setting(Int) {
  Setting(
    Field(key, label, description, Whole(Some(default), minimum, maximum)),
    decode.int,
    default,
  )
}

/// A whole number from `minimum` to `maximum`, or `no_limit` for no cap.
pub fn limit(
  key: String,
  label: String,
  description: String,
  default: Limit,
  minimum: Int,
  maximum: Int,
) -> Setting(Limit) {
  Setting(
    Field(key, label, description, Capped(default, minimum, maximum)),
    decode.map(decode.int, fn(number) {
      case number == no_limit {
        True -> Unlimited
        False -> Limited(number)
      }
    }),
    default,
  )
}

/// A whole number that may stay unset.
pub fn optional_whole(
  key: String,
  label: String,
  description: String,
  minimum: Int,
  maximum: Int,
) -> Setting(Option(Int)) {
  Setting(
    Field(key, label, description, Whole(None, minimum, maximum)),
    decode.map(decode.int, Some),
    None,
  )
}

pub fn text(
  key: String,
  label: String,
  description: String,
  default: String,
) -> Setting(String) {
  Setting(
    Field(key, label, description, Text(Some(default))),
    decode.string,
    default,
  )
}

/// Text that may stay unset.
pub fn optional_text(
  key: String,
  label: String,
  description: String,
) -> Setting(Option(String)) {
  Setting(
    Field(key, label, description, Text(None)),
    decode.map(decode.string, Some),
    None,
  )
}

pub fn field(setting: Setting(a)) -> Field {
  setting.field
}

/// Decodes `setting` from the section: its default when the key is absent
/// or null. `load_section` has checked the value against the field first.
pub fn value(
  setting: Setting(a),
  next: fn(a) -> decode.Decoder(b),
) -> decode.Decoder(b) {
  decode.optional_field(
    setting.field.key,
    setting.default,
    decode.optional(setting.decoder)
      |> decode.map(option.unwrap(_, setting.default)),
    next,
  )
}

/// The part of `/config` a section belongs to. Every section names one, so
/// settings group by what they configure rather than by who declares them.
pub type Category {
  /// What `web_search` asks and where it asks it.
  WebSearch
  /// How a session's context is kept within its window.
  Context
  /// The agents a session spawns: how many and how deep.
  Agents
  /// The model catalog and keeping prompt caches warm.
  ModelsAndCaching
  /// What the agent drives or reaches: MCP servers, remote kernels, the
  /// desktop.
  Tools
}

/// `category` as the `extension_settings` group reports it.
pub fn category_name(category: Category) -> String {
  case category {
    WebSearch -> "web_search"
    Context -> "context"
    Agents -> "agents"
    ModelsAndCaching -> "models_and_caching"
    Tools -> "tools"
  }
}

/// A whole section: the name it is saved under, a label that says what it
/// configures to someone who does not know who declares it, the category it
/// belongs to, the fields it declares, the decoder that reads them into its
/// owner's config, and the rules across fields that no one field states
/// (`check`).
pub opaque type Section(a) {
  Section(
    name: String,
    label: String,
    category: Category,
    fields: List(Field),
    decoder: decode.Decoder(a),
    check: fn(a) -> Result(a, String),
  )
}

pub fn section(
  name: String,
  label: String,
  category: Category,
  fields: List(Field),
  decoder: decode.Decoder(a),
  check: fn(a) -> Result(a, String),
) -> Section(a) {
  Section(name, label, category, fields, decoder, check)
}

/// A section without its config type, as an extension plugs it in: `accept`
/// answers whether a saved section is one the extension can use.
pub type Declaration {
  Declaration(
    section: String,
    label: String,
    category: Category,
    fields: List(Field),
    accept: fn(Dynamic) -> Result(Nil, String),
  )
}

pub fn declaration(section: Section(a)) -> Declaration {
  Declaration(
    section.name,
    section.label,
    section.category,
    section.fields,
    fn(value) { parse(section, value) |> result.replace(Nil) },
  )
}

/// Whether `declaration`'s defaults are values its own fields accept, and
/// together a section its own check accepts.
pub fn sound(declaration: Declaration) -> Result(Nil, String) {
  let defaults =
    list.filter_map(declaration.fields, fn(field) {
      case field.kind {
        Whole(Some(default), _, _) -> Ok(#(field.key, dynamic.int(default)))
        Text(Some(default)) -> Ok(#(field.key, dynamic.string(default)))
        Capped(default, _, _) ->
          Ok(#(field.key, dynamic.int(limit_value(default))))
        _ -> Error(Nil)
      }
    })
  use _ <- result.try(
    list.try_each(declaration.fields, fn(field) {
      check_field(declaration.section, field, dict.from_list(defaults))
    }),
  )
  declaration.accept(dynamic.properties([]))
}

/// The owner's config from its saved section. A missing section reads as an
/// empty one, so every setting takes its default.
pub fn load_section(section: Section(a)) -> Result(a, String) {
  use sections <- result.try(sections(home()))
  parse(
    section,
    dict.get(sections, section.name) |> result.unwrap(dynamic.properties([])),
  )
}

fn parse(section: Section(a), value: Dynamic) -> Result(a, String) {
  use values <- result.try(
    decode.run(value, decode.dict(decode.string, decode.dynamic))
    |> result.replace_error(section.name <> " settings must be an object"),
  )
  use _ <- result.try(
    list.try_each(section.fields, fn(field) {
      check_field(section.name, field, values)
    }),
  )
  use config <- result.try(
    decode.run(value, section.decoder)
    |> result.replace_error("invalid settings in section " <> section.name),
  )
  section.check(config)
}

/// Whether the saved value of `field`, if any, is one it accepts. Null
/// counts as unset.
pub fn check_field(
  section: String,
  field: Field,
  values: Dict(String, Dynamic),
) -> Result(Nil, String) {
  case dict.get(values, field.key) {
    Error(_) -> Ok(Nil)
    Ok(saved) ->
      case decode.run(saved, decode.optional(decode.dynamic)) {
        Ok(None) -> Ok(Nil)
        _ ->
          case accepts(field.kind, saved) {
            True -> Ok(Nil)
            False ->
              Error(
                section <> " " <> field.key <> " must be " <> rule(field.kind),
              )
          }
      }
  }
}

fn accepts(kind: Kind, saved: Dynamic) -> Bool {
  case kind {
    Whole(_, minimum, maximum) -> within(saved, minimum, maximum)
    Text(_) ->
      case decode.run(saved, decode.string) {
        Ok(text) ->
          string.trim(text) != "" && string.byte_size(text) <= text_limit
        Error(_) -> False
      }
    Capped(_, minimum, maximum) ->
      within(saved, minimum, maximum)
      || decode.run(saved, decode.int) == Ok(no_limit)
  }
}

fn within(saved: Dynamic, minimum: Int, maximum: Int) -> Bool {
  case decode.run(saved, decode.int) {
    Ok(number) -> number >= minimum && number <= maximum
    Error(_) -> False
  }
}

/// `limit` as a saved value: its number, or `no_limit`.
pub fn limit_value(limit: Limit) -> Int {
  case limit {
    Limited(number) -> number
    Unlimited -> no_limit
  }
}

/// What `kind` accepts, as the end of a sentence.
pub fn rule(kind: Kind) -> String {
  case kind {
    Whole(_, minimum, maximum) ->
      "a whole number from "
      <> int.to_string(minimum)
      <> " to "
      <> int.to_string(maximum)
    Text(_) ->
      "text that is not blank, at most "
      <> int.to_string(text_limit)
      <> " bytes"
    Capped(_, minimum, maximum) ->
      "a whole number from "
      <> int.to_string(minimum)
      <> " to "
      <> int.to_string(maximum)
      <> ", or "
      <> int.to_string(no_limit)
      <> " for no limit"
  }
}

/// A section nothing declares, `default` when it is missing.
pub fn load(
  name: String,
  decoder: decode.Decoder(a),
  default: a,
) -> Result(a, String) {
  use sections <- result.try(sections(home()))
  case dict.get(sections, name) {
    Error(_) -> Ok(default)
    Ok(value) ->
      decode.run(value, decoder)
      |> result.replace_error("invalid settings in section " <> name)
  }
}

fn sections(home: String) -> Result(Dict(String, Dynamic), String) {
  use bytes <- result.try(read(home))
  json.parse_bits(bytes, decode.dict(decode.string, decode.dynamic))
  |> result.replace_error("extensions.json must contain a JSON object")
}

/// `$ALBEDO_HOME`, else `~/.albedo`: where extension-owned state belongs.
@external(erlang, "albedo_extension_settings", "home")
pub fn home() -> String

@external(erlang, "albedo_extension_settings", "read")
fn read(home: String) -> Result(BitArray, String)

/// Read-only inputs used by composition discovery and admission checks.
@external(erlang, "albedo_settings_read", "composition_revision")
pub fn composition_revision(home: String) -> Result(String, String)

@external(erlang, "albedo_settings_read", "mcp_definitions")
pub fn mcp_definitions(home: String) -> Result(List(#(String, Bool)), String)
