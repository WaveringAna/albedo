//// Read-only storage accounting. SQL stays on the store owner; filesystem
//// inspection runs in the HTTP request process after the projection returns.

import albedo/daemon/store
import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option}
import gleam/result
import sqlight

pub type SessionBytes {
  SessionBytes(
    id: String,
    bytes: Int,
    title: String,
    workspace: String,
    created_at: Option(Int),
    activity_at: Option(Int),
  )
}

pub type Database {
  Database(
    sessions: List(SessionBytes),
    images: Int,
    free_pages: Int,
    page_size: Int,
    page_count: Int,
    image_count: Int,
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

pub type Observation {
  Observation(database: Database, files: Filesystem)
}

pub fn observe(db: store.Store, home: String) -> Result(Observation, String) {
  use database <- result.try(store.query(db, projection))
  use files <- result.try(inspect(
    home,
    list.map(database.sessions, fn(session) { session.id }),
  ))
  Ok(Observation(database, files))
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
  let fork_traces = case list.contains(tables, "transcript_traces") {
    True ->
      "COALESCE((SELECT SUM(LENGTH(CAST(payload AS BLOB))) FROM transcript_traces WHERE session=s.id),0)"
    False -> "0"
  }
  use sessions <- result.try(
    store.rows(
      db,
      "SELECT s.id,COALESCE(LENGTH(s.pinned_context),0)+"
        <> transcript
        <> "+"
        <> cells
        <> "+"
        <> fork_traces
        <> ",COALESCE(NULLIF(s.name,''),s.title),s.cwd,s.created_at,s.activity_at FROM sessions s ORDER BY s.id",
      [],
      {
        use id <- decode.field(0, decode.string)
        use bytes <- decode.field(1, decode.int)
        use title <- decode.field(2, decode.string)
        use workspace <- decode.field(3, decode.string)
        use created_at <- decode.field(4, decode.optional(decode.int))
        use activity_at <- decode.field(5, decode.optional(decode.int))
        decode.success(SessionBytes(
          id,
          bytes,
          title,
          workspace,
          created_at,
          activity_at,
        ))
      },
    ),
  )
  use images <- result.try(case list.contains(tables, "images") {
    True -> scalar(db, "SELECT COALESCE(SUM(LENGTH(data)),0) FROM images")
    False -> Ok(0)
  })
  use free_pages <- result.try(scalar(db, "PRAGMA freelist_count"))
  use page_size <- result.try(scalar(db, "PRAGMA page_size"))
  use page_count <- result.try(scalar(db, "PRAGMA page_count"))
  use image_count <- result.try(case list.contains(tables, "images") {
    True -> scalar(db, "SELECT COUNT(*) FROM images")
    False -> Ok(0)
  })
  Ok(Database(sessions, images, free_pages, page_size, page_count, image_count))
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
