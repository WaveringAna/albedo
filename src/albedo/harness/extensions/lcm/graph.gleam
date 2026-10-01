//// Derived summary tree. The transcript remains the authority for every leaf.

import albedo/daemon/store
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import sqlight

pub type Node {
  Node(id: Int, depth: Int, first_seq: Int, last_seq: Int, summary: String)
}

pub type Leaf {
  Leaf(first_seq: Int, last_seq: Int, summary: String)
}

pub fn initialise(ledger: store.Store) -> Result(Nil, String) {
  store.query(ledger, fn(db) {
    store.exec(
      db,
      "CREATE TABLE IF NOT EXISTS lcm_compaction_state(session TEXT PRIMARY KEY REFERENCES sessions(id),last_seq INTEGER NOT NULL CHECK(last_seq >= 0)); CREATE TABLE IF NOT EXISTS lcm_compaction_node(id INTEGER PRIMARY KEY AUTOINCREMENT,session TEXT NOT NULL REFERENCES sessions(id),depth INTEGER NOT NULL CHECK(depth >= 0),first_seq INTEGER NOT NULL,last_seq INTEGER NOT NULL,summary TEXT NOT NULL); CREATE INDEX IF NOT EXISTS lcm_compaction_node_session ON lcm_compaction_node(session,first_seq); CREATE TABLE IF NOT EXISTS lcm_compaction_edge(child INTEGER PRIMARY KEY REFERENCES lcm_compaction_node(id),parent INTEGER NOT NULL REFERENCES lcm_compaction_node(id),position INTEGER NOT NULL CHECK(position >= 0)); CREATE INDEX IF NOT EXISTS lcm_compaction_edge_parent ON lcm_compaction_edge(parent,position);",
    )
  })
}

/// Deletes a session's summary graph, edges first: they reference its nodes.
pub fn forget_session(
  db: sqlight.Connection,
  session: String,
) -> Result(Nil, String) {
  use _ <- result.try(
    store.run(
      db,
      "DELETE FROM lcm_compaction_edge WHERE child IN (SELECT id FROM lcm_compaction_node WHERE session=?1) OR parent IN (SELECT id FROM lcm_compaction_node WHERE session=?1)",
      [sqlight.text(session)],
    ),
  )
  store.forget_session(
    db,
    ["lcm_compaction_state", "lcm_compaction_node"],
    session,
  )
}

/// The single row `sql` answers, or `None` when it answers none.
fn one_row(
  ledger: store.Store,
  sql: String,
  arguments: List(sqlight.Value),
  decoder: decode.Decoder(a),
) -> Result(Option(a), String) {
  store.read(ledger, sql, arguments, decoder)
  |> result.map(fn(rows) {
    case rows {
      [value] -> Some(value)
      _ -> None
    }
  })
}

pub fn storage_available(ledger: store.Store) -> Result(Bool, String) {
  one_row(
    ledger,
    "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='lcm_compaction_node'",
    [],
    decode.field(0, decode.int, decode.success),
  )
  |> result.map(fn(count) { count == Some(1) })
}

pub fn last_seq(ledger: store.Store, session: String) -> Result(Int, String) {
  one_row(
    ledger,
    "SELECT last_seq FROM lcm_compaction_state WHERE session=?",
    [sqlight.text(session)],
    decode.field(0, decode.int, decode.success),
  )
  |> result.map(fn(value) { option.unwrap(value, 0) })
}

pub fn frontier(
  ledger: store.Store,
  session: String,
) -> Result(List(Node), String) {
  store.read(
    ledger,
    "SELECT n.id,n.depth,n.first_seq,n.last_seq,n.summary FROM lcm_compaction_node n LEFT JOIN lcm_compaction_edge e ON e.child=n.id WHERE n.session=? AND e.child IS NULL ORDER BY n.first_seq,n.id",
    [sqlight.text(session)],
    node_decoder(),
  )
}

pub fn node(
  ledger: store.Store,
  session: String,
  id: Int,
) -> Result(Option(Node), String) {
  one_row(
    ledger,
    "SELECT id,depth,first_seq,last_seq,summary FROM lcm_compaction_node WHERE session=? AND id=?",
    [sqlight.text(session), sqlight.int(id)],
    node_decoder(),
  )
}

