//// Bounded, read-only access to this session's durable transcript rows, for
//// history an archive frame renders illegibly or its budget dropped.

import albedo/harness/extension
import albedo/harness/search
import albedo/harness/tool
import gleam/dynamic/decode
import gleam/json
import gleam/result

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
        search.transcript_grep(
          context.store,
          context.session,
          pattern,
          limit,
          offset,
        )
        |> result.map(json.to_string)
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
        tool.transcript_read(context.store, context.session, seq, offset, limit)
        |> result.map(json.to_string)
      },
    ),
  ]
}
