import albedo/openai_api/types
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/list
import gleam/result
import gleam/string

type Schema =
  Dict(String, Dynamic)

const kept = [
  "type", "description", "enum", "items", "properties", "required", "title",
]

const spilled = [
  "format", "pattern", "minLength", "maxLength", "minimum", "maximum",
  "exclusiveMinimum", "exclusiveMaximum", "multipleOf", "minItems", "maxItems",
  "uniqueItems", "minProperties", "maxProperties", "default", "examples",
]

// Cloud Code Assist accepts the same flat OpenAPI subset for every model family.
// Keep unsupported constraints as description guidance rather than discarding them.
pub fn normalize(input: Json) -> Json {
  let assert Ok(value) = json.parse(json.to_string(input), decode.dynamic)
  let root = object(value) |> result.unwrap(dict.new())
  let definitions =
    dict.merge(properties(root, "definitions"), properties(root, "$defs"))
  let normalized = schema(root, definitions, 0)
  case field(normalized, "type", decode.string, "") {
    "object" -> encode_schema(normalized)
    _ ->
      json.object([
        #("type", json.string("object")),
        #("properties", json.object([])),
      ])
  }
}

fn schema(node: Schema, definitions: Schema, depth: Int) -> Schema {
  case depth > 32 {
    True -> dict.new()
    False -> {
      let resolved = resolve(node, definitions, depth)
      case
        list.any(["allOf", "anyOf", "oneOf"], fn(key) {
          dict.has_key(resolved, key)
        })
      {
        True ->
          schema(collapse(resolved, definitions, depth), definitions, depth + 1)
        False -> finish(resolved, definitions, depth)
      }
    }
  }
}

fn resolve(node: Schema, definitions: Schema, depth: Int) -> Schema {
  let reference = field(node, "$ref", decode.string, "")
  case depth < 32 && string.starts_with(reference, "#/") {
    False -> node
    True -> {
      let name = string.split(reference, "/") |> list.last |> result.unwrap("")
      let rest = dict.delete(node, "$ref")
      case dict.get(definitions, name) |> result.try(object) {
        Ok(target) -> resolve(dict.merge(target, rest), definitions, depth + 1)
        Error(_) -> rest
      }
    }
  }
}

fn collapse(node: Schema, definitions: Schema, depth: Int) -> Schema {
  let base =
    list.fold(
      branches(node, "allOf"),
      dict.delete(node, "allOf"),
      fn(acc, branch) { merge(resolve(branch, definitions, depth + 1), acc) },
    )
  let options =
    list.append(branches(base, "anyOf"), branches(base, "oneOf"))
    |> list.map(fn(branch) { resolve(branch, definitions, depth + 1) })
    |> list.filter(fn(branch) {
      field(branch, "type", decode.string, "") != "null"
    })
  let rest = base |> dict.delete("anyOf") |> dict.delete("oneOf")
  case options {
    [] -> rest
    [only] -> merge(only, rest)
    [first, ..] -> {
      case
        list.all(options, fn(branch) {
          dict.has_key(branch, "const") || dict.has_key(branch, "enum")
        })
      {
        True ->
          dict.insert(
            rest,
            "enum",
            dynamic.list(list.flat_map(options, values)),
          )
        False ->
          describe(
            merge(first, rest),
            "one of: " <> string.join(list.map(options, kind), ", "),
          )
      }
    }
  }
}

fn merge(branch: Schema, into: Schema) -> Schema {
  list.fold(dict.to_list(branch), into, fn(acc, pair) {
    let #(key, value) = pair
    case key {
      "properties" ->
        dict.insert(
          acc,
          key,
          schema_value(dict.merge(properties(branch, key), properties(acc, key))),
        )
      "required" ->
        dict.insert(
          acc,
          key,
          dynamic.list(list.map(
            sorted_names(list.append(required(branch), required(acc))),
            dynamic.string,
          )),
        )
      _ -> dict.insert(acc, key, value)
    }
  })
}

fn finish(node: Schema, definitions: Schema, depth: Int) -> Schema {
  let node = case dict.get(node, "const") {
    Ok(value) -> dict.insert(node, "enum", dynamic.list([value]))
    Error(_) -> node
  }
  let notes =
    list.filter_map(spilled, fn(key) {
      dict.get(node, key)
      |> result.map(fn(value) {
        key <> ": " <> json.to_string(types.encode_value(value))
      })
    })
  let base = dict.filter(node, fn(key, _) { list.contains(kept, key) })
  let base =
    list.fold(["description", "title"], base, fn(acc, key) {
      case dict.get(acc, key) {
        Error(_) -> acc
        Ok(_) ->
          dict.insert(
            acc,
            key,
            dynamic.string(field(acc, key, decode.string, "")),
          )
      }
    })
  let described = case notes {
    [] -> base
    _ -> describe(base, string.join(notes, ", "))
  }
  let typed = case scalar_type(node) {
    Error(_) -> dict.delete(described, "type")
    Ok(kind) -> dict.insert(described, "type", dynamic.string(kind))
  }
  children(normalize_enum(typed), definitions, depth)
}