pub fn children(ledger: store.Store, parent: Int) -> Result(List(Int), String) {
  store.read(
    ledger,
    "SELECT child FROM lcm_compaction_edge WHERE parent=? ORDER BY position",
    [sqlight.int(parent)],
    decode.field(0, decode.int, decode.success),
  )
}

/// Copy only summary nodes whose complete source span survives a transcript
/// fork. The fork transaction owns this connection, so either transcript and
/// remapped graph both commit or neither does. A node crossing the checkpoint
/// is omitted; its complete children can still become the branch frontier.
pub fn inherit_fork_prefix(
  db: sqlight.Connection,
  source: String,
  branch: String,
  checkpoint: Int,
  source_seqs: List(Int),
) -> Result(Nil, String) {
  use installed <- result.try(store.rows(
    db,
    "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='lcm_compaction_node'",
    [],
    decode.field(0, decode.int, decode.success),
  ))
  use nodes <- result.try(case installed {
    [0] -> Ok([])
    [1] ->
      store.rows(
        db,
        "SELECT id,depth,first_seq,last_seq,summary FROM lcm_compaction_node WHERE session=? AND last_seq<=? ORDER BY id",
        [sqlight.text(source), sqlight.int(checkpoint)],
        node_decoder(),
      )
    _ -> Error("could not inspect installed LCM storage")
  })
  case nodes {
    [] -> Ok(Nil)
    _ -> inherit_nodes(db, source, branch, checkpoint, source_seqs, nodes)
  }
}

