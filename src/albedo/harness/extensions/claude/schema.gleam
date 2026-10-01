import albedo/openai_api/types
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/list
import gleam/result
import gleam/string

type Object =
  Dict(String, Dynamic)

// Anthropic rejects top-level combiners. Preserve nested schemas and unrelated
// fields; the harness still validates tool arguments against the original schema.
pub fn normalize(schema: Json) -> Json {
  let assert Ok(value) = json.parse(json.to_string(schema), decode.dynamic)
  case object(value) {
    Error(_) ->
      json.object([
        #("type", json.string("object")),
        #("properties", json.object([])),
      ])
    Ok(root) -> {
      let keys = ["allOf", "oneOf", "anyOf"]
      case list.any(keys, fn(key) { dict.has_key(root, key) }) {
        False -> schema
        True -> flatten(root, keys)
      }
    }
  }
}

fn flatten(root: Object, keys: List(String)) -> Json {
  let all = branches(root, "allOf")
  let unions = list.append(branches(root, "oneOf"), branches(root, "anyOf"))
  let base = list.fold(keys, root, fn(node, key) { dict.delete(node, key) })
  // Root properties and earlier branches take precedence over later branches.
  let props =
    list.fold(list.append(all, unions), properties(base), fn(acc, branch) {
      dict.merge(properties(branch), acc)
    })
  let required =
    list.append(required(base), list.flat_map(all, required))
    |> list.append(common_required(unions))
    |> list.unique
    |> list.sort(string.compare)
  base
  |> dict.delete("type")
  |> dict.delete("properties")
  |> dict.delete("required")
  |> dict.map_values(fn(_, value) { types.encode_value(value) })
  |> dict.insert("type", json.string("object"))
  |> dict.insert(
    "properties",
    json.object(
      dict.to_list(
        dict.map_values(props, fn(_, value) { types.encode_value(value) }),
      ),
    ),
  )
  |> dict.insert("required", json.array(required, json.string))
  |> describe_union(root)
  |> dict.to_list
  |> json.object
}

fn object(value: Dynamic) {
  decode.run(value, decode.dict(decode.string, decode.dynamic))
}

fn branches(root: Object, key: String) -> List(Object) {
  field(root, key, decode.list(decode.dynamic), [])
  |> list.filter_map(object)
}

fn properties(node: Object) -> Object {
  field(
    node,
    "properties",
    decode.dict(decode.string, decode.dynamic),
    dict.new(),
  )
}

fn required(node: Object) -> List(String) {
  field(node, "required", decode.list(decode.dynamic), [])
  |> list.filter_map(fn(value) { decode.run(value, decode.string) })
}

fn field(
  node: Object,
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

fn common_required(branches: List(Object)) -> List(String) {
  case branches {
    [] -> []
    [first, ..rest] -> {
      let required_sets =
        list.map(rest, fn(branch) {
          required(branch)
          |> list.map(fn(name) { #(name, Nil) })
          |> dict.from_list
        })
      list.filter(required(first), fn(name) {
        list.all(required_sets, fn(names) { dict.has_key(names, name) })
      })
    }
  }
}

fn describe_union(
  fields: Dict(String, Json),
  root: Object,
) -> Dict(String, Json) {
  let guidance =
    [#("oneOf", "Exactly one of: "), #("anyOf", "At least one of: ")]
    |> list.filter_map(fn(pair) {
      let hints = branches(root, pair.0) |> list.map(branch_hint)
      case hints {
        [_, _, ..] ->
          case list.contains(hints, "") {
            True -> Error(Nil)
            False -> Ok(pair.1 <> string.join(hints, " or "))
          }
        _ -> Error(Nil)
      }
    })
  case guidance {
    [] -> fields
    _ -> {
      let existing = field(root, "description", decode.string, "")
      let description =
        [existing, ..guidance]
        |> list.filter(fn(text) { text != "" })
        |> string.join("; ")
      dict.insert(fields, "description", json.string(description))
    }
  }
}

fn branch_hint(branch: Object) -> String {
  case required(branch) {
    [] -> properties(branch) |> dict.keys |> list.sort(string.compare)
    names -> names
  }
  |> string.join(" + ")
}
