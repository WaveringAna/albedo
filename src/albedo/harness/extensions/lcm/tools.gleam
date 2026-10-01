//// Bounded, read-only access to source-backed LCM nodes and transcript rows.

import albedo/daemon/conversation
import albedo/daemon/store
import albedo/harness/compaction
import albedo/harness/extension
import albedo/harness/extensions/lcm/graph
import albedo/harness/search
import albedo/harness/tool
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub fn definitions() -> List(extension.Tool) {
  [
    tool.text(
      "lcm_list",
      "List every stored LCM fold in this session, including folds absent from the current request. Results are paged.",
      False,
      [],
      [
        #("limit", "integer"),
        #("offset", "integer"),
      ],
      {
        use limit <- decode.optional_field("limit", 20, decode.int)
        use offset <- decode.optional_field("offset", 0, decode.int)
        decode.success(#(limit, offset))
      },
      "expected optional limit and offset",
      fn(context, arguments) {
        let #(limit, offset) = arguments
        list_folds(context.store, context.session, limit, offset)
      },
    ),
    tool.text(
      "lcm_grep",
      "Find a case-insensitive literal term in this session's durable conversation and LCM summaries. Results are paged; source matches name their covering summary node.",
      False,
      ["pattern"],
      [
        #("pattern", "string"),
        #("limit", "integer"),
        #("offset", "integer"),
        #("summary_id", "integer"),
      ],
      {
        use pattern <- decode.field("pattern", decode.string)
        use limit <- decode.optional_field("limit", 10, decode.int)
        use offset <- decode.optional_field("offset", 0, decode.int)
        use summary_id <- decode.optional_field(
          "summary_id",
          None,
          decode.optional(decode.int),
        )
        decode.success(#(pattern, limit, offset, summary_id))
      },
      "expected pattern and optional limit, offset, summary_id",
      fn(context, arguments) {
        let #(pattern, limit, offset, summary_id) = arguments
        grep_page(
          context.store,
          context.session,
          pattern,
          limit,
          offset,
          summary_id,
        )
      },
    ),
    tool.text(
      "lcm_describe",
      "Inspect one LCM summary node, its durable source range, and child nodes.",
      True,
      ["id"],
      [#("id", "integer")],
      decode.field("id", decode.int, decode.success),
      "expected integer node id",
      fn(context, id) { describe(context.store, context.session, id) },
    ),
    tool.text(
      "lcm_expand",
      "Read a bounded page of the original transcript rows covered by one LCM node. Use next_offset to continue; image payloads remain in the durable transcript.",
      False,
      ["id"],
      [
        #("id", "integer"),
        #("offset", "integer"),
        #("limit", "integer"),
      ],
      {
        use id <- decode.field("id", decode.int)
        use offset <- decode.optional_field("offset", 0, decode.int)
        use limit <- decode.optional_field("limit", 4000, decode.int)
        decode.success(#(id, offset, limit))
      },
      "expected id, optional offset and limit",
      fn(context, arguments) {
        let #(id, offset, limit) = arguments
        expand(context.store, context.session, id, offset, limit)
      },
    ),
  ]
}

pub fn list_folds(
  ledger: store.Store,
  session: String,
  limit: Int,
  offset: Int,
) -> Result(String, String) {
  use _ <- result.try(compaction.require(
    offset >= 0,
    "LCM list offset must be nonnegative",
  ))
  use nodes <- result.try(graph.all_nodes(ledger, session))
  use frontier <- result.try(graph.frontier(ledger, session))
  let limit = int.clamp(limit, 1, 20)
  let next = offset + limit
  json.object([
    #("total", json.int(list.length(nodes))),
    #("offset", json.int(offset)),
    #("next_offset", tool.next_offset(next, next < list.length(nodes))),
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
          #("preview", json.string(tool.excerpt(node.summary, 200))),
        ])
      }),
    ),
  ])
  |> json.to_string
  |> Ok
}

/// Search the first page of matching transcript rows and LCM summaries.
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
  use needle <- result.try(search.needle(pattern))
  use _ <- result.try(compaction.require(
    offset >= 0,
    "LCM search offset must be nonnegative",
  ))
  use sources <- result.try(search.rows(ledger, search.Within(session), needle))
  use nodes <- result.try(graph.all_nodes(ledger, session))
  use frontier <- result.try(graph.frontier(ledger, session))
  use scope <- result.try(case summary_id {
    Some(id) -> required_node(ledger, session, id) |> result.map(Some)
    None -> Ok(None)
  })
  let matches = list.filter(sources, fn(match) { in_scope(match.seq, scope) })
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
  let limit = int.clamp(limit, 1, 20)
  let next = offset + limit
  json.object([
    #("pattern", json.string(string.trim(pattern))),
    #("offset", json.int(offset)),
    #("source_count", json.int(list.length(matches))),
    #("node_count", json.int(list.length(summaries))),
    #(
      "next_offset",
      tool.next_offset(
        next,
        next < list.length(matches) || next < list.length(summaries),
      ),
    ),
    #(
      "sources",
      json.array(list.take(list.drop(matches, offset), limit), fn(match) {
        json.object([
          #("seq", json.int(match.seq)),
          #("node_id", case covering_node(frontier, match.seq) {
            Some(node) -> json.int(node.id)
            None -> json.null()
          }),
          #("preview", json.string(search.preview(match.text, needle))),
        ])
      }),
    ),
    #(
      "nodes",
      json.array(list.take(list.drop(summaries, offset), limit), fn(node) {
        json.object([
          #("id", json.int(node.id)),
          #("preview", json.string(search.preview(node.summary, needle))),
        ])
      }),
    ),
  ])
  |> json.to_string
  |> Ok
}

/// Whether `node`'s durable source range contains `seq`.
fn covers(node: graph.Node, seq: Int) -> Bool {
  seq >= node.first_seq && seq <= node.last_seq
}

fn in_scope(seq: Int, scope: Option(graph.Node)) -> Bool {
  case scope {
    Some(node) -> covers(node, seq)
    None -> True
  }
}

fn covering_node(frontier: List(graph.Node), seq: Int) -> Option(graph.Node) {
  list.find(frontier, fn(node) { covers(node, seq) })
  |> option.from_result
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
  use _ <- result.try(compaction.require(
    offset >= 0,
    "LCM expansion offset must be nonnegative",
  ))
  use node <- result.try(required_node(ledger, session, id))
  use sources <- result.try(conversation.load_sources(ledger, session))
  let rendered =
    sources
    |> list.filter(fn(item) { covers(node, item.source.seq) })
    |> list.map(fn(item) {
      "[source #"
      <> int.to_string(item.source.seq)
      <> "]\n"
      <> tool.row_text(item.entry.input)
    })
    |> string.join("\n\n")
  let #(page, next) = tool.text_page(rendered, offset, limit)
  json.object([
    #("id", json.int(id)),
    #("offset", json.int(offset)),
    #("content", json.string(page)),
    #("next_offset", tool.next_offset(next, next < string.length(rendered))),
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
  option.to_result(
    found,
    "LCM node "
      <> int.to_string(id)
      <> " not found in this session; node ids come from lcm_list or lcm_grep"
      <> " nodes, and transcript row seqs belong to transcript_read",
  )
}
