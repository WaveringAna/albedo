//// Pasted text a message carries beside its prompt. The prompt marks each
//// paste as `[Paste #N, …]`, numbered from 1. A short paste goes back in
//// place of its marker; a long one is saved under the daemon home and its
//// marker names the file, so the model reads it when it needs to.

import gleam/int
import gleam/list
import gleam/result
import gleam/string

/// A paste this long or longer is saved to a file instead of inlined.
pub const file_lines = 100

pub const file_bytes = 32_768

/// The model's text: each marker replaced by its paste or by the file it was
/// saved to. Files go to `home/pastes/<session>/<input>-<n>.md`, so a
/// repeated admission of the same input rewrites the same files.
pub fn expand(
  text: String,
  pastes: List(String),
  home: String,
  session: String,
  input: String,
) -> Result(String, String) {
  let folder = string.join([home, "pastes", session], "/")
  use placed <- result.try(
    list.index_map(pastes, fn(paste, index) { #(index + 1, paste) })
    |> list.try_map(fn(entry) {
      let #(n, paste) = entry
      case lines(paste) >= file_lines || string.byte_size(paste) >= file_bytes {
        False -> Ok(entry)
        True -> {
          let path = folder <> "/" <> input <> "-" <> int.to_string(n) <> ".md"
          use _ <- result.map(write(path, paste))
          #(n, saved_marker(n, lines(paste), path))
        }
      }
    }),
  )
  Ok(replace_markers(text, placed))
}

fn saved_marker(n: Int, lines: Int, path: String) -> String {
  "[Paste #"
  <> int.to_string(n)
  <> ", "
  <> int.to_string(lines)
  <> " lines, saved to "
  <> path
  <> "]"
}

fn lines(text: String) -> Int {
  list.length(string.split(text, "\n"))
}

/// One pass over `text`: replaced content is never scanned again, so a paste
/// that itself contains a marker survives verbatim.
fn replace_markers(text: String, pastes: List(#(Int, String))) -> String {
  case string.split_once(text, "[Paste #") {
    Error(_) -> text
    Ok(#(before, rest)) ->
      case
        marker(rest)
        |> result.try(fn(found) {
          list.key_find(pastes, found.0)
          |> result.map(fn(paste) { #(paste, found.1) })
        })
      {
        Ok(#(paste, after)) -> before <> paste <> replace_markers(after, pastes)
        Error(_) -> before <> "[Paste #" <> replace_markers(rest, pastes)
      }
  }
}

/// The number of the marker `rest` continues and the text after it: digits,
/// an optional `, label` on one line, then `]`.
fn marker(rest: String) -> Result(#(Int, String), Nil) {
  use #(inside, after) <- result.try(string.split_once(rest, "]"))
  let #(digits, label) = case string.split_once(inside, ", ") {
    Ok(#(digits, label)) -> #(digits, label)
    Error(_) -> #(inside, "")
  }
  use n <- result.try(int.parse(digits))
  case string.contains(label, "\n") || string.contains(label, "[") {
    True -> Error(Nil)
    False -> Ok(#(n, after))
  }
}

@external(erlang, "albedo_pastes", "write")
fn write(path: String, text: String) -> Result(Nil, String)

/// Deletes saved pastes older than `retention` seconds; returns how many.
@external(erlang, "albedo_pastes", "prune")
pub fn prune(home: String, retention: Int) -> Int
