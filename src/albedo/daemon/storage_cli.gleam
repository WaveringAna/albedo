//// Standalone storage helpers. Never initialize or migrate application storage.

import albedo/daemon/server
import albedo/daemon/store
import gleam/dict
import gleam/dynamic/decode
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import sqlight

pub type FileIdentity

@external(erlang, "albedo_storage_cli", "arguments")
pub fn arguments() -> List(String)

@external(erlang, "albedo_storage_cli", "identity")
fn identity(path: String) -> Result(Option(FileIdentity), String)

@external(erlang, "albedo_storage_cli", "bytes")
fn bytes(identity: FileIdentity) -> Int

@external(erlang, "albedo_storage_cli", "copy")
fn copy(source: String, destination: String) -> Result(Nil, String)

@external(erlang, "albedo_storage_cli", "remove")
pub fn remove(path: String) -> Result(Nil, String)

@external(erlang, "albedo_storage_cli", "database_uri")
fn database_uri(path: String, mode: String) -> String

@external(erlang, "albedo_storage_cli", "read_line")
fn read_line() -> Result(Option(String), String)

@external(erlang, "albedo_storage_cli", "watch_owner")
fn watch_owner() -> Nil

@external(erlang, "albedo_storage_cli", "halt")
fn halt(code: Int) -> Nil

type SessionBytes {
  SessionBytes(id: String, bytes: Int)
}

type Authorization {
  Authorization(apply: Bool, vacuum: Bool, before: Int, free_pages: Int)
}

pub fn main(arguments: List(String)) -> Nil {
  let outcome = case arguments {
    ["storage", "inspect", database, scratch] -> inspect(database, scratch)
    ["storage", "maintain", home] -> maintain(home, remove, vacuum)
    _ ->
      Error(
        "usage: albedo-daemon storage inspect <database> <scratch-directory> | storage maintain <home>",
      )
  }
  finish(outcome)
}

pub fn finish(outcome: Result(Nil, String)) -> Nil {
  case outcome {
    Ok(_) -> halt(0)
    Error(error) -> {
      io.println_error(error)
      halt(1)
    }
  }
}

fn required_identity(path: String) -> Result(FileIdentity, String) {
  use found <- result.try(identity(path))
  case found {
    Some(value) -> Ok(value)
    None -> Error("file disappeared: " <> path)
  }
}

fn inspect(path: String, scratch: String) -> Result(Nil, String) {
  let sources = [path, path <> "-wal"]
  use before <- result.try(list.try_map(sources, identity))
  use _ <- result.try(case before {
    [None, ..] ->
      Error("database disappeared before offline inspection; retry the report")
    _ -> Ok(Nil)
  })
  let snapshot = scratch <> "/albedo.sqlite"
  use _ <- result.try(
    list.zip(list.zip(sources, before), [snapshot, snapshot <> "-wal"])
    |> list.try_each(fn(entry) {
      let #(#(source, found), target) = entry
      case found {
        None -> Ok(Nil)
        Some(_) -> copy(source, target)
      }
    }),
  )
  use after <- result.try(list.try_map(sources, identity))
  use _ <- result.try(case before == after {
    True -> Ok(Nil)
    False ->
      Error(
        "storage changed while copying the offline snapshot; retry the report or query the running daemon",
      )
  })
  use report <- result.try(
    with_database(snapshot, "ro", fn(connection) {
      use _ <- result.try(store.exec(connection, "PRAGMA query_only=ON"))
      projection(connection)
    }),
  )
  io.println(json.to_string(report))
  Ok(Nil)
}

fn with_database(
  path: String,
  mode: String,
  run: fn(sqlight.Connection) -> Result(a, String),
) -> Result(a, String) {
  use connection <- result.try(
    sqlight.open(database_uri(path, mode))
    |> result.map_error(fn(error) {
      case error.message {
        "" -> "could not open SQLite database: " <> path
        message -> message
      }
    }),
  )
  let outcome = run(connection)
  let _ = sqlight.close(connection)
  outcome
}

fn columns(
  connection: sqlight.Connection,
  table: String,
  required: List(String),
) -> Result(List(String), String) {
  use found <- result.try(
    store.rows(connection, "PRAGMA table_info(" <> table <> ")", [], {
      use name <- decode.field(1, decode.string)
      decode.success(name)
    }),
  )
  let missing = list.filter(required, fn(name) { !list.contains(found, name) })
  case missing {
    [] -> Ok(found)
    _ ->
      Error(
        "unsupported storage layout: "
        <> table
        <> " lacks "
        <> string.join(missing, ", ")
        <> "; use a compatible daemon to inspect or upgrade this database",
      )
  }
}

