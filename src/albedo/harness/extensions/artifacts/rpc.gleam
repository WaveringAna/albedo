//// The host calls behind the Python `artifacts` module: uploading files by
//// hash, saving versions, and reading back what the agent and the page made.

import albedo/harness/extensions/artifacts/ledger
import albedo/harness/rpc
import gleam/bit_array
import gleam/dynamic
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

pub fn handle(
  store: ledger.Store,
  workspace: String,
  session: String,
  method: String,
  args: dynamic.Dynamic,
) -> Result(json.Json, #(String, String)) {
  rpc.serve(
    method,
    args,
    fn(method, args) { dispatch(store, workspace, session, method, args) },
    describe,
  )
}

fn describe(error: ledger.Error) -> #(String, String) {
  case error {
    ledger.Invalid(message) -> #("invalid", message)
    ledger.NotFound -> #("not_found", "no such artifact")
    ledger.Storage(message) -> #("storage", message)
  }
}

fn parse(
  args: dynamic.Dynamic,
  decoder: decode.Decoder(a),
) -> Result(a, ledger.Error) {
  rpc.args(args, decoder, ledger.Invalid("invalid artifact arguments"))
}

fn id_field(next: fn(String) -> decode.Decoder(a)) -> decode.Decoder(a) {
  use id <- decode.field("id", decode.string)
  next(id)
}

fn known(id: String) -> Result(String, ledger.Error) {
  case ledger.valid_id(id) {
    True -> Ok(id)
    False -> Error(ledger.NotFound)
  }
}

