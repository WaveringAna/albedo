//// Bounded, read-only access to this session's durable transcript rows, for
//// history an archive frame renders illegibly or its budget dropped.

import albedo/harness/extension
import albedo/harness/search
import albedo/harness/tool
import gleam/dynamic/decode
import gleam/json
import gleam/option.{None}
import gleam/result

pub fn definitions() -> List(extension.Tool) {
  [
    tool.text(
      "transcript_grep",
      "Find a case-insensitive literal term in this session's full durable transcript, including history archived out of the request. It matches the text of messages, reasoning and tool calls, not a row's label. Results are oldest first and paged (limit 1..20, default 10); each names the row's seq and kind for transcript_read. after_seq and before_seq restrict the rows searched to those after and before a seq.",
      False,
      ["pattern"],
      [
        #("pattern", "string"),
        #("limit", "integer"),
        #("offset", "integer"),
        #("after_seq", "integer"),
        #("before_seq", "integer"),
      ],
      {
        use pattern <- decode.field("pattern", decode.string)
        use limit <- decode.optional_field("limit", 10, decode.int)
        use offset <- decode.optional_field("offset", 0, decode.int)
        use after <- decode.optional_field(
          "after_seq",
          None,
          decode.optional(decode.int),
        )
        use before <- decode.optional_field(
          "before_seq",
          None,
          decode.optional(decode.int),
        )
        decode.success(#(pattern, limit, offset, after, before))
      },
      "expected pattern and optional limit, offset, after_seq, before_seq",
      fn(context, arguments) {
        let #(pattern, limit, offset, after, before) = arguments
        search.transcript_grep(
          context.store,
          context.session,
          pattern,
          limit,
          offset,
          after,
          before,
        )
        |> result.map(json.to_string)
      },
    ),
    tool.text(
      "transcript_read",
      "Read this session's original transcript rows as text from seq on; each row starts with a `[row #N]` header. limit and offset count characters, not rows (limit default 4000, at most 8000); next_offset continues the page. through stops after that row, so seq N with through N reads exactly row N. Image payloads remain in the durable transcript.",
      False,
      ["seq"],
      [
        #("seq", "integer"),
        #("through", "integer"),
        #("offset", "integer"),
        #("limit", "integer"),
      ],
      {
        use seq <- decode.field("seq", decode.int)
        use through <- decode.optional_field(
          "through",
          None,
          decode.optional(decode.int),
        )
        use offset <- decode.optional_field("offset", 0, decode.int)
        use limit <- decode.optional_field("limit", 4000, decode.int)
        decode.success(#(seq, through, offset, limit))
      },
      "expected seq, optional through, offset and limit",
      fn(context, arguments) {
        let #(seq, through, offset, limit) = arguments
        tool.transcript_read(
          context.store,
          context.session,
          seq,
          through,
          offset,
          limit,
        )
        |> result.map(json.to_string)
      },
    ),
  ]
}
