//// Field reads over objects `json.parse` produced, without the per-field
//// bookkeeping of `gleam/dynamic/decode`. Each returns `Error(Nil)` for any
//// shape its decoder equivalent would not take as is, so a caller reads the
//// common shape here and falls back to that decoder, which owns the verdict.

import gleam/dynamic.{type Dynamic}
import gleam/option.{type Option}

type Kind {
  String
  Int
  Bool
  List
  Object
}

/// A parsed event and its `type` string, as
/// `decode.field("type", decode.string)` reads it.
@external(erlang, "albedo_openai_json", "event")
pub fn event(data: String) -> Result(#(String, Dynamic), Nil)

/// `decode.field(key, decode.string)`.
@external(erlang, "albedo_openai_json", "string_field")
pub fn string(object: Dynamic, key: String) -> Result(String, Nil)

/// `decode.at(path, decode.string)`.
@external(erlang, "albedo_openai_json", "string_at")
pub fn string_at(object: Dynamic, path: List(String)) -> Result(String, Nil)

/// `decode.field(key, decode.int)`.
@external(erlang, "albedo_openai_json", "int_field")
pub fn int(object: Dynamic, key: String) -> Result(Int, Nil)

/// `decode.optional_field(key, default, decode.int)`.
@external(erlang, "albedo_openai_json", "int_field_or")
pub fn int_or(object: Dynamic, key: String, default: Int) -> Result(Int, Nil)

/// `decode.optional_field(key, None, decode.optional(decode.string))`.
@external(erlang, "albedo_openai_json", "optional_string_field")
pub fn optional_string(
  object: Dynamic,
  key: String,
) -> Result(Option(String), Nil)

/// `decode.optional_field(key, None, decode.optional(decode.int))`.
@external(erlang, "albedo_openai_json", "optional_int_field")
pub fn optional_int(object: Dynamic, key: String) -> Result(Option(Int), Nil)

/// The elements of a list field.
@external(erlang, "albedo_openai_json", "list_field")
pub fn list(object: Dynamic, key: String) -> Result(List(Dynamic), Nil)

/// An object field.
@external(erlang, "albedo_openai_json", "object_field")
pub fn object(object: Dynamic, key: String) -> Result(Dynamic, Nil)

/// Whether a field is absent or null.
@external(erlang, "albedo_openai_json", "missing")
pub fn missing(object: Dynamic, key: String) -> Bool

/// Whether `object` is an object whose fields outside `keys` are all null
/// or empty lists.
@external(erlang, "albedo_openai_json", "empty_except")
pub fn empty_except(object: Dynamic, keys: List(String)) -> Bool

/// `next()` when `condition` holds, else Error(Nil): a field reader's guard.
pub fn require(
  condition: Bool,
  next: fn() -> Result(a, Nil),
) -> Result(a, Nil) {
  case condition {
    True -> next()
    False -> Error(Nil)
  }
}

/// Whether `object` is an object without `key`; a null field is present.
@external(erlang, "albedo_openai_json", "absent")
pub fn absent(object: Dynamic, key: String) -> Bool

@external(erlang, "albedo_openai_json", "field_or")
fn field_or(
  object: Dynamic,
  key: String,
  kind: Kind,
  default: a,
) -> Result(a, Nil)

@external(erlang, "albedo_openai_json", "present")
fn present(object: Dynamic, key: String, kind: Kind) -> Result(Option(a), Nil)

/// `decode.optional_field(key, default, decode.string)`.
pub fn string_or(
  object: Dynamic,
  key: String,
  default: String,
) -> Result(String, Nil) {
  field_or(object, key, String, default)
}

/// `decode.optional_field(key, default, decode.bool)`.
pub fn bool_or(
  object: Dynamic,
  key: String,
  default: Bool,
) -> Result(Bool, Nil) {
  field_or(object, key, Bool, default)
}

/// The elements of a list field, or none when it is absent.
pub fn list_or_empty(
  object: Dynamic,
  key: String,
) -> Result(List(Dynamic), Nil) {
  field_or(object, key, List, [])
}

/// A string field as an option that is None only when the key is absent:
/// `decode.optional_field(key, None, decode.map(decode.string, Some))`.
pub fn present_string(
  object: Dynamic,
  key: String,
) -> Result(Option(String), Nil) {
  present(object, key, String)
}

/// An int field as an option that is None only when the key is absent.
pub fn present_int(object: Dynamic, key: String) -> Result(Option(Int), Nil) {
  present(object, key, Int)
}

/// An object field as an option that is None only when the key is absent.
pub fn present_object(
  object: Dynamic,
  key: String,
) -> Result(Option(Dynamic), Nil) {
  present(object, key, Object)
}