fn dispatch(
  store: ledger.Store,
  workspace: String,
  session: String,
  method: String,
  args: dynamic.Dynamic,
) -> Result(json.Json, ledger.Error) {
  case method {
    "artifacts.missing" -> {
      use hashes <- result.try(parse(
        args,
        decode.field("hashes", decode.list(decode.string), decode.success),
      ))
      ledger.missing(store, hashes) |> result.map(json.array(_, json.string))
    }
    "artifacts.upload" -> {
      use #(hash, data) <- result.try(
        parse(args, {
          use hash <- decode.field("hash", decode.string)
          use data <- decode.field("data", decode.string)
          decode.success(#(hash, data))
        }),
      )
      use bytes <- result.try(
        bit_array.base64_decode(data)
        |> result.replace_error(ledger.Invalid("file data is not base64")),
      )
      ledger.put(store, hash, bytes) |> result.replace(json.null())
    }
    "artifacts.save" -> {
      use save <- result.try(
        parse(args, {
          use id <- decode.optional_field(
            "id",
            None,
            decode.optional(decode.string),
          )
          use title <- decode.optional_field(
            "title",
            None,
            decode.optional(decode.string),
          )
          use entry <- decode.optional_field(
            "entry",
            None,
            decode.optional(decode.string),
          )
          use files <- decode.optional_field(
            "files",
            None,
            decode.optional(
              decode.list({
                use path <- decode.field("path", decode.string)
                use hash <- decode.field("hash", decode.string)
                use size <- decode.field("size", decode.int)
                decode.success(ledger.File(path:, hash:, size:))
              }),
            ),
          )
          use cell <- decode.optional_field(
            "cell",
            None,
            decode.optional(decode.string),
          )
          decode.success(ledger.Save(
            id:,
            title:,
            entry:,
            files:,
            session:,
            workspace:,
            cell:,
          ))
        }),
      )
      use _ <- result.try(case save.id {
        Some(id) -> known(id) |> result.replace(Nil)
        None -> Ok(Nil)
      })
      use #(artifact, created) <- result.try(ledger.save(store, save))
      Ok(
        json.object([
          #("artifact", summary(artifact)),
          #("created", json.bool(created)),
        ]),
      )
    }
    "artifacts.list" -> {
      use #(limit, current) <- result.try(
        parse(args, {
          use limit <- decode.optional_field("limit", 20, decode.int)
          use current <- decode.optional_field("current", False, decode.bool)
          decode.success(#(limit, current))
        }),
      )
      use <- guard_limit(limit)
      ledger.page(store, None, limit, case current {
        True -> Some(session)
        False -> None
      })
      |> result.map(json.array(_, summary))
    }
    "artifacts.get" -> {
      use #(id, version) <- result.try(parse(args, versioned()))
      use id <- result.try(known(id))
      use artifact <- result.try(ledger.get(store, id))
      use found <- result.try(ledger.version(store, id, version))
      Ok(described(artifact, found))
    }
    "artifacts.read" -> {
      use #(#(id, version), path) <- result.try(
        parse(args, {
          use pair <- decode.then(versioned())
          use path <- decode.optional_field(
            "path",
            None,
            decode.optional(decode.string),
          )
          decode.success(#(pair, path))
        }),
      )
      use id <- result.try(known(id))
      use found <- result.try(ledger.version(store, id, version))
      let path = option.unwrap(path, found.entry)
      use file <- result.try(
        list.find(found.files, fn(file) { file.path == path })
        |> result.replace_error(ledger.Invalid(
          path <> " is not a file of version " <> int_text(found.version),
        )),
      )
      use bytes <- result.try(ledger.data(store, file.hash))
      Ok(
        json.object([
          #("data", json.string(bit_array.base64_encode(bytes, True))),
        ]),
      )
    }
    "artifacts.state" -> {
      use id <- result.try(parse(args, id_field(decode.success)))
      use id <- result.try(known(id))
      use _ <- result.try(ledger.get(store, id))
      use text <- result.try(ledger.state(store, id))
      // Stored as the JSON the page sent, which the module decodes.
      Ok(json.object([#("state", json.string(text))]))
    }
    "artifacts.errors" -> {
      use id <- result.try(parse(args, id_field(decode.success)))
      use id <- result.try(known(id))
      use _ <- result.try(ledger.get(store, id))
      ledger.failures(store, id)
      |> result.map(
        json.array(_, fn(failure) {
          json.object([
            #("version", json.int(failure.version)),
            #("at", json.int(failure.at)),
            #("message", json.string(failure.message)),
            #("source", json.string(failure.source)),
            #("line", json.int(failure.line)),
            #("column", json.int(failure.column)),
            #("stack", json.string(failure.stack)),
          ])
        }),
      )
    }
    // The latest version's files with their hashes, which `update` merges
    // the changed files into.
    "artifacts.manifest" -> {
      use id <- result.try(parse(args, id_field(decode.success)))
      use id <- result.try(known(id))
      use found <- result.try(ledger.version(store, id, None))
      Ok(
        json.object([
          #("entry", json.string(found.entry)),
          #(
            "files",
            json.array(found.files, fn(file) {
              json.object([
                #("path", json.string(file.path)),
                #("hash", json.string(file.hash)),
                #("size", json.int(file.size)),
              ])
            }),
          ),
        ]),
      )
    }
    "artifacts.frame" -> {
      use #(id, version) <- result.try(parse(args, versioned()))
      use id <- result.try(known(id))
      use artifact <- result.try(ledger.get(store, id))
      use found <- result.try(ledger.version(store, id, version))
      Ok(
        json.object([
          #(
            "path",
            json.string(
              "/frame/"
              <> artifact.id
              <> "."
              <> artifact.key
              <> "/"
              <> int_text(found.version)
              <> "/"
              <> found.entry,
            ),
          ),
        ]),
      )
    }
    _ -> Error(ledger.Invalid("unknown host operation"))
  }
}

fn guard_limit(
  limit: Int,
  next: fn() -> Result(json.Json, ledger.Error),
) -> Result(json.Json, ledger.Error) {
  case limit < 1 || limit > 200 {
    True -> Error(ledger.Invalid("1 <= limit <= 200 required"))
    False -> next()
  }
}

fn versioned() -> decode.Decoder(#(String, Option(Int))) {
  use id <- decode.field("id", decode.string)
  use version <- decode.optional_field(
    "version",
    None,
    decode.optional(decode.int),
  )
  decode.success(#(id, version))
}

fn int_text(value: Int) -> String {
  json.to_string(json.int(value))
}

/// An artifact as the model sees it.
fn summary(artifact: ledger.Artifact) -> json.Json {
  json.object(fields(artifact))
}

fn fields(artifact: ledger.Artifact) -> List(#(String, json.Json)) {
  [
    #("id", json.string(artifact.id)),
    #("title", json.string(artifact.title)),
    #("version", json.int(artifact.version)),
    #("versions", json.int(artifact.versions)),
    #("entry", json.string(artifact.entry)),
    #("session", json.string(artifact.session)),
    #("workspace", json.string(artifact.workspace)),
    #("created_at", json.int(artifact.created_at)),
    #("updated_at", json.int(artifact.updated_at)),
    #("bytes", json.int(artifact.bytes)),
  ]
}

/// An artifact at one version, with that version's files and their sizes.
fn described(artifact: ledger.Artifact, found: ledger.Version) -> json.Json {
  let artifact =
    ledger.Artifact(
      ..artifact,
      version: found.version,
      entry: found.entry,
      bytes: found.bytes,
    )
  json.object(
    list.append(fields(artifact), [
      #(
        "files",
        json.object(
          list.map(found.files, fn(file) { #(file.path, json.int(file.size)) }),
        ),
      ),
    ]),
  )
}
