//// Bounded, read-only access to source-backed LCM nodes and transcript rows.

import albedo/daemon/conversation
import albedo/daemon/store
import albedo/harness/extension
import albedo/harness/extensions/lcm/graph
import albedo/openai_api/types
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub fn definitions() -> List(extension.Tool) {
  [
    extension.Tool(
      types.Tool(
        "lcm_list",
        "List every stored LCM fold in this session, including folds absent from the current request. Results are paged.",
        json.object([
          #("type", json.string("object")),
          #("additionalProperties", json.bool(False)),
          #("required", json.array([], json.string)),
          #(
            "properties",
            json.object([
              #("limit", json.object([#("type", json.string("integer"))])),
              #("offset", json.object([#("type", json.string("integer"))])),
            ]),
          ),
        ]),
        False,
      ),
      fn(context, arguments) {
        let decoder = {
          use limit <- decode.optional_field("limit", 20, decode.int)
          use offset <- decode.optional_field("offset", 0, decode.int)
          decode.success(#(limit, offset))
        }
        case json.parse(arguments, decoder) {
          Ok(#(limit, offset)) ->
            list_folds(context.store, context.session, limit, offset)
            |> result.map(extension.text)
          Error(_) -> Ok(extension.text("expected optional limit and offset"))
        }
      },
      fn(_) { None },
    ),
    extension.Tool(
      types.Tool(
        "lcm_grep",
        "Find a case-insensitive literal term in this session's durable conversation and LCM summaries. Results are paged; source matches name their covering summary node.",
        json.object([
          #("type", json.string("object")),
          #("additionalProperties", json.bool(False)),
          #("required", json.array(["pattern"], json.string)),
          #(
            "properties",
            json.object([
              #("pattern", json.object([#("type", json.string("string"))])),
              #("limit", json.object([#("type", json.string("integer"))])),
              #("offset", json.object([#("type", json.string("integer"))])),
              #("summary_id", json.object([#("type", json.string("integer"))])),
            ]),
          ),
        ]),
        False,
      ),
      fn(context, arguments) {
        let decoder = {
          use pattern <- decode.field("pattern", decode.string)
          use limit <- decode.optional_field("limit", 10, decode.int)
          use offset <- decode.optional_field("offset", 0, decode.int)
          use summary_id <- decode.optional_field(
            "summary_id",
            None,
            decode.optional(decode.int),
          )
          decode.success(#(pattern, limit, offset, summary_id))
        }
        case json.parse(arguments, decoder) {
          Ok(#(pattern, limit, offset, summary_id)) ->
            grep_page(
              context.store,
              context.session,
              pattern,
              limit,
              offset,
              summary_id,
            )
            |> result.map(extension.text)
          Error(_) ->
            Ok(extension.text(
              "expected pattern and optional limit, offset, summary_id",
            ))
        }
      },
      fn(_) { None },
    ),
    extension.Tool(
      types.Tool(
        "lcm_describe",
        "Inspect one LCM summary node, its durable source range, and child nodes.",
        json.object([
          #("type", json.string("object")),
          #("additionalProperties", json.bool(False)),
          #("required", json.array(["id"], json.string)),
          #(
            "properties",
            json.object([
              #("id", json.object([#("type", json.string("integer"))])),
            ]),
          ),
        ]),
        True,
      ),
      fn(context, arguments) {
        case
          json.parse(arguments, decode.field("id", decode.int, decode.success))
        {
          Ok(id) ->
            describe(context.store, context.session, id)
            |> result.map(extension.text)
          Error(_) -> Ok(extension.text("expected integer node id"))
        }
      },
      fn(_) { None },
    ),
    extension.Tool(
      types.Tool(
        "lcm_expand",
        "Read a bounded page of the original transcript rows covered by one LCM node. Use next_offset to continue; image payloads remain in the durable transcript.",
        json.object([
          #("type", json.string("object")),
          #("additionalProperties", json.bool(False)),
          #("required", json.array(["id"], json.string)),
          #(
            "properties",
            json.object([
              #("id", json.object([#("type", json.string("integer"))])),
              #("offset", json.object([#("type", json.string("integer"))])),
              #("limit", json.object([#("type", json.string("integer"))])),
            ]),
          ),
        ]),
        False,
      ),
      fn(context, arguments) {
        let decoder = {
          use id <- decode.field("id", decode.int)
          use offset <- decode.optional_field("offset", 0, decode.int)
          use limit <- decode.optional_field("limit", 4000, decode.int)
          decode.success(#(id, offset, limit))
        }
        case json.parse(arguments, decoder) {
          Ok(#(id, offset, limit)) ->
            expand(context.store, context.session, id, offset, limit)
            |> result.map(extension.text)
          Error(_) ->
            Ok(extension.text("expected id, optional offset and limit"))
        }
      },
      fn(_) { None },
    ),
  ]
}

pub fn list_folds(
  ledger: store.Store,
  session: String,
  limit: Int,
  offset: Int,
) -> Result(String, String) {
  use _ <- result.try(case offset >= 0 {
    True -> Ok(Nil)
    False -> Error("LCM list offset must be nonnegative")
  })
  use nodes <- result.try(graph.all_nodes(ledger, session))
  use frontier <- result.try(graph.frontier(ledger, session))
  let limit = int.min(20, int.max(1, limit))
  let next = offset + limit
  json.object([
    #("total", json.int(list.length(nodes))),
    #("offset", json.int(offset)),
    #("next_offset", case next < list.length(nodes) {
      True -> json.int(next)
      False -> json.null()
    }),
    #(
      "folds",
      json.array(list.take(list.drop(nodes, offset), limit), fn(node) {
        json.object([
          #("id", json.int(node.id)),
          #("depth", json.int(node.depth)),
          #("first_seq", json.int(node.first_seq)),
          #("last_seq", json.int(node.last_seq)),
          #(
            "frontier",
            json.bool(list.any(frontier, fn(item) { item.id == node.id })),
          ),
          #("preview", json.string(excerpt(node.summary, 200))),
        ])
      }),
    ),
  ])
  |> json.to_string
  |> Ok
}

