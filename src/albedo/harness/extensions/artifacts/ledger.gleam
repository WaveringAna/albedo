//// Artifacts: web pages the agent made, every version of each, the files
//// they hold, and what each page saved or failed with. Files are stored once
//// by SHA-256, so a version that changes one file stores one file. Rows are
//// never deleted with their session; an artifact goes only when someone
//// deletes it from the gallery.

import albedo/clock
import albedo/daemon/store as storage
import albedo/text_scalars
import gleam/bit_array
import gleam/bool
import gleam/crypto
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import sqlight

pub type Store =
  storage.Store

pub type Error {
  Invalid(String)
  NotFound
  Storage(String)
}

/// One artifact as of its latest version.
pub type Artifact {
  Artifact(
    id: String,
    key: String,
    title: String,
    version: Int,
    versions: Int,
    entry: String,
    session: String,
    workspace: String,
    created_at: Int,
    updated_at: Int,
    bytes: Int,
  )
}

/// A file of a version: where it sits, which stored bytes it is, how many.
pub type File {
  File(path: String, hash: String, size: Int)
}

pub type Version {
  Version(
    version: Int,
    entry: String,
    files: List(File),
    cell: Option(String),
    created_at: Int,
    bytes: Int,
  )
}

/// A failure the page reported, as the page described it.
pub type Failure {
  Failure(
    version: Int,
    at: Int,
    message: String,
    source: String,
    line: Int,
    column: Int,
    stack: String,
  )
}

pub const file_limit = 16_777_216

pub const version_limit = 67_108_864

pub const file_count_limit = 2000

pub const state_limit = 1_048_576

const kept_failures = 20

pub fn initialise(ledger: Store) -> Result(Nil, String) {
  storage.query(ledger, storage.exec(_, schema))
}

const schema =
  "