fn projection(connection: sqlight.Connection) -> Result(json.Json, String) {
  use tables <- result.try(
    store.rows(
      connection,
      "SELECT name FROM sqlite_master WHERE type='table'",
      [],
      {
        use name <- decode.field(0, decode.string)
        decode.success(name)
      },
    ),
  )
  use session_columns <- result.try(columns(connection, "sessions", ["id"]))
  use _ <- result.try(columns(connection, "transcript", ["session", "payload"]))
  let pinned = case list.contains(session_columns, "pinned_context") {
    True -> "COALESCE(length(pinned_context),0)"
    False -> "0"
  }
  use sessions <- result.try(
    store.rows(
      connection,
      "SELECT id," <> pinned <> " FROM sessions ORDER BY id",
      [],
      {
        use id <- decode.field(0, decode.string)
        use bytes <- decode.field(1, decode.int)
        decode.success(SessionBytes(id, bytes))
      },
    )
    |> result.map_error(fn(_) {
      "unsupported storage layout: invalid session identity; use a compatible daemon to inspect this database"
    }),
  )
  let identities = list.map(sessions, fn(session) { session.id })
  use _ <- result.try(case list.any(identities, fn(id) { id == "" }) {
    True ->
      Error(
        "unsupported storage layout: invalid session identity; use a compatible daemon to inspect this database",
      )
    False -> Ok(Nil)
  })
  use _ <- result.try(
    case list.length(list.unique(identities)) == list.length(identities) {
      True -> Ok(Nil)
      False ->
        Error(
          "unsupported storage layout: duplicate session identities; use a compatible daemon to inspect this database",
        )
    },
  )
  use sessions <- result.try(add_sizes(
    connection,
    sessions,
    "SELECT session,COALESCE(sum(length(payload)),0) FROM transcript GROUP BY session",
  ))
  use sessions <- result.try(case list.contains(tables, "transcript_traces") {
    False -> Ok(sessions)
    True -> {
      use _ <- result.try(
        columns(connection, "transcript_traces", [
          "session",
          "cell_id",
          "payload",
        ]),
      )
      add_sizes(
        connection,
        sessions,
        "SELECT session,COALESCE(sum(length(CAST(payload AS BLOB))),0) FROM transcript_traces GROUP BY session",
      )
    }
  })
  use _ <- result.try(case list.contains(tables, "cell_traces") {
    False -> Ok([])
    True -> columns(connection, "cell_traces", ["id", "payload"])
  })
  use sessions <- result.try(case list.contains(tables, "cells") {
    False -> Ok(sessions)
    True -> {
      use _ <- result.try(
        columns(connection, "cells", ["id", "session", "source", "payload"]),
      )
      let #(join, trace) = case list.contains(tables, "cell_traces") {
        True -> #(
          "LEFT JOIN cell_traces t ON t.id=c.id",
          "COALESCE(length(t.payload),0)",
        )
        False -> #("", "0")
      }
      add_sizes(
        connection,
        sessions,
        "SELECT c.session,COALESCE(sum(length(c.source)+COALESCE(length(c.payload),0)+"
          <> trace
          <> "),0) FROM cells c "
          <> join
          <> " GROUP BY c.session",
      )
    }
  })
  use images <- result.try(case list.contains(tables, "images") {
    False -> Ok(0)
    True -> {
      use _ <- result.try(columns(connection, "images", ["data"]))
      scalar(connection, "SELECT COALESCE(sum(length(data)),0) FROM images")
    }
  })
  use free_pages <- result.try(scalar(connection, "PRAGMA freelist_count"))
  use page_size <- result.try(scalar(connection, "PRAGMA page_size"))
  Ok(
    json.object([
      #(
        "sessions",
        json.array(sessions, fn(session) {
          json.object([
            #("id", json.string(session.id)),
            #("bytes", json.int(session.bytes)),
          ])
        }),
      ),
      #("images", json.int(images)),
      #("free_pages", json.int(free_pages)),
      #("page_size", json.int(page_size)),
    ]),
  )
}