pub fn grep(
  ledger: store.Store,
  session: String,
  pattern: String,
  limit: Int,
) -> Result(String, String) {
  grep_page(ledger, session, pattern, limit, 0, None)
}

pub fn grep_page(
  ledger: store.Store,
  session: String,
  pattern: String,
  limit: Int,
  offset: Int,
  summary_id: Option(Int),
) -> Result(String, String) {
  let pattern = string.trim(pattern)
  use _ <- result.try(case pattern != "" && string.length(pattern) <= 200 {
    True -> Ok(Nil)
    False -> Error("LCM search pattern must be 1..200 characters")
  })
  use _ <- result.try(case offset >= 0 {
    True -> Ok(Nil)
    False -> Error("LCM search offset must be nonnegative")
  })
  use sources <- result.try(conversation.load_sources(ledger, session))
  use nodes <- result.try(graph.all_nodes(ledger, session))
  use frontier <- result.try(graph.frontier(ledger, session))
  use scope <- result.try(case summary_id {
    Some(id) -> required_node(ledger, session, id) |> result.map(Some)
    None -> Ok(None)
  })
  let needle = string.lowercase(pattern)
  let matches =
    sources
    |> list.filter(fn(item) {
      in_scope(item.source.seq, scope)
      && string.contains(
        string.lowercase(source_text(item.entry.input)),
        needle,
      )
    })
  let summaries =
    nodes
    |> list.filter(fn(node) {
      case scope {
        Some(parent) ->
          node.first_seq >= parent.first_seq && node.last_seq <= parent.last_seq
        None -> True
      }
      && string.contains(string.lowercase(node.summary), needle)
    })
  let limit = int.min(20, int.max(1, limit))
  let next = offset + limit
  json.object([
    #("pattern", json.string(pattern)),
    #("offset", json.int(offset)),
    #("source_count", json.int(list.length(matches))),
    #("node_count", json.int(list.length(summaries))),
    #(
      "next_offset",
      case next < list.length(matches) || next < list.length(summaries) {
        True -> json.int(next)
        False -> json.null()
      },
    ),
    #(
      "sources",
      json.array(list.take(list.drop(matches, offset), limit), fn(item) {
        json.object([
          #("seq", json.int(item.source.seq)),
          #("node_id", case covering_node(frontier, item.source.seq) {
            Some(node) -> json.int(node.id)
            None -> json.null()
          }),
          #("preview", json.string(excerpt(source_text(item.entry.input), 400))),
        ])
      }),
    ),
    #(
      "nodes",
      json.array(list.take(list.drop(summaries, offset), limit), fn(node) {
        json.object([
          #("id", json.int(node.id)),
          #("preview", json.string(excerpt(node.summary, 400))),
        ])
      }),
    ),
  ])
  |> json.to_string
  |> Ok
}