CREATE TABLE IF NOT EXISTS artifacts (
 id TEXT PRIMARY KEY,
 key TEXT NOT NULL,
 session TEXT NOT NULL,
 workspace TEXT NOT NULL,
 title TEXT NOT NULL,
 version INTEGER NOT NULL,
 created_at INTEGER NOT NULL,
 updated_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS artifacts_by_change ON artifacts(updated_at DESC, id DESC);
CREATE INDEX IF NOT EXISTS artifacts_by_session ON artifacts(session, updated_at DESC);
CREATE TABLE IF NOT EXISTS artifact_versions (
 artifact TEXT NOT NULL,
 version INTEGER NOT NULL,
 entry TEXT NOT NULL,
 manifest TEXT NOT NULL,
 bytes INTEGER NOT NULL,
 cell TEXT,
 created_at INTEGER NOT NULL,
 PRIMARY KEY (artifact, version)
);
CREATE TABLE IF NOT EXISTS artifact_files (
 hash TEXT PRIMARY KEY,
 size INTEGER NOT NULL,
 data BLOB NOT NULL
);
CREATE TABLE IF NOT EXISTS artifact_state (
 artifact TEXT PRIMARY KEY,
 state TEXT NOT NULL,
 updated_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS artifact_errors (
 id INTEGER PRIMARY KEY AUTOINCREMENT,
 artifact TEXT NOT NULL,
 version INTEGER NOT NULL,
 at INTEGER NOT NULL,
 message TEXT NOT NULL,
 source TEXT NOT NULL,
 line INTEGER NOT NULL,
 column INTEGER NOT NULL,
 stack TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS artifact_errors_by_artifact ON artifact_errors(artifact, id);
"

const columns =
  "a.id,a.key,a.title,a.version,(SELECT count(*) FROM artifact_versions c WHERE c.artifact=a.id),v.entry,a.session,a.workspace,a.created_at,a.updated_at,v.bytes"

const joined =
  " FROM artifacts a JOIN artifact_versions v ON v.artifact=a.id AND v.version=a.version"

fn artifact_decoder() -> decode.Decoder(Artifact) {
  use id <- decode.field(0, decode.string)
  use key <- decode.field(1, decode.string)
  use title <- decode.field(2, decode.string)
  use version <- decode.field(3, decode.int)
  use versions <- decode.field(4, decode.int)
  use entry <- decode.field(5, decode.string)
  use session <- decode.field(6, decode.string)
  use workspace <- decode.field(7, decode.string)
  use created_at <- decode.field(8, decode.int)
  use updated_at <- decode.field(9, decode.int)
  use bytes <- decode.field(10, decode.int)
  decode.success(Artifact(
    id:,
    key:,
    title:,
    version:,
    versions:,
    entry:,
    session:,
    workspace:,
    created_at:,
    updated_at:,
    bytes:,
  ))
}

fn version_decoder() -> decode.Decoder(Version) {
  use version <- decode.field(0, decode.int)
  use entry <- decode.field(1, decode.string)
  use manifest <- decode.field(2, decode.string)
  use cell <- decode.field(3, decode.optional(decode.string))
  use created_at <- decode.field(4, decode.int)
  use bytes <- decode.field(5, decode.int)
  case json.parse(manifest, manifest_decoder()) {
    Ok(files) ->
      decode.success(Version(
        version:,
        entry:,
        files:,
        cell:,
        created_at:,
        bytes:,
      ))
    Error(_) ->
      decode.failure(
        Version(version, entry, [], cell, created_at, bytes),
        "artifact manifest",
      )
  }
}

fn manifest_decoder() -> decode.Decoder(List(File)) {
  decode.dict(decode.string, {
    use hash <- decode.field("hash", decode.string)
    use size <- decode.field("size", decode.int)
    decode.success(#(hash, size))
  })
  |> decode.map(fn(files) {
    files
    |> dict.to_list
    |> list.map(fn(file) { File(file.0, file.1.0, file.1.1) })
    |> list.sort(fn(a, b) { string.compare(a.path, b.path) })
  })
}

fn manifest(files: List(File)) -> String {
  files
  |> list.map(fn(file) {
    #(
      file.path,
      json.object([
        #("hash", json.string(file.hash)),
        #("size", json.int(file.size)),
      ]),
    )
  })
  |> json.object
  |> json.to_string
}

fn failure_decoder() -> decode.Decoder(Failure) {
  use version <- decode.field(0, decode.int)
  use at <- decode.field(1, decode.int)
  use message <- decode.field(2, decode.string)
  use source <- decode.field(3, decode.string)
  use line <- decode.field(4, decode.int)
  use column <- decode.field(5, decode.int)
  use stack <- decode.field(6, decode.string)
  decode.success(Failure(
    version:,
    at:,
    message:,
    source:,
    line:,
    column:,
    stack:,
  ))
}

fn storage_error(result: Result(a, String)) -> Result(a, Error) {
  result.map_error(result, Storage)
}

// Ids are short enough to type into a cell; the key is the capability that
// serves an artifact's pages, so it is long and random.
const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789"

fn new_id() -> String {
  crypto.strong_random_bytes(12)
  |> bytes_list
  |> list.map(fn(byte) {
    let assert Ok(letter) = bit_array.slice(<<alphabet:utf8>>, byte % 36, 1)
    letter
  })
  |> bit_array.concat
  |> bit_array.to_string
  |> result.unwrap("")
}

fn bytes_list(bytes: BitArray) -> List(Int) {
  case bytes {
    <<byte, rest:bits>> -> [byte, ..bytes_list(rest)]
    _ -> []
  }
}

fn new_key() -> String {
  crypto.strong_random_bytes(16) |> bit_array.base16_encode |> string.lowercase
}

pub fn hash(data: BitArray) -> String {
  crypto.hash(crypto.Sha256, data)
  |> bit_array.base16_encode
  |> string.lowercase
}

/// Whether `text` names an artifact: twelve lowercase letters or digits.
pub fn valid_id(text: String) -> Bool {
  string.byte_size(text) == 12
  && list.all(string.to_graphemes(text), string.contains(alphabet, _))
}

fn valid_hash(text: String) -> Bool {
  string.byte_size(text) == 64
  && list.all(string.to_graphemes(text), string.contains("0123456789abcdef", _))
}

/// A relative path inside a version: `/`-separated, no empty, `.` or `..`
/// segment, nothing under `.albedo/` (the bridge's own paths), at most 512
/// bytes.
pub fn valid_path(path: String) -> Bool {
  let segments = string.split(path, "/")
  path != ""
  && string.byte_size(path) <= 512
  && !string.contains(path, "\\")
  && !string.contains(path, "\u{0}")
  && list.all(segments, fn(segment) {
    segment != "" && segment != "." && segment != ".."
  })
  && list.first(segments) != Ok(".albedo")
}

pub fn valid_title(title: String) -> Result(String, Error) {
  let title = string.trim(title)
  let length = text_scalars.length(title)
  case length {
    0 -> Error(Invalid("an artifact needs a title"))
    _ if length > 200 ->
      Error(Invalid("an artifact title is at most 200 characters"))
    _ -> Ok(title)
  }
}

/// The hashes among `hashes` no stored file has, in the order given.
pub fn missing(
  store: Store,
  hashes: List(String),
) -> Result(List(String), Error) {
  use <- bool.guard(
    !list.all(hashes, valid_hash),
    Error(Invalid("a file hash is 64 lowercase hex characters (SHA-256)")),
  )
  use <- bool.guard(
    list.length(hashes) > file_count_limit,
    Error(Invalid("a version holds at most 2000 files")),
  )
  use stored <- result.try(
    storage.snapshot(store, fn(db) {
      list.try_map(hashes |> list.unique, fn(hash) {
        storage.rows(
          db,
          "SELECT hash FROM artifact_files WHERE hash=?",
          [sqlight.text(hash)],
          decode.field(0, decode.string, decode.success),
        )
      })
    })
    |> storage_error,
  )
  let stored = list.flatten(stored)
  Ok(list.filter(hashes, fn(hash) { !list.contains(stored, hash) }))
}

/// Stores one file's bytes under their hash; storing them again is a no-op.
pub fn put(
  store: Store,
  expected: String,
  data: BitArray,
) -> Result(Nil, Error) {
  let size = bit_array.byte_size(data)
  use <- bool.guard(
    size > file_limit,
    Error(Invalid("a file is at most 16 MiB")),
  )
  use <- bool.guard(
    hash(data) != expected,
    Error(Invalid("the file's bytes do not match its hash")),
  )
  storage.query(store, fn(db) {
    storage.run(
      db,
      "INSERT OR IGNORE INTO artifact_files(hash,size,data) VALUES(?,?,?)",
      [sqlight.text(expected), sqlight.int(size), sqlight.blob(data)],
    )
  })
  |> storage_error
}

/// What a save asks for. `id` is `None` to make a new artifact. `files` is
/// the whole tree of the new version, or `None` to only rename.
pub type Save {
  Save(
    id: Option(String),
    title: Option(String),
    entry: Option(String),
    files: Option(List(File)),
    session: String,
    workspace: String,
    cell: Option(String),
  )
}

fn check_files(files: List(File), entry: String) -> Result(Int, Error) {
  let paths = list.map(files, fn(file) { file.path })
  let bytes = int.sum(list.map(files, fn(file) { file.size }))
  case list.find(paths, fn(path) { !valid_path(path) }) {
    Ok(path) ->
      Error(Invalid(
        "\""
        <> text_scalars.take(path, 200)
        <> "\" is not a relative path inside the artifact (no leading /, no . or .. segments, not under .albedo/)",
      ))
    Error(_) ->
      case
        files == [],
        list.length(files) > file_count_limit,
        list.length(list.unique(paths)) != list.length(paths),
        bytes > version_limit,
        list.contains(paths, entry)
      {
        True, _, _, _, _ ->
          Error(Invalid("an artifact needs at least one file"))
        _, True, _, _, _ -> Error(Invalid("a version holds at most 2000 files"))
        _, _, True, _, _ -> Error(Invalid("a path appears twice"))
        _, _, _, True, _ -> Error(Invalid("a version holds at most 64 MiB"))
        _, _, _, _, False ->
          Error(Invalid(
            "the entry file \"" <> entry <> "\" is not among the files",
          ))
        _, _, _, _, True -> Ok(bytes)
      }
  }
}

/// Saves a new artifact or its next version, in one transaction: every file
/// must already be stored, with the size the manifest says.
pub fn save(store: Store, save: Save) -> Result(#(Artifact, Bool), Error) {
  use title <- result.try(case save.title {
    Some(title) -> valid_title(title) |> result.map(Some)
    None -> Ok(None)
  })
  storage.query(store, fn(db) {
    storage.transaction(db, fn() {
      case transact(db, save, title) {
        Ok(value) -> Ok(Ok(value))
        // A storage failure rolls back what was written. A refusal comes
        // before any write, so committing it changes nothing.
        Error(Storage(message)) -> Error(message)
        Error(refusal) -> Ok(Error(refusal))
      }
    })
    |> result.map_error(Storage)
    |> result.flatten
  })
  |> result.try(fn(saved) {
    get(store, saved.0) |> result.map(fn(artifact) { #(artifact, saved.1) })
  })
}

fn transact(
  db: sqlight.Connection,
  save: Save,
  title: Option(String),
) -> Result(#(String, Bool), Error) {
  let now = clock.system_ms()
  case save.id {
    None -> {
      use title <- result.try(option.to_result(
        title,
        Invalid("an artifact needs a title"),
      ))
      use files <- result.try(option.to_result(
        save.files,
        Invalid("an artifact needs at least one file"),
      ))
      let entry = option.unwrap(save.entry, "index.html")
      use bytes <- result.try(check_files(files, entry))
      use _ <- result.try(stored(db, files))
      let id = new_id()
      use _ <- result.try(
        storage.run(
          db,
          "INSERT INTO artifacts(id,key,session,workspace,title,version,created_at,updated_at) VALUES(?,?,?,?,?,1,?,?)",
          [
            sqlight.text(id),
            sqlight.text(new_key()),
            sqlight.text(save.session),
            sqlight.text(save.workspace),
            sqlight.text(title),
            sqlight.int(now),
            sqlight.int(now),
          ],
        )
        |> storage_error,
      )
      use _ <- result.try(insert_version(
        db,
        id,
        1,
        entry,
        files,
        bytes,
        save.cell,
        now,
      ))
      Ok(#(id, True))
    }
    Some(id) -> {
      use current <- result.try(
        storage.rows(
          db,
          "SELECT a.version,v.entry FROM artifacts a JOIN artifact_versions v ON v.artifact=a.id AND v.version=a.version WHERE a.id=?",
          [sqlight.text(id)],
          {
            use version <- decode.field(0, decode.int)
            use entry <- decode.field(1, decode.string)
            decode.success(#(version, entry))
          },
        )
        |> storage_error
        |> result.try(fn(rows) {
          list.first(rows) |> result.replace_error(NotFound)
        }),
      )
      case save.files {
        None -> {
          use title <- result.try(option.to_result(
            title,
            Invalid("give the next version's files, or a new title"),
          ))
          use _ <- result.try(
            storage.run(
              db,
              "UPDATE artifacts SET title=?,updated_at=? WHERE id=?",
              [
                sqlight.text(title),
                sqlight.int(now),
                sqlight.text(id),
              ],
            )
            |> storage_error,
          )
          Ok(#(id, False))
        }
        Some(files) -> {
          let entry = option.unwrap(save.entry, current.1)
          use bytes <- result.try(check_files(files, entry))
          use _ <- result.try(stored(db, files))
          let version = current.0 + 1
          use _ <- result.try(insert_version(
            db,
            id,
            version,
            entry,
            files,
            bytes,
            save.cell,
            now,
          ))
          use _ <- result.try(
            storage.run(
              db,
              "UPDATE artifacts SET version=?,title=COALESCE(?,title),updated_at=? WHERE id=?",
              [
                sqlight.int(version),
                sqlight.nullable(sqlight.text, title),
                sqlight.int(now),
                sqlight.text(id),
              ],
            )
            |> storage_error,
          )
          Ok(#(id, False))
        }
      }
    }
  }
}

fn insert_version(
  db: sqlight.Connection,
  id: String,
  version: Int,
  entry: String,
  files: List(File),
  bytes: Int,
  cell: Option(String),
  now: Int,
) -> Result(Nil, Error) {
  storage.run(
    db,
    "INSERT INTO artifact_versions(artifact,version,entry,manifest,bytes,cell,created_at) VALUES(?,?,?,?,?,?,?)",
    [
      sqlight.text(id),
      sqlight.int(version),
      sqlight.text(entry),
      sqlight.text(manifest(files)),
      sqlight.int(bytes),
      sqlight.nullable(sqlight.text, cell),
      sqlight.int(now),
    ],
  )
  |> storage_error
}

// Every file is uploaded before the version naming it is saved, with the
// size the manifest claims.
fn stored(db: sqlight.Connection, files: List(File)) -> Result(Nil, Error) {
  list.try_each(files, fn(file) {
    use sizes <- result.try(
      storage.rows(
        db,
        "SELECT size FROM artifact_files WHERE hash=?",
        [sqlight.text(file.hash)],
        decode.field(0, decode.int, decode.success),
      )
      |> storage_error,
    )
    case sizes {
      [size] if size == file.size -> Ok(Nil)
      [_] -> Error(Invalid(file.path <> ": its size does not match its bytes"))
      _ -> Error(Invalid(file.path <> ": its bytes were never uploaded"))
    }
  })
}

pub fn get(store: Store, id: String) -> Result(Artifact, Error) {
  storage.snapshot(store, fn(db) {
    storage.rows(
      db,
      "SELECT " <> columns <> joined <> " WHERE a.id=?",
      [sqlight.text(id)],
      artifact_decoder(),
    )
  })
  |> storage_error
  |> result.try(fn(rows) { list.first(rows) |> result.replace_error(NotFound) })
}

/// Artifacts newest change first, after the `(updated_at, id)` a previous
/// page ended on, optionally only one session's.
pub fn page(
  store: Store,
  after: Option(#(Int, String)),
  limit: Int,
  session: Option(String),
) -> Result(List(Artifact), Error) {
  let #(cursor, cursor_args) = case after {
    None -> #("", [])
    Some(#(at, id)) -> #(
      " AND (a.updated_at<? OR (a.updated_at=? AND a.id<?))",
      [
        sqlight.int(at),
        sqlight.int(at),
        sqlight.text(id),
      ],
    )
  }
  let #(scope, scope_args) = case session {
    None -> #("", [])
    Some(session) -> #(" AND a.session=?", [sqlight.text(session)])
  }
  storage.snapshot(store, fn(db) {
    storage.rows(
      db,
      "SELECT "
        <> columns
        <> joined
        <> " WHERE 1"
        <> scope
        <> cursor
        <> " ORDER BY a.updated_at DESC, a.id DESC LIMIT ?",
      list.flatten([scope_args, cursor_args, [sqlight.int(limit)]]),
      artifact_decoder(),
    )
  })
  |> storage_error
}

/// Every version, newest first.
pub fn history(store: Store, id: String) -> Result(List(Version), Error) {
  storage.snapshot(store, fn(db) {
    storage.rows(
      db,
      "SELECT version,entry,manifest,cell,created_at,bytes FROM artifact_versions WHERE artifact=? ORDER BY version DESC",
      [sqlight.text(id)],
      version_decoder(),
    )
  })
  |> storage_error
}

/// One version; `None` asks for the latest.
pub fn version(
  store: Store,
  id: String,
  version: Option(Int),
) -> Result(Version, Error) {
  storage.snapshot(store, fn(db) {
    storage.rows(
      db,
      "SELECT v.version,v.entry,v.manifest,v.cell,v.created_at,v.bytes FROM artifact_versions v JOIN artifacts a ON a.id=v.artifact WHERE v.artifact=? AND v.version=COALESCE(?,a.version)",
      [sqlight.text(id), sqlight.nullable(sqlight.int, version)],
      version_decoder(),
    )
  })
  |> storage_error
  |> result.try(fn(rows) { list.first(rows) |> result.replace_error(NotFound) })
}

/// The version a frame names, when its key is the artifact's.
pub fn framed(
  store: Store,
  id: String,
  key: String,
  number: Int,
) -> Result(#(Artifact, Version), Error) {
  use artifact <- result.try(get(store, id))
  use <- bool.guard(
    !crypto.secure_compare(<<artifact.key:utf8>>, <<key:utf8>>),
    Error(NotFound),
  )
  use found <- result.try(version(store, id, Some(number)))
  Ok(#(artifact, found))
}

/// The stored bytes of one file.
pub fn data(store: Store, hash: String) -> Result(BitArray, Error) {
  storage.snapshot(store, fn(db) {
    storage.rows(
      db,
      "SELECT data FROM artifact_files WHERE hash=?",
      [sqlight.text(hash)],
      decode.field(0, decode.bit_array, decode.success),
    )
  })
  |> storage_error
  |> result.try(fn(rows) { list.first(rows) |> result.replace_error(NotFound) })
}

/// What the page last saved to its `localStorage`, as JSON text.
pub fn state(store: Store, id: String) -> Result(String, Error) {
  storage.snapshot(store, fn(db) {
    storage.rows(
      db,
      "SELECT state FROM artifact_state WHERE artifact=?",
      [sqlight.text(id)],
      decode.field(0, decode.string, decode.success),
    )
  })
  |> storage_error
  |> result.map(fn(rows) { list.first(rows) |> result.unwrap("{}") })
}

pub fn set_state(
  store: Store,
  id: String,
  state: Dict(String, String),
) -> Result(Nil, Error) {
  let text =
    state
    |> dict.to_list
    |> list.map(fn(pair) { #(pair.0, json.string(pair.1)) })
    |> json.object
    |> json.to_string
  use <- bool.guard(
    string.byte_size(text) > state_limit,
    Error(Invalid("a page saves at most 1 MiB")),
  )
  storage.query(store, fn(db) {
    storage.run(
      db,
      "INSERT INTO artifact_state(artifact,state,updated_at) VALUES(?,?,?) ON CONFLICT(artifact) DO UPDATE SET state=excluded.state,updated_at=excluded.updated_at",
      [sqlight.text(id), sqlight.text(text), sqlight.int(clock.system_ms())],
    )
  })
  |> storage_error
}

/// Keeps one failure, and only the newest twenty per artifact.
pub fn record_failure(
  store: Store,
  id: String,
  failure: Failure,
) -> Result(Nil, Error) {
  storage.query(store, fn(db) {
    storage.transaction(db, fn() {
      use _ <- result.try(
        storage.run(
          db,
          "INSERT INTO artifact_errors(artifact,version,at,message,source,line,column,stack) VALUES(?,?,?,?,?,?,?,?)",
          [
            sqlight.text(id),
            sqlight.int(failure.version),
            sqlight.int(failure.at),
            sqlight.text(failure.message),
            sqlight.text(failure.source),
            sqlight.int(failure.line),
            sqlight.int(failure.column),
            sqlight.text(failure.stack),
          ],
        ),
      )
      storage.run(
        db,
        "DELETE FROM artifact_errors WHERE artifact=? AND id NOT IN (SELECT id FROM artifact_errors WHERE artifact=? ORDER BY id DESC LIMIT ?)",
        [sqlight.text(id), sqlight.text(id), sqlight.int(kept_failures)],
      )
    })
  })
  |> storage_error
}

/// The page's recorded failures, oldest first.
pub fn failures(store: Store, id: String) -> Result(List(Failure), Error) {
  storage.snapshot(store, fn(db) {
    storage.rows(
      db,
      "SELECT version,at,message,source,line,column,stack FROM artifact_errors WHERE artifact=? ORDER BY id",
      [sqlight.text(id)],
      failure_decoder(),
    )
  })
  |> storage_error
}

/// Removes an artifact, its versions, state and failures, and every file no
/// other version still names.
pub fn delete(store: Store, id: String) -> Result(Nil, Error) {
  use _ <- result.try(get(store, id))
  storage.query(store, fn(db) {
    storage.transaction(db, fn() {
      use _ <- result.try(
        list.try_each(
          [
            "DELETE FROM artifact_versions WHERE artifact=?",
            "DELETE FROM artifact_state WHERE artifact=?",
            "DELETE FROM artifact_errors WHERE artifact=?",
            "DELETE FROM artifacts WHERE id=?",
          ],
          fn(sql) { storage.run(db, sql, [sqlight.text(id)]) },
        ),
      )
      storage.run(
        db,
        "DELETE FROM artifact_files WHERE hash NOT IN (SELECT json_extract(m.value,'$.hash') FROM artifact_versions v, json_each(v.manifest) m)",
        [],
      )
    })
  })
  |> storage_error
}

/// Display names for sessions, and which of them no longer exist.
pub fn sessions(
  store: Store,
  ids: List(String),
) -> Result(Dict(String, Option(String)), Error) {
  case ids {
    [] -> Ok(dict.new())
    _ ->
      storage.snapshot(store, fn(db) {
        storage.rows(
          db,
          "SELECT s.id, COALESCE(NULLIF(s.name,''), f.name, NULLIF(s.title,'new session'), '')"
            <> " FROM sessions s LEFT JOIN session_family f ON f.session=s.id"
            <> " WHERE s.id IN ("
            <> list.map(ids, fn(_) { "?" }) |> string.join(",")
            <> ")",
          list.map(ids, sqlight.text),
          {
            use id <- decode.field(0, decode.string)
            use label <- decode.field(1, decode.string)
            decode.success(
              #(id, case label {
                "" -> None
                _ -> Some(label)
              }),
            )
          },
        )
      })
      |> storage_error
      |> result.map(dict.from_list)
  }
}