fn add_sizes(
  connection: sqlight.Connection,
  sessions: List(SessionBytes),
  sql: String,
) -> Result(List(SessionBytes), String) {
  use sizes <- result.try(
    store.rows(connection, sql, [], {
      use id <- decode.field(0, decode.optional(decode.string))
      use bytes <- decode.field(1, decode.int)
      decode.success(#(id, bytes))
    }),
  )
  let sizes = dict.from_list(sizes)
  Ok(
    list.map(sessions, fn(session) {
      SessionBytes(
        ..session,
        bytes: session.bytes
          + result.unwrap(dict.get(sizes, Some(session.id)), 0),
      )
    }),
  )
}

fn scalar(connection: sqlight.Connection, sql: String) -> Result(Int, String) {
  store.one(
    connection,
    sql,
    [],
    {
      use value <- decode.field(0, decode.int)
      decode.success(value)
    },
    "missing storage accounting value",
  )
}

pub fn vacuum(path: String) -> Result(Nil, String) {
  with_database(path, "rw", store.exec(_, "VACUUM"))
}

/// The caller owns the home lock for this whole handshake. Effect callbacks
/// let lifetime tests pause actual work without production environment hooks.
pub fn maintain(
  home: String,
  remove_file: fn(String) -> Result(Nil, String),
  vacuum_database: fn(String) -> Result(Nil, String),
) -> Result(Nil, String) {
  use _ <- result.try(
    server.claim_home(home)
    |> result.map_error(fn(error) {
      case error.code {
        sqlight.Busy | sqlight.Locked ->
          "storage is in use by an Albedo daemon or maintenance command; stop Albedo after its work finishes, or wait for maintenance, then try again; no files have been removed"
        _ ->
          case error.message {
            "" -> "could not claim storage: " <> home
            message -> message
          }
      }
    }),
  )
  use line <- result.try(read_line())
  use paths <- result.try(case line {
    None -> Error("missing maintenance candidates")
    Some(line) ->
      json.parse(line, {
        use paths <- decode.field("paths", decode.list(decode.string))
        decode.success(paths)
      })
      |> result.replace_error("invalid maintenance candidates")
  })
  use captured <- result.try(list.try_map(paths, required_identity))
  io.println("{\"ready\":true}")
  use line <- result.try(read_line())
  case line {
    None -> Ok(Nil)
    Some(line) -> {
      use work <- result.try(
        json.parse(line, {
          use apply <- decode.field("apply", decode.bool)
          use vacuum <- decode.field("vacuum", decode.bool)
          use before <- decode.field("before", decode.int)
          use free_pages <- decode.field("free_pages", decode.int)
          decode.success(Authorization(apply, vacuum, before, free_pages))
        })
        |> result.replace_error("invalid maintenance authorization"),
      )
      case work.apply {
        False -> Ok(Nil)
        True -> {
          watch_owner()
          use _ <- result.try(
            list.zip(paths, captured)
            |> list.try_each(fn(entry) {
              let #(path, approved) = entry
              use fresh <- result.try(required_identity(path))
              case fresh == approved {
                True -> Ok(Nil)
                False ->
                  Error(
                    "file changed after the preview; cleanup stopped: " <> path,
                  )
              }
            }),
          )
          use _ <- result.try(list.try_each(paths, remove_file))
          use report <- result.try(shrink(home, work, vacuum_database))
          io.println(json.to_string(json.object([#("result", report)])))
          Ok(Nil)
        }
      }
    }
  }
}

fn shrink(
  home: String,
  work: Authorization,
  vacuum_database: fn(String) -> Result(Nil, String),
) -> Result(json.Json, String) {
  let path = home <> "/albedo.sqlite"
  use after <- result.try(case work.vacuum {
    False -> Ok(0)
    True if work.before == 0 -> Error("no SQLite database to shrink")
    True if work.free_pages == 0 -> Ok(0)
    True -> {
      use _ <- result.try(vacuum_database(path))
      use found <- result.try(required_identity(path))
      Ok(bytes(found))
    }
  })
  let vacuumed = work.vacuum && work.free_pages != 0
  Ok(
    json.object([
      #("VacuumSkipped", json.bool(work.vacuum && work.free_pages == 0)),
      #("Vacuumed", json.bool(vacuumed)),
      #(
        "Before",
        json.int(case vacuumed {
          True -> work.before
          False -> 0
        }),
      ),
      #("After", json.int(after)),
    ]),
  )
}
