//// Serving an artifact's files: their content types, and the bridge every
//// HTML file gets first thing in its head (robot-docs/artifacts.md).

import albedo/harness/extensions/artifacts/ledger
import gleam/bit_array
import gleam/json
import gleam/list
import gleam/result
import gleam/string

/// The content type a browser needs for a file, from its extension.
pub fn content_type(path: String) -> String {
  let extension =
    path
    |> string.split("/")
    |> list.last
    |> result.unwrap("")
    |> string.split(".")
    |> list.last
    |> result.unwrap("")
    |> string.lowercase
  case extension {
    "html" | "htm" -> "text/html; charset=utf-8"
    "js" | "mjs" | "cjs" -> "text/javascript; charset=utf-8"
    "css" -> "text/css; charset=utf-8"
    "json" | "map" -> "application/json; charset=utf-8"
    "webmanifest" -> "application/manifest+json; charset=utf-8"
    "txt" -> "text/plain; charset=utf-8"
    "md" -> "text/markdown; charset=utf-8"
    "csv" -> "text/csv; charset=utf-8"
    "xml" -> "application/xml; charset=utf-8"
    "svg" -> "image/svg+xml"
    "png" -> "image/png"
    "jpg" | "jpeg" -> "image/jpeg"
    "gif" -> "image/gif"
    "webp" -> "image/webp"
    "avif" -> "image/avif"
    "ico" -> "image/x-icon"
    "wasm" -> "application/wasm"
    "woff" -> "font/woff"
    "woff2" -> "font/woff2"
    "ttf" -> "font/ttf"
    "otf" -> "font/otf"
    "mp3" -> "audio/mpeg"
    "wav" -> "audio/wav"
    "ogg" | "oga" -> "audio/ogg"
    "m4a" -> "audio/mp4"
    "mp4" | "m4v" -> "video/mp4"
    "webm" -> "video/webm"
    "glb" -> "model/gltf-binary"
    "gltf" -> "model/gltf+json"
    "pdf" -> "application/pdf"
    _ -> "application/octet-stream"
  }
}

pub fn is_html(path: String) -> Bool {
  string.starts_with(content_type(path), "text/html")
}

/// The file a request path names: itself, or the `index.html` of a folder.
pub fn resolve(
  files: List(ledger.File),
  path: String,
) -> Result(ledger.File, Nil) {
  let wanted = case path == "" || string.ends_with(path, "/") {
    True -> path <> "index.html"
    False -> path
  }
  list.find(files, fn(file) { file.path == wanted })
}

/// `html` with the bridge in front of everything else in its head, so its
/// storage stands in before the page's own scripts run.
pub fn inject(
  html: BitArray,
  bridge: String,
  artifact: ledger.Artifact,
  version: Int,
  state: String,
) -> BitArray {
  let boot =
    json.object([
      #("id", json.string(artifact.id)),
      #("version", json.int(version)),
      #("latest", json.int(artifact.version)),
      #("title", json.string(artifact.title)),
      #(
        "base",
        json.string(
          "/frame/"
          <> artifact.id
          <> "."
          <> artifact.key
          <> "/"
          <> json.to_string(json.int(version))
          <> "/",
        ),
      ),
      #("state", json.string(state)),
    ])
    |> json.to_string
    // Inside a script element only `</script` and `<!--` end or confuse it.
    |> string.replace("<", "\\u003c")
  let script =
    "<script>window.__albedo=" <> boot <> ";\n" <> bridge <> "\n</script>"
  let at = case head_end(html, 0) {
    Ok(at) -> at
    // No head: after the doctype if there is one, so the page keeps
    // standards mode.
    Error(_) ->
      case doctype_end(html) {
        Ok(at) -> at
        Error(_) -> 0
      }
  }
  let assert Ok(before) = bit_array.slice(html, 0, at)
  let assert Ok(after) =
    bit_array.slice(html, at, bit_array.byte_size(html) - at)
  bit_array.concat([before, <<script:utf8>>, after])
}

// Byte offsets after `<head ...>`, found byte by byte in ASCII, so a page in
// any encoding keeps its bytes.
fn head_end(html: BitArray, at: Int) -> Result(Int, Nil) {
  case html {
    <<60, h, e, a, d, next, rest:bytes>> ->
      case
        lower(h) == 104
        && lower(e) == 101
        && lower(a) == 97
        && lower(d) == 100
        && { next == 62 || next == 32 || next == 9 || next == 10 || next == 13 }
      {
        True ->
          case next {
            62 -> Ok(at + 6)
            _ -> close(rest, at + 6)
          }
        False -> head_end(<<h, e, a, d, next, rest:bits>>, at + 1)
      }
    <<_, rest:bytes>> -> head_end(rest, at + 1)
    _ -> Error(Nil)
  }
}

fn close(html: BitArray, at: Int) -> Result(Int, Nil) {
  case html {
    <<62, _:bytes>> -> Ok(at + 1)
    <<_, rest:bytes>> -> close(rest, at + 1)
    _ -> Error(Nil)
  }
}

fn doctype_end(html: BitArray) -> Result(Int, Nil) {
  let skipped = skip_space(html, 0)
  let assert Ok(rest) =
    bit_array.slice(html, skipped, bit_array.byte_size(html) - skipped)
  case rest {
    <<60, 33, d, o, c, t, y, p, e, tail:bytes>> ->
      case
        lower(d) == 100
        && lower(o) == 111
        && lower(c) == 99
        && lower(t) == 116
        && lower(y) == 121
        && lower(p) == 112
        && lower(e) == 101
      {
        True -> close(tail, skipped + 9)
        False -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

fn skip_space(html: BitArray, at: Int) -> Int {
  case html {
    <<byte, rest:bytes>>
      if byte == 32 || byte == 9 || byte == 10 || byte == 13
    -> skip_space(rest, at + 1)
    // A UTF-8 byte order mark.
    <<239, 187, 191, rest:bytes>> if at == 0 -> skip_space(rest, 3)
    _ -> at
  }
}

fn lower(byte: Int) -> Int {
  case byte >= 65 && byte <= 90 {
    True -> byte + 32
    False -> byte
  }
}
