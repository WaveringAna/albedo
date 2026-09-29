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
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string

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

/// Every row in `scope` whose text contains `needle`, oldest first.
pub fn rows(
  ledger: store.Store,
  scope: Scope,
  needle: String,
) -> Result(List(Match), String) {
  fold(ledger, scope, needle, [], fn(_, _) { True }, fn(found, match) {
    [match, ..found]
  })
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
  let #(session, except, cwd) = case scope {
    Within(session) -> #(session, "", "")
    Beyond(caller, cwd) -> #("", caller, cwd)
  }
  use #(low, high) <- result.try(conversation.seq_bounds(ledger, session))
  let scan =
    Scan(ledger, needle, probe(needle), session, except, cwd, wants, step)
  windows(scan, low, high + 1, acc)
}

type Scan(a) {
  Scan(
    ledger: store.Store,
    needle: String,
    probe: String,
    session: String,
    except: String,
    cwd: String,
    wants: fn(a, String) -> Bool,
    step: fn(a, Match) -> a,
  )
}

/// Transcript rows one store call scans.
const window_rows = 2048

/// The rows from `low` up to `high`, one window at a time, newest first.
fn windows(scan: Scan(a), low: Int, high: Int, acc: a) -> Result(a, String) {
  case high <= low {
    True -> Ok(acc)
    False -> {
      let floor = int.max(low, high - window_rows)
      use rows <- result.try(conversation.candidates(
        scan.ledger,
        scan.probe,
        scan.session,
        scan.except,
        scan.cwd,
        floor,
        high,
      ))
      windows(
        scan,
        low,
        floor,
        list.fold(rows, acc, fn(acc, row) { visit(scan, acc, row) }),
      )
    }
  }
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
  use matches <- result.try(rows(ledger, Within(session), needle))
  let limit = int.clamp(limit, 1, 20)
  let next = offset + limit
  Ok(
    json.object([
      #("pattern", json.string(string.trim(pattern))),
      #("offset", json.int(offset)),
      #("count", json.int(list.length(matches))),
      #("next_offset", tool.next_offset(next, next < list.length(matches))),
      #(
        "rows",
        json.array(list.take(list.drop(matches, offset), limit), fn(match) {
          json.object([
            #("seq", json.int(match.seq)),
            #("preview", json.string(preview(match.text, needle))),
          ])
        }),
      ),
    ]),
  )
}
