//// Finding transcript rows by their text: the one search behind
//// transcript_grep, lcm_grep, `h.search_messages`, and `agents.sessions`.
////
//// SQLite narrows the stored rows to candidates one window of rows at a
//// time, so no search holds the store for long, and only candidates are
//// decoded. A candidate's text, as retrieval tools show it, then decides,
//// case-insensitively.

import albedo/daemon/conversation
import albedo/daemon/store
import albedo/harness/compaction
import albedo/harness/tool
import gleam/bool
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import sqlight

pub type Scope {
  /// One session's rows.
  Within(session: String)
  /// The rows of every session but `caller`, and only of those opened in
  /// `cwd` unless it is "".
  Beyond(caller: String, cwd: String)
}

/// A row whose text contains the needle.
pub type Match {
  Match(session: String, seq: Int, text: String)
}

/// `pattern` trimmed, checked, and lowercased for matching.
pub fn needle(pattern: String) -> Result(String, String) {
  let pattern = string.trim(pattern)
  case pattern != "" && string.length(pattern) <= 200 {
    True -> Ok(string.lowercase(pattern))
    False -> Error("search pattern must be 1..200 characters")
  }
}

/// `step` over each row in `scope` whose text contains `needle`, newest
/// first. A row of a session for which `wants(acc, session)` is False is
/// passed over without being decoded.
pub fn fold(
  ledger: store.Store,
  scope: Scope,
  needle: String,
  acc: a,
  wants: fn(a, String) -> Bool,
  step: fn(a, Match) -> a,
) -> Result(a, String) {
  use #(low, high) <- result.try(bounds(ledger, scope))
  let scan =
    Scan(ledger, needle, probe(needle), scope, low, high, False, wants, step)
  pages(scan, high + 1, acc)
}

type Scan(a) {
  Scan(
    ledger: store.Store,
    needle: String,
    probe: String,
    scope: Scope,
    low: Int,
    high: Int,
    ascending: Bool,
    wants: fn(a, String) -> Bool,
    step: fn(a, Match) -> a,
  )
}

const window_rows = 2048

fn bounds(ledger: store.Store, scope: Scope) -> Result(#(Int, Int), String) {
  let #(sql, arguments) = case scope {
    Within(session) -> #(
      "SELECT (SELECT COALESCE(MIN(seq),1) FROM transcript WHERE session=?),(SELECT COALESCE(MAX(seq),0) FROM transcript WHERE session=?)",
      [sqlight.text(session), sqlight.text(session)],
    )
    Beyond(_, _) -> #(
      "SELECT (SELECT COALESCE(MIN(seq),1) FROM transcript),(SELECT COALESCE(MAX(seq),0) FROM transcript)",
      [],
    )
  }
  use rows <- result.try(
    store.read(ledger, sql, arguments, {
      use low <- decode.field(0, decode.int)
      use high <- decode.field(1, decode.int)
      decode.success(#(low, high))
    }),
  )
  case rows {
    [bounds] -> Ok(bounds)
    _ -> Error("could not read transcript bounds")
  }
}

fn scope_filter(scope: Scope) -> #(String, List(sqlight.Value)) {
  case scope {
    Within(session) -> #("t.session=?", [sqlight.text(session)])
    Beyond(caller, "") -> #("t.session<>?", [sqlight.text(caller)])
    Beyond(caller, cwd) -> #("t.session<>? AND s.cwd=?", [
      sqlight.text(caller),
      sqlight.text(cwd),
    ])
  }
}

/// Page actual rows before filtering candidates, so a rare probe cannot
/// make one store call scan the entire transcript. The cursor advances even
/// when no row in the page contains the probe. Cross-session scans page global
/// rows before scope filtering to bound work when most sessions are excluded.
fn pages(scan: Scan(a), cursor: Int, acc: a) -> Result(a, String) {
  let #(where, arguments) = scope_filter(scan.scope)
  let #(raw_scope, raw_arguments, hit_scope, hit_arguments) = case scan.scope {
    Within(_) -> #(where <> " AND ", arguments, "", [])
    Beyond(_, _) -> #("", [], where <> " AND ", arguments)
  }
  let #(comparison, order, boundary) = case scan.ascending {
    True -> #(">", "ASC", "MAX")
    False -> #("<", "DESC", "MIN")
  }
  use rows <- result.try(
    store.read(
      scan.ledger,
      "WITH page AS MATERIALIZED (SELECT t.session,t.seq,t.payload FROM transcript t WHERE "
        <> raw_scope
        <> "t.seq>=? AND t.seq<=? AND t.seq"
        <> comparison
        <> "? ORDER BY t.seq "
        <> order
        <> " LIMIT ?), hits AS (SELECT t.session,t.seq,t.payload FROM page t JOIN sessions s ON s.id=t.session WHERE "
        <> hit_scope
        <> "instr(lower(t.payload),?)>0) SELECT (SELECT COALESCE("
        <> boundary
        <> "(seq),-1) FROM page),hits.session,hits.seq,hits.payload FROM (SELECT 1) LEFT JOIN hits ON 1 ORDER BY hits.seq "
        <> order,
      list.append(raw_arguments, [
        sqlight.int(scan.low),
        sqlight.int(scan.high),
        sqlight.int(cursor),
        sqlight.int(window_rows),
      ])
        |> list.append(hit_arguments)
        |> list.append([sqlight.text(scan.probe)]),
      {
        use cursor <- decode.field(0, decode.int)
        use session <- decode.field(1, decode.optional(decode.string))
        use seq <- decode.field(2, decode.optional(decode.int))
        use payload <- decode.field(3, decode.optional(decode.bit_array))
        decode.success(
          #(cursor, case session, seq, payload {
            Some(session), Some(seq), Some(payload) ->
              Some(#(session, seq, payload))
            _, _, _ -> None
          }),
        )
      },
    ),
  )
  case rows {
    [#(-1, _)] -> Ok(acc)
    [#(next, _), ..] -> {
      let acc =
        list.fold(rows, acc, fn(acc, row) {
          case row.1 {
            Some(candidate) -> visit(scan, acc, candidate)
            None -> acc
          }
        })
      pages(scan, next, acc)
    }
    [] -> Error("could not read transcript search page")
  }
}