fn scalar_type(node: Schema) -> Result(String, Nil) {
  let inferred = case
    dict.has_key(node, "properties"),
    dict.has_key(node, "items"),
    dict.has_key(node, "enum")
  {
    True, _, _ -> Ok("object")
    _, True, _ -> Ok("array")
    _, _, True -> Ok("string")
    _, _, _ -> Error(Nil)
  }
  let decoded =
    dict.get(node, "type")
    |> result.try(fn(value) {
      decode.run(value, decode.string) |> result.replace_error(Nil)
    })
  case decoded {
    Ok("null") | Error(_) ->
      case
        strings(node, "type")
        |> list.filter(fn(kind) { kind != "null" })
        |> list.first
      {
        Ok(kind) -> Ok(kind)
        Error(_) -> inferred
      }
    Ok(kind) -> Ok(kind)
  }
}

fn normalize_enum(node: Schema) -> Schema {
  let strings =
    field(node, "enum", decode.list(decode.dynamic), [])
    |> list.filter(fn(value) {
      json.to_string(types.encode_value(value)) != "null"
    })
    |> list.map(fn(value) {
      decode.run(value, decode.string)
      |> result.unwrap(json.to_string(types.encode_value(value)))
    })
    |> sorted_names
  case strings {
    [] -> dict.delete(node, "enum")
    _ ->
      node
      |> dict.insert("enum", dynamic.list(list.map(strings, dynamic.string)))
      |> dict.insert("type", dynamic.string("string"))
  }
}

fn children(node: Schema, definitions: Schema, depth: Int) -> Schema {
  case field(node, "type", decode.string, "") {
    "object" -> {
      let props =
        properties(node, "properties")
        |> dict.map_values(fn(_, value) {
          schema(
            object(value) |> result.unwrap(dict.new()),
            definitions,
            depth + 1,
          )
          |> schema_value
        })
      let names =
        required(node)
        |> list.filter(fn(name) { dict.has_key(props, name) })
        |> sorted_names
      let with_props = dict.insert(node, "properties", schema_value(props))
      case names {
        [] -> dict.delete(with_props, "required")
        _ ->
          dict.insert(
            with_props,
            "required",
            dynamic.list(list.map(names, dynamic.string)),
          )
      }
    }
    "array" -> {
      let items = case dict.get(node, "items") {
        Error(_) -> dict.new()
        Ok(value) ->
          case object(value) {
            Ok(items) -> items
            Error(_) ->
              decode.run(value, decode.list(decode.dynamic))
              |> result.unwrap([])
              |> list.filter_map(object)
              |> list.first
              |> result.unwrap(dict.new())
          }
      }
      node
      |> dict.delete("required")
      |> dict.insert(
        "items",
        schema_value(schema(items, definitions, depth + 1)),
      )
    }
    _ -> list.fold(["properties", "required", "items"], node, dict.delete)
  }
}

fn describe(node: Schema, note: String) -> Schema {
  let description = case field(node, "description", decode.string, "") {
    "" -> note
    text -> text <> " (" <> note <> ")"
  }
  dict.insert(node, "description", dynamic.string(description))
}

fn kind(node: Schema) -> String {
  field(
    node,
    "type",
    decode.string,
    field(node, "title", decode.string, "schema"),
  )
}

fn values(node: Schema) -> List(Dynamic) {
  case dict.get(node, "const") {
    Ok(value) -> [value]
    Error(_) -> field(node, "enum", decode.list(decode.dynamic), [])
  }
}

fn branches(node: Schema, key: String) -> List(Schema) {
  field(node, key, decode.list(decode.dynamic), []) |> list.filter_map(object)
}

fn required(node: Schema) -> List(String) {
  strings(node, "required")
}

fn strings(node: Schema, key: String) -> List(String) {
  field(node, key, decode.list(decode.dynamic), [])
  |> list.filter_map(fn(value) { decode.run(value, decode.string) })
}

fn sorted_names(names: List(String)) -> List(String) {
  names |> list.unique |> list.sort(string.compare)
}

fn properties(node: Schema, key: String) -> Schema {
  field(node, key, decode.dict(decode.string, decode.dynamic), dict.new())
}

fn object(value: Dynamic) {
  decode.run(value, decode.dict(decode.string, decode.dynamic))
  |> result.replace_error(Nil)
}

fn field(
  node: Schema,
  key: String,
  decoder: decode.Decoder(a),
  default: a,
) -> a {
  dict.get(node, key)
  |> result.try(fn(value) {
    decode.run(value, decoder) |> result.replace_error(Nil)
  })
  |> result.unwrap(default)
}

fn schema_value(node: Schema) -> Dynamic {
  dynamic.properties(
    list.map(dict.to_list(node), fn(pair) { #(dynamic.string(pair.0), pair.1) }),
  )
}

fn encode_schema(node: Schema) -> Json {
  types.encode_value(schema_value(node))
}
