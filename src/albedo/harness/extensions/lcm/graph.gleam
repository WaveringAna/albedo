//// Derived summary tree. The transcript remains the authority for every leaf.

import albedo/daemon/store
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import sqlight

pub type Node {
  Node(id: Int, depth: Int, first_seq: Int, last_seq: Int, summary: String)
}

pub type Leaf {
  Leaf(first_seq: Int, last_seq: Int, summary: String)
}

pub fn initialise(ledger: store.Store) -> Result(Nil, String) {
  store.query(ledger, fn(db) {
    sqlight.exec(
      "CREATE TABLE IF NOT EXISTS lcm_compaction_state(session TEXT PRIMARY KEY REFERENCES sessions(id),last_seq INTEGER NOT NULL CHECK(last_seq >= 0)); CREATE TABLE IF NOT EXISTS lcm_compaction_node(id INTEGER PRIMARY KEY AUTOINCREMENT,session TEXT NOT NULL REFERENCES sessions(id),depth INTEGER NOT NULL CHECK(depth >= 0),first_seq INTEGER NOT NULL,last_seq INTEGER NOT NULL,summary TEXT NOT NULL); CREATE INDEX IF NOT EXISTS lcm_compaction_node_session ON lcm_compaction_node(session,first_seq); CREATE TABLE IF NOT EXISTS lcm_compaction_edge(child INTEGER PRIMARY KEY REFERENCES lcm_compaction_node(id),parent INTEGER NOT NULL REFERENCES lcm_compaction_node(id),position INTEGER NOT NULL CHECK(position >= 0)); CREATE INDEX IF NOT EXISTS lcm_compaction_edge_parent ON lcm_compaction_edge(parent,position);",
      db,
    )
    |> result.replace(Nil)
    |> result.map_error(fn(error) { error.message })
  })
}

pub fn last_seq(ledger: store.Store, session: String) -> Result(Int, String) {
  store.query(ledger, fn(db) {
    sqlight.query(
      "SELECT last_seq FROM lcm_compaction_state WHERE session=?",
      db,
      [sqlight.text(session)],
      decode.field(0, decode.int, decode.success),
    )
    |> result.map_error(fn(error) { error.message })
    |> result.map(fn(rows) {
      case rows {
        [value] -> value
        _ -> 0
      }
    })
  })
}

pub fn frontier(
  ledger: store.Store,
  session: String,
) -> Result(List(Node), String) {
  store.query(ledger, fn(db) {
    sqlight.query(
      "SELECT n.id,n.depth,n.first_seq,n.last_seq,n.summary FROM lcm_compaction_node n LEFT JOIN lcm_compaction_edge e ON e.child=n.id WHERE n.session=? AND e.child IS NULL ORDER BY n.first_seq,n.id",
      db,
      [sqlight.text(session)],
      node_decoder(),
    )
    |> result.map_error(fn(error) { error.message })
  })
}

pub fn all_nodes(
  ledger: store.Store,
  session: String,
) -> Result(List(Node), String) {
  store.query(ledger, fn(db) {
    sqlight.query(
      "SELECT id,depth,first_seq,last_seq,summary FROM lcm_compaction_node WHERE session=? ORDER BY id",
      db,
      [sqlight.text(session)],
      node_decoder(),
    )
    |> result.map_error(fn(error) { error.message })
  })
}

pub fn node(
  ledger: store.Store,
  session: String,
  id: Int,
) -> Result(Option(Node), String) {
  store.query(ledger, fn(db) {
    sqlight.query(
      "SELECT id,depth,first_seq,last_seq,summary FROM lcm_compaction_node WHERE session=? AND id=?",
      db,
      [sqlight.text(session), sqlight.int(id)],
      node_decoder(),
    )
    |> result.map_error(fn(error) { error.message })
    |> result.map(fn(rows) {
      case rows {
        [value] -> Some(value)
        _ -> None
      }
    })
  })
}

