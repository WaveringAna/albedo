//// Bounded, read-only access to this session's durable transcript rows, for
//// history an archive frame renders illegibly or its budget dropped.

import albedo/daemon/conversation
import albedo/daemon/store
import albedo/harness/compaction
import albedo/harness/extension
import albedo/harness/tool
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string

pub fn definitions() -> List(extension.Tool) {
  [
    tool.text(
      "transcript_grep",
      "Find a case-insensitive literal term in this session's full durable transcript, including history archived out of the request. Results are paged and name each row's seq for transcript_read.",
      False,
      ["pattern"],
      [
        #("pattern", "string"),
        #("limit", "integer"),
        #("offset", "integer"),
      ],
      {
        use pattern <- decode.field("pattern", decode.string)
        use limit <- decode.optional_field("limit", 10, decode.int)
        use offset <- decode.optional_field("offset", 0, decode.int)
        decode.success(#(pattern, limit, offset))
      },
      "expected pattern and optional limit, offset",
      fn(context, arguments) {
        let #(pattern, limit, offset) = arguments
        grep(context.store, context.session, pattern, limit, offset)
      },
    ),
    tool.text(
      "transcript_read",
      "Read a bounded page of this session's original transcript rows starting at seq. Use next_offset to continue; image payloads remain in the durable transcript.",
      False,
      ["seq"],
      [
        #("seq", "integer"),
        #("offset", "integer"),
        #("limit", "integer"),
      ],
      {
        use seq <- decode.field("seq", decode.int)
        use offset <- decode.optional_field("offset", 0, decode.int)
        use limit <- decode.optional_field("limit", 4000, decode.int)
        decode.success(#(seq, offset, limit))
      },
      "expected seq, optional offset and limit",
      fn(context, arguments) {
        let #(seq, offset, limit) = arguments
        read(context.store, context.session, seq, offset, limit)
      },
    ),
  ]
}

pub fn grep(
  ledger: store.Store,
  session: String,
  pattern: String,
  limit: Int,
  offset: Int,
) -> Result(String, String) {
  let pattern = string.trim(pattern)
  use _ <- result.try(compaction.require(
    pattern != "" && string.length(pattern) <= 200,
    "transcript search pattern must be 1..200 characters",
  ))
  use _ <- result.try(compaction.require(
    offset >= 0,
    "transcript search offset must be nonnegative",
  ))
  use sources <- result.try(conversation.load_sources(ledger, session))
  let needle = string.lowercase(pattern)
  let matches =
    list.filter(sources, fn(item) {
      string.contains(string.lowercase(tool.row_text(item.entry.input)), needle)
    })
  let limit = int.clamp(limit, 1, 20)
  let next = offset + limit
  json.object([
    #("pattern", json.string(pattern)),
    #("offset", json.int(offset)),
    #("count", json.int(list.length(matches))),
    #("next_offset", tool.next_offset(next, next < list.length(matches))),
    #(
      "rows",
      json.array(list.take(list.drop(matches, offset), limit), fn(item) {
        json.object([
          #("seq", json.int(item.source.seq)),
          #(
            "preview",
            json.string(tool.excerpt(tool.row_text(item.entry.input), 400)),
          ),
        ])
      }),
    ),
  ])
  |> json.to_string
  |> Ok
}

pub fn read(
  ledger: store.Store,
  session: String,
  seq: Int,
  offset: Int,
  limit: Int,
) -> Result(String, String) {
  use _ <- result.try(compaction.require(
    offset >= 0,
    "transcript read offset must be nonnegative",
  ))
  use sources <- result.try(conversation.load_sources(ledger, session))
  let rendered =
    sources
    |> list.filter(fn(item) { item.source.seq >= seq })
    |> list.map(fn(item) {
      "[row #"
      <> int.to_string(item.source.seq)
      <> "]\n"
      <> tool.row_text(item.entry.input)
    })
    |> string.join("\n\n")
  let #(page, next) = tool.text_page(rendered, offset, limit)
  json.object([
    #("seq", json.int(seq)),
    #("offset", json.int(offset)),
    #("content", json.string(page)),
    #("next_offset", tool.next_offset(next, next < string.length(rendered))),
  ])
  |> json.to_string
  |> Ok
}
