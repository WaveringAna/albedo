//// Sessions as agents find them: every session, most recently active first,
//// narrowed to one directory and to those a query names or talks about.

import albedo/daemon/conversation
import albedo/daemon/store
import albedo/harness/search
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/list
import gleam/result
import gleam/string
import sqlight

/// One message row that contains the query, with the text around it.
pub type Hit {
  Hit(seq: Int, preview: String)
}

/// A session and its newest hits; none when only its name matched, or when
/// there was no query.
pub type Found {
  Found(info: conversation.Info, hits: List(Hit))
}

/// Hits kept per session: enough to show why it matched.
const hits_per_session = 3

/// Every session opened in `cwd` ("" for all), most recently active first.
/// A nonblank `query` keeps those whose title, given name, or family name
/// contains it case-insensitively, and those whose messages do. The caller's
/// own messages are not searched: they would always hold the query.
pub fn find(
  db: store.Store,
  caller: String,
  query: String,
  cwd: String,
) -> Result(List(Found), String) {
  use listed <- result.try(listed(db, cwd))
  case string.trim(query) {
    "" -> Ok(list.map(listed, fn(pair) { Found(pair.0, []) }))
    _ -> {
      use needle <- result.try(search.needle(query))
      use hits <- result.try(
        search.fold(
          db,
          search.Beyond(caller, cwd),
          needle,
          dict.new(),
          fn(hits, session) {
            list.length(hit_list(hits, session)) < hits_per_session
          },
          fn(hits, match) {
            let hit = Hit(match.seq, search.preview(match.text, needle))
            dict.insert(hits, match.session, [
              hit,
              ..hit_list(hits, match.session)
            ])
          },
        ),
      )
      listed
      |> list.filter_map(fn(pair) {
        let #(info, name) = pair
        let found = dict.get(hits, info.id) |> result.map(list.reverse)
        let named =
          string.contains(string.lowercase(info.title <> "\n" <> name), needle)
        case found, named {
          Ok(hits), _ -> Ok(Found(info, hits))
          Error(_), True -> Ok(Found(info, []))
          Error(_), False -> Error(Nil)
        }
      })
      |> Ok
    }
  }
}

/// Sessions in `cwd` in activity order, each with its family name ("" for
/// a root).
fn listed(
  db: store.Store,
  cwd: String,
) -> Result(List(#(conversation.Info, String)), String) {
  store.read(
    db,
    "SELECT "
      <> conversation.info_columns
      <> ",COALESCE((SELECT name FROM session_family WHERE session=sessions.id),'') FROM sessions WHERE ?='' OR cwd=? ORDER BY activity_seq DESC,rowid DESC",
    [sqlight.text(cwd), sqlight.text(cwd)],
    {
      use info <- decode.then(conversation.info_decoder())
      use name <- decode.field(9, decode.string)
      decode.success(#(info, name))
    },
  )
}

fn hit_list(hits: Dict(String, List(Hit)), session: String) -> List(Hit) {
  dict.get(hits, session) |> result.unwrap([])
}