pub fn children(ledger: store.Store, parent: Int) -> Result(List(Int), String) {
  store.query(ledger, fn(db) {
    sqlight.query(
      "SELECT child FROM lcm_compaction_edge WHERE parent=? ORDER BY position",
      db,
      [sqlight.int(parent)],
      decode.field(0, decode.int, decode.success),
    )
    |> result.map_error(fn(error) { error.message })
  })
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
  use installed <- result.try(
    sqlight.query(
      "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='lcm_compaction_node'",
      db,
      [],
      decode.field(0, decode.int, decode.success),
    )
    |> result.map_error(fn(error) { error.message }),
  )
  case installed {
    [0] -> Ok(Nil)
    [1] -> {
      use nodes <- result.try(
        sqlight.query(
          "SELECT id,depth,first_seq,last_seq,summary FROM lcm_compaction_node WHERE session=? AND last_seq<=? ORDER BY id",
          db,
          [sqlight.text(source), sqlight.int(checkpoint)],
          node_decoder(),
        )
        |> result.map_error(fn(error) { error.message }),
      )
      case nodes {
        [] -> Ok(Nil)
        _ -> inherit_nodes(db, source, branch, checkpoint, source_seqs, nodes)
      }
    }
    _ -> Error("could not inspect installed LCM storage")
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
  use branch_seqs <- result.try(
    sqlight.query(
      "SELECT seq FROM transcript WHERE session=? ORDER BY seq",
      db,
      [sqlight.text(branch)],
      decode.field(0, decode.int, decode.success),
    )
    |> result.map_error(fn(error) { error.message }),
  )
  use seq_map <- result.try(pair_sequences(source_seqs, branch_seqs, dict.new()))
  use node_map <- result.try(
    list.fold(nodes, Ok(dict.new()), fn(state, node) {
      use state <- result.try(state)
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
      Ok(dict.insert(state, node.id, id))
    }),
  )
  use edges <- result.try(
    sqlight.query(
      "SELECT e.child,e.parent,e.position FROM lcm_compaction_edge e JOIN lcm_compaction_node p ON p.id=e.parent WHERE p.session=? AND p.last_seq<=? ORDER BY e.parent,e.position",
      db,
      [sqlight.text(source), sqlight.int(checkpoint)],
      {
        use child <- decode.field(0, decode.int)
        use parent <- decode.field(1, decode.int)
        use position <- decode.field(2, decode.int)
        decode.success(#(child, parent, position))
      },
    )
    |> result.map_error(fn(error) { error.message }),
  )
  use _ <- result.try(
    list.try_each(edges, fn(edge) {
      use child <- result.try(mapped(node_map, edge.0))
      use parent <- result.try(mapped(node_map, edge.1))
      sqlight.query(
        "INSERT INTO lcm_compaction_edge(child,parent,position) VALUES(?,?,?)",
        db,
        [sqlight.int(child), sqlight.int(parent), sqlight.int(edge.2)],
        decode.dynamic,
      )
      |> result.replace(Nil)
      |> result.map_error(fn(error) { error.message })
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
      sqlight.query(
        "INSERT INTO lcm_compaction_state(session,last_seq) VALUES(?,?)",
        db,
        [sqlight.text(branch), sqlight.int(remapped)],
        decode.dynamic,
      )
      |> result.replace(Nil)
      |> result.map_error(fn(error) { error.message })
    }
  }
}

fn pair_sequences(
  source: List(Int),
  branch: List(Int),
  pairs: Dict(Int, Int),
) -> Result(Dict(Int, Int), String) {
  case source, branch {
    [], [] -> Ok(pairs)
    [old, ..old_rest], [new, ..new_rest] ->
      pair_sequences(old_rest, new_rest, dict.insert(pairs, old, new))
    _, _ -> Error("fork transcript copy changed its source row count")
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
        use _ <- result.try(begin(db))
        let written = {
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
          sqlight.query(
            "INSERT INTO lcm_compaction_state(session,last_seq) VALUES(?,?) ON CONFLICT(session) DO UPDATE SET last_seq=excluded.last_seq",
            db,
            [sqlight.text(session), sqlight.int(last.last_seq)],
            decode.dynamic,
          )
          |> result.replace(Nil)
          |> result.map_error(fn(error) { error.message })
        }
        finish(db, written)
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
  case children {
    [first, _, ..] ->
      case list.last(children) {
        Error(_) -> Error("LCM cannot condense an empty node group")
        Ok(last) ->
          store.query(ledger, fn(db) {
            use _ <- result.try(begin(db))
            let written = {
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
                sqlight.query(
                  "INSERT INTO lcm_compaction_edge(child,parent,position) VALUES(?,?,?)",
                  db,
                  [
                    sqlight.int(item.0),
                    sqlight.int(parent),
                    sqlight.int(item.1),
                  ],
                  decode.dynamic,
                )
                |> result.replace(Nil)
                |> result.map_error(fn(error) { error.message })
              })
            }
            finish(db, written)
          })
      }
    _ -> Error("LCM needs at least two nodes to condense")
  }
}

fn node_decoder() {
  use id <- decode.field(0, decode.int)
  use depth <- decode.field(1, decode.int)
  use first <- decode.field(2, decode.int)
  use last <- decode.field(3, decode.int)
  use summary <- decode.field(4, decode.string)
  decode.success(Node(id, depth, first, last, summary))
}

fn insert_node(
  db,
  session: String,
  depth: Int,
  first: Int,
  last: Int,
  summary: String,
) -> Result(Int, String) {
  sqlight.query(
    "INSERT INTO lcm_compaction_node(session,depth,first_seq,last_seq,summary) VALUES(?,?,?,?,?) RETURNING id",
    db,
    [
      sqlight.text(session),
      sqlight.int(depth),
      sqlight.int(first),
      sqlight.int(last),
      sqlight.text(summary),
    ],
    decode.field(0, decode.int, decode.success),
  )
  |> result.map_error(fn(error) { error.message })
  |> result.try(fn(rows) {
    case rows {
      [id] -> Ok(id)
      _ -> Error("LCM node insert returned no identity")
    }
  })
}

fn begin(db) -> Result(Nil, String) {
  sqlight.exec("BEGIN IMMEDIATE", db)
  |> result.replace(Nil)
  |> result.map_error(fn(error) { error.message })
}

fn finish(db, written: Result(Nil, String)) -> Result(Nil, String) {
  case written {
    Ok(_) ->
      sqlight.exec("COMMIT", db)
      |> result.replace(Nil)
      |> result.map_error(fn(error) { error.message })
    Error(error) -> {
      let _ = sqlight.exec("ROLLBACK", db)
      Error(error)
    }
  }
}
