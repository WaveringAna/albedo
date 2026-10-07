//// Field reads over objects `json.parse` produced, without the per-field
//// bookkeeping of `gleam/dynamic/decode`. Each returns `Error(Nil)` for any
//// shape its decoder equivalent would not take as is, so a caller reads the
//// common shape here and falls back to that decoder, which owns the verdict.

import gleam/dynamic.{type Dynamic}
import gleam/option.{type Option}

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