fn inherit_nodes(
  db: sqlight.Connection,
  source: String,
  branch: String,
  checkpoint: Int,
  source_seqs: List(Int),
  nodes: List(Node),
) -> Result(Nil, String) {
  use branch_seqs <- result.try(store.rows(
    db,
    "SELECT seq FROM transcript WHERE session=? ORDER BY seq",
    [sqlight.text(branch)],
    decode.field(0, decode.int, decode.success),
  ))
  use seq_map <- result.try(
    list.strict_zip(source_seqs, branch_seqs)
    |> result.map(dict.from_list)
    |> result.replace_error("fork transcript copy changed its source row count"),
  )
  use node_map <- result.try(
    list.try_fold(nodes, dict.new(), fn(node_map, node) {
      use first <- result.try(mapped(seq_map, node.first_seq))
      use last <- result.try(mapped(seq_map, node.last_seq))
      use id <- result.try(insert_node(
        db,
        branch,
        node.depth,
        first,
        last,
        node.summary,
      ))
      Ok(dict.insert(node_map, node.id, id))
    }),
  )
  use edges <- result.try(
    store.rows(
      db,
      "SELECT e.child,e.parent,e.position FROM lcm_compaction_edge e JOIN lcm_compaction_node p ON p.id=e.parent WHERE p.session=? AND p.last_seq<=? ORDER BY e.parent,e.position",
      [sqlight.text(source), sqlight.int(checkpoint)],
      {
        use child <- decode.field(0, decode.int)
        use parent <- decode.field(1, decode.int)
        use position <- decode.field(2, decode.int)
        decode.success(#(child, parent, position))
      },
    ),
  )
  use _ <- result.try(
    list.try_each(edges, fn(edge) {
      use child <- result.try(mapped(node_map, edge.0))
      use parent <- result.try(mapped(node_map, edge.1))
      store.run(
        db,
        "INSERT INTO lcm_compaction_edge(child,parent,position) VALUES(?,?,?)",
        [sqlight.int(child), sqlight.int(parent), sqlight.int(edge.2)],
      )
    }),
  )
  let covered =
    list.fold(nodes, 0, fn(highest, node) {
      case node.depth == 0 {
        True -> int.max(highest, node.last_seq)
        False -> highest
      }
    })
  case covered {
    0 -> Ok(Nil)
    covered -> {
      use remapped <- result.try(mapped(seq_map, covered))
      store.run(
        db,
        "INSERT INTO lcm_compaction_state(session,last_seq) VALUES(?,?)",
        [sqlight.text(branch), sqlight.int(remapped)],
      )
    }
  }
}

fn mapped(mapping: Dict(Int, Int), original: Int) -> Result(Int, String) {
  dict.get(mapping, original)
  |> result.replace_error("fork has no matching source row")
}

/// A failed summary never advances the cursor. Persist a complete successful
/// batch and its last covered source in one transaction.
pub fn save_leaves(
  ledger: store.Store,
  session: String,
  leaves: List(Leaf),
) -> Result(Nil, String) {
  case list.last(leaves) {
    Error(_) -> Ok(Nil)
    Ok(last) ->
      store.query(ledger, fn(db) {
        store.transaction(db, fn() {
          use _ <- result.try(
            list.try_each(leaves, fn(leaf) {
              insert_node(
                db,
                session,
                0,
                leaf.first_seq,
                leaf.last_seq,
                leaf.summary,
              )
              |> result.replace(Nil)
            }),
          )
          store.run(
            db,
            "INSERT INTO lcm_compaction_state(session,last_seq) VALUES(?,?) ON CONFLICT(session) DO UPDATE SET last_seq=excluded.last_seq",
            [sqlight.text(session), sqlight.int(last.last_seq)],
          )
        })
      })
  }
}

/// Condensed nodes point to existing children; leaf ranges still lead directly
/// to the immutable transcript. Only one parent can claim each child.
pub fn save_parent(
  ledger: store.Store,
  session: String,
  children: List(Node),
  summary: String,
) -> Result(Nil, String) {
  case children, list.last(children) {
    [first, _, ..], Ok(last) ->
      store.query(ledger, fn(db) {
        store.transaction(db, fn() {
          let depth =
            1
            + list.fold(children, 0, fn(highest, child) {
              int.max(highest, child.depth)
            })
          use parent <- result.try(insert_node(
            db,
            session,
            depth,
            first.first_seq,
            last.last_seq,
            summary,
          ))
          children
          |> list.index_map(fn(child, position) { #(child.id, position) })
          |> list.try_each(fn(item) {
            store.run(
              db,
              "INSERT INTO lcm_compaction_edge(child,parent,position) VALUES(?,?,?)",
              [
                sqlight.int(item.0),
                sqlight.int(parent),
                sqlight.int(item.1),
              ],
            )
          })
        })
      })
    _, _ -> Error("LCM needs at least two nodes to condense")
  }
}

fn node_decoder() -> decode.Decoder(Node) {
  use id <- decode.field(0, decode.int)
  use depth <- decode.field(1, decode.int)
  use first <- decode.field(2, decode.int)
  use last <- decode.field(3, decode.int)
  use summary <- decode.field(4, decode.string)
  decode.success(Node(id, depth, first, last, summary))
}

fn insert_node(
  db: sqlight.Connection,
  session: String,
  depth: Int,
  first: Int,
  last: Int,
  summary: String,
) -> Result(Int, String) {
  use rows <- result.try(store.rows(
    db,
    "INSERT INTO lcm_compaction_node(session,depth,first_seq,last_seq,summary) VALUES(?,?,?,?,?) RETURNING id",
    [
      sqlight.text(session),
      sqlight.int(depth),
      sqlight.int(first),
      sqlight.int(last),
      sqlight.text(summary),
    ],
    decode.field(0, decode.int, decode.success),
  ))
  case rows {
    [id] -> Ok(id)
    _ -> Error("LCM node insert returned no identity")
  }
}

pub type NodeListPage {
  NodeListPage(total: Int, nodes: List(#(Node, Bool)))
}

/// Count and fetch one node page in the same store turn. Frontier membership
/// is determined for returned nodes without loading every summary.
pub fn list_page(
  ledger: store.Store,
  session: String,
  limit: Int,
  offset: Int,
) -> Result(NodeListPage, String) {
  store.query(ledger, fn(db) {
    use total <- result.try(store.one(
      db,
      "SELECT COUNT(*) FROM lcm_compaction_node WHERE session=?",
      [sqlight.text(session)],
      decode.field(0, decode.int, decode.success),
      "could not count LCM nodes",
    ))
    use nodes <- result.try(
      store.rows(
        db,
        "SELECT n.id,n.depth,n.first_seq,n.last_seq,n.summary,NOT EXISTS(SELECT 1 FROM lcm_compaction_edge e WHERE e.child=n.id) FROM lcm_compaction_node n WHERE n.session=? ORDER BY n.id LIMIT ? OFFSET ?",
        [sqlight.text(session), sqlight.int(limit), sqlight.int(offset)],
        {
          use node <- decode.then(node_decoder())
          use frontier <- decode.field(5, decode.int)
          decode.success(#(node, frontier == 1))
        },
      ),
    )
    Ok(NodeListPage(total, nodes))
  })
}

pub type NodeSearchPage {
  NodeSearchPage(count: Int, nodes: List(Node))
}

/// Unicode matching remains in Gleam; SQLite lower only folds ASCII. Count
/// every match in the scoped range while retaining only the requested page.
pub fn search_page(
  ledger: store.Store,
  session: String,
  scope: Option(Node),
  needle: String,
  limit: Int,
  offset: Int,
) -> Result(NodeSearchPage, String) {
  let #(where, arguments) = case scope {
    None -> #("session=?", [sqlight.text(session)])
    Some(node) -> #("session=? AND first_seq>=? AND last_seq<=?", [
      sqlight.text(session),
      sqlight.int(node.first_seq),
      sqlight.int(node.last_seq),
    ])
  }
  use upper <- result.try(one_row(
    ledger,
    "SELECT COALESCE(MAX(id),0) FROM lcm_compaction_node WHERE " <> where,
    arguments,
    decode.field(0, decode.int, decode.success),
  ))
  search_node_pages(
    ledger,
    where,
    arguments,
    option.unwrap(upper, 0),
    0,
    needle,
    limit,
    offset,
    NodeSearchPage(0, []),
  )
  |> result.map(fn(page) {
    NodeSearchPage(page.count, list.reverse(page.nodes))
  })
}

fn search_node_pages(
  ledger: store.Store,
  where: String,
  arguments: List(sqlight.Value),
  upper: Int,
  after: Int,
  needle: String,
  limit: Int,
  offset: Int,
  page: NodeSearchPage,
) -> Result(NodeSearchPage, String) {
  use nodes <- result.try(store.read(
    ledger,
    "SELECT id,depth,first_seq,last_seq,summary FROM lcm_compaction_node WHERE "
      <> where
      <> " AND id>? AND id<=? ORDER BY id LIMIT 128",
    list.append(arguments, [sqlight.int(after), sqlight.int(upper)]),
    node_decoder(),
  ))
  let page =
    list.fold(nodes, page, fn(page, node) {
      case string.contains(string.lowercase(node.summary), needle) {
        False -> page
        True -> {
          let kept = case page.count >= offset && page.count - offset < limit {
            True -> [node, ..page.nodes]
            False -> page.nodes
          }
          NodeSearchPage(page.count + 1, kept)
        }
      }
    })
  case list.last(nodes) {
    Error(_) -> Ok(page)
    Ok(last) ->
      case list.length(nodes) < 128 {
        True -> Ok(page)
        False ->
          search_node_pages(
            ledger,
            where,
            arguments,
            upper,
            last.id,
            needle,
            limit,
            offset,
            page,
          )
      }
  }
}

/// The first frontier node covering each requested source, in frontier order.
/// Only IDs are read; retrieval pages do not need every frontier summary.
pub fn covering_nodes(
  ledger: store.Store,
  session: String,
  seqs: List(Int),
) -> Result(Dict(Int, Int), String) {
  store.query(ledger, fn(db) {
    list.try_fold(seqs, dict.new(), fn(found, seq) {
      use rows <- result.try(store.rows(
        db,
        "SELECT n.id FROM lcm_compaction_node n WHERE n.session=? AND n.first_seq<=? AND n.last_seq>=? AND NOT EXISTS(SELECT 1 FROM lcm_compaction_edge e WHERE e.child=n.id) ORDER BY n.first_seq,n.id LIMIT 1",
        [sqlight.text(session), sqlight.int(seq), sqlight.int(seq)],
        decode.field(0, decode.int, decode.success),
      ))
      Ok(case rows {
        [id] -> dict.insert(found, seq, id)
        _ -> found
      })
    })
  })
}