fn in_scope(seq: Int, scope: Option(graph.Node)) -> Bool {
  case scope {
    Some(node) -> seq >= node.first_seq && seq <= node.last_seq
    None -> True
  }
}

fn covering_node(frontier: List(graph.Node), seq: Int) -> Option(graph.Node) {
  frontier
  |> list.find(fn(node) { seq >= node.first_seq && seq <= node.last_seq })
  |> result.map(Some)
  |> result.unwrap(None)
}

pub fn describe(
  ledger: store.Store,
  session: String,
  id: Int,
) -> Result(String, String) {
  use node <- result.try(required_node(ledger, session, id))
  use children <- result.try(graph.children(ledger, node.id))
  json.object([
    #("id", json.int(node.id)),
    #("depth", json.int(node.depth)),
    #("first_seq", json.int(node.first_seq)),
    #("last_seq", json.int(node.last_seq)),
    #("children", json.array(children, json.int)),
    #("summary", json.string(node.summary)),
  ])
  |> json.to_string
  |> Ok
}

pub fn expand(
  ledger: store.Store,
  session: String,
  id: Int,
  offset: Int,
  limit: Int,
) -> Result(String, String) {
  use _ <- result.try(case offset >= 0 {
    True -> Ok(Nil)
    False -> Error("LCM expansion offset must be nonnegative")
  })
  use node <- result.try(required_node(ledger, session, id))
  use sources <- result.try(conversation.load_sources(ledger, session))
  let rendered =
    sources
    |> list.filter(fn(item) {
      item.source.seq >= node.first_seq && item.source.seq <= node.last_seq
    })
    |> list.map(fn(item) {
      "[source #"
      <> int.to_string(item.source.seq)
      <> "]\n"
      <> source_text(item.entry.input)
    })
    |> string.join("\n\n")
  let limit = int.min(8000, int.max(1, limit))
  let page = string.slice(rendered, offset, limit)
  let next = offset + string.length(page)
  json.object([
    #("id", json.int(id)),
    #("offset", json.int(offset)),
    #("content", json.string(page)),
    #("next_offset", case next < string.length(rendered) {
      True -> json.int(next)
      False -> json.null()
    }),
    #(
      "image_payloads",
      json.string("retained in transcript; text page shows metadata only"),
    ),
  ])
  |> json.to_string
  |> Ok
}

fn required_node(
  ledger: store.Store,
  session: String,
  id: Int,
) -> Result(graph.Node, String) {
  use found <- result.try(graph.node(ledger, session, id))
  case found {
    Some(node) -> Ok(node)
    None -> Error("LCM node not found in this session")
  }
}

fn source_text(input: types.Input) -> String {
  case input {
    types.User(text) -> "[user]\n" <> text
    types.UserImage(text, image) ->
      "[user with " <> image_description(image) <> "]\n" <> text
    types.Assistant(text) -> "[assistant]\n" <> text
    types.ToolOutput(id, output, images) ->
      "[tool "
      <> id
      <> "]\n"
      <> output
      <> string.concat(
        list.map(images, fn(image) { "\n[" <> image_description(image) <> "]" }),
      )
    types.Replay(item) ->
      "[provider output]\n" <> json.to_string(types.replay_json(item))
  }
}

fn image_description(image: types.Image) -> String {
  let #(mime, width, height, _) = types.image_meta(image)
  mime <> " " <> int.to_string(width) <> "x" <> int.to_string(height)
}

fn excerpt(value: String, maximum: Int) -> String {
  case string.length(value) > maximum {
    True -> string.slice(value, 0, maximum) <> "…"
    False -> value
  }
}
