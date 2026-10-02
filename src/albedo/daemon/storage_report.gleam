//// Read-only storage accounting. SQL stays on the store owner; filesystem
//// inspection runs in the HTTP request process after the projection returns.

import albedo/daemon/store
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/result
import sqlight

type SessionBytes {
  SessionBytes(id: String, bytes: Int)
}

type Database {
  Database(
    sessions: List(SessionBytes),
    images: Int,
    free_pages: Int,
    page_size: Int,
  )
}

pub type FileBytes {
  FileBytes(path: String, bytes: Int)
}

pub type Filesystem {
  Filesystem(
    old_kernels: List(FileBytes),
    old_backups: List(FileBytes),
    database: Int,
    wal: Int,
    kernels: Int,
    backups: Int,
    other: Int,
    recent_backups: Int,
    recent_backup_count: Int,
  )
}

@external(erlang, "albedo_storage_report", "inspect")
fn inspect(home: String, sessions: List(String)) -> Result(Filesystem, String)

pub fn report(db: store.Store, home: String) -> Result(json.Json, String) {
  use database <- result.try(store.query(db, projection))
  use files <- result.try(inspect(
    home,
    list.map(database.sessions, fn(session) { session.id }),
  ))
  Ok(
    json.object([
      #("old_kernels", json.array(files.old_kernels, file_json)),
      #("old_backups", json.array(files.old_backups, file_json)),
      #(
        "db",
        json.object([
          #(
            "sessions",
            json.array(database.sessions, fn(session) {
              json.object([
                #("id", json.string(session.id)),
                #("bytes", json.int(session.bytes)),
              ])
            }),
          ),
          #("images", json.int(database.images)),
          #("free_pages", json.int(database.free_pages)),
          #("page_size", json.int(database.page_size)),
        ]),
      ),
      #("database", json.int(files.database)),
      #("wal", json.int(files.wal)),
      #("kernels", json.int(files.kernels)),
      #("backups", json.int(files.backups)),
      #("other", json.int(files.other)),
      #("recent_backups", json.int(files.recent_backups)),
      #("recent_backup_count", json.int(files.recent_backup_count)),
    ]),
  )
}

fn file_json(file: FileBytes) -> json.Json {
  json.object([
    #("path", json.string(file.path)),
    #("bytes", json.int(file.bytes)),
  ])
}

fn projection(db: sqlight.Connection) -> Result(Database, String) {
  use tables <- result.try(
    store.rows(db, "SELECT name FROM sqlite_master WHERE type='table'", [], {
      use value <- decode.field(0, decode.string)
      decode.success(value)
    }),
  )
  use _ <- result.try(
    case
      list.contains(tables, "sessions") && list.contains(tables, "transcript")
    {
      True -> Ok(Nil)
      False ->
        Error("storage report requires the sessions and transcript tables")
    },
  )
  let transcript =
    "COALESCE((SELECT SUM(LENGTH(payload)) FROM transcript WHERE session=s.id),0)"
  let cells = case list.contains(tables, "cells") {
    False -> "0"
    True -> {
      let #(join, trace) = case list.contains(tables, "cell_traces") {
        True -> #(
          "LEFT JOIN cell_traces t ON t.id=c.id",
          "COALESCE(LENGTH(t.payload),0)",
        )
        False -> #("", "0")
      }
      "COALESCE((SELECT SUM(LENGTH(c.source)+COALESCE(LENGTH(c.payload),0)+"
      <> trace
      <> ") FROM cells c "
      <> join
      <> " WHERE c.session=s.id),0)"
    }
  }
  use sessions <- result.try(
    store.rows(
      db,
      "SELECT s.id,COALESCE(LENGTH(s.pinned_context),0)+"
        <> transcript
        <> "+"
        <> cells
        <> " FROM sessions s",
      [],
      {
        use id <- decode.field(0, decode.string)
        use bytes <- decode.field(1, decode.int)
        decode.success(SessionBytes(id, bytes))
      },
    ),
  )
  use images <- result.try(case list.contains(tables, "images") {
    True -> scalar(db, "SELECT COALESCE(SUM(LENGTH(data)),0) FROM images")
    False -> Ok(0)
  })
  use free_pages <- result.try(scalar(db, "PRAGMA freelist_count"))
  use page_size <- result.try(scalar(db, "PRAGMA page_size"))
  Ok(Database(sessions, images, free_pages, page_size))
}

fn scalar(db: sqlight.Connection, sql: String) -> Result(Int, String) {
  store.one(
    db,
    sql,
    [],
    {
      use value <- decode.field(0, decode.int)
      decode.success(value)
    },
    "missing storage accounting value",
  )
}