pub type Page {
  Page(count: Int, matches: List(Match))
}

/// Count every confirmed match while retaining only the chronological page.
/// Exact counts still require scanning every candidate inside the range.
pub fn page(
  ledger: store.Store,
  session: String,
  needle: String,
  first: Int,
  last: Int,
  offset: Int,
  limit: Int,
) -> Result(Page, String) {
  use snapshot <- result.try(conversation.snapshot(ledger, session))
  let scan =
    Scan(
      ledger,
      needle,
      probe(needle),
      Within(session),
      first,
      int.min(last, snapshot.upper),
      True,
      fn(_, _) { True },
      fn(page: Page, match) {
        let matches = case page.count >= offset && page.count - offset < limit {
          True -> [match, ..page.matches]
          False -> page.matches
        }
        Page(page.count + 1, matches)
      },
    )
  pages(scan, first - 1, Page(0, []))
  |> result.map(fn(page) { Page(page.count, list.reverse(page.matches)) })
}

/// `acc` stepped with `row` when its session is wanted and its text holds
/// the needle. Packed rows also match on field names and tags, so the text
/// decides.
fn visit(scan: Scan(a), acc: a, row: #(String, Int, BitArray)) -> a {
  let #(session, seq, payload) = row
  use <- bool.guard(!scan.wants(acc, session), acc)
  let text =
    conversation.read_input(scan.ledger, payload)
    |> result.map(tool.row_text)
    |> result.unwrap("")
  case string.contains(string.lowercase(text), scan.needle) {
    True -> scan.step(acc, Match(session, seq, text))
    False -> acc
  }
}

/// The longest ASCII stretch of `needle`: every row that contains the needle
/// contains it, and SQLite folds its case. "" (every row) when there is none.
fn probe(needle: String) -> String {
  let #(longest, _) =
    list.fold(string.to_graphemes(needle), #("", ""), fn(runs, grapheme) {
      let #(longest, current) = runs
      case string.byte_size(grapheme) == 1 {
        False -> #(longest, "")
        True -> {
          let current = current <> grapheme
          case string.length(current) > string.length(longest) {
            True -> #(current, current)
            False -> #(longest, current)
          }
        }
      }
    })
  longest
}

/// Up to 400 graphemes of `text` from a little before the first place it
/// contains `needle`, case-insensitively.
pub fn preview(text: String, needle: String) -> String {
  let at = case string.split_once(string.lowercase(text), needle) {
    Ok(#(before, _)) -> string.length(before)
    Error(_) -> 0
  }
  case at > 120 {
    True -> "…" <> tool.excerpt(string.drop_start(text, at - 100), 400)
    False -> tool.excerpt(text, 400)
  }
}

/// The rows of `session`'s durable transcript whose text contains `pattern`,
/// case-insensitively: a page of at most 20 seqs with previews, oldest first.
pub fn transcript_grep(
  ledger: store.Store,
  session: String,
  pattern: String,
  limit: Int,
  offset: Int,
) -> Result(json.Json, String) {
  use needle <- result.try(needle(pattern))
  use _ <- result.try(compaction.require(
    offset >= 0,
    "transcript search offset must be nonnegative",
  ))
  let limit = int.clamp(limit, 1, 20)
  use page <- result.try(page(
    ledger,
    session,
    needle,
    0,
    9_223_372_036_854_775_807,
    offset,
    limit,
  ))
  let next = offset + limit
  Ok(
    json.object([
      #("pattern", json.string(string.trim(pattern))),
      #("offset", json.int(offset)),
      #("count", json.int(page.count)),
      #("next_offset", tool.next_offset(next, next < page.count)),
      #(
        "rows",
        json.array(page.matches, fn(match) {
          json.object([
            #("seq", json.int(match.seq)),
            #("preview", json.string(preview(match.text, needle))),
          ])
        }),
      ),
    ]),
  )
}
