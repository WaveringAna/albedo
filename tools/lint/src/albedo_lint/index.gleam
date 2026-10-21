//// What the rules need to know about the checkout and glinter does not tell
//// a module rule: which file a module came from, and which extension
//// created each table.

import gleam/dict.{type Dict}
import gleam/list
import gleam/string
import simplifile

pub type Index {
  Index(
    /// A module's source text to its path under the project, such as
    /// `src/albedo/clock.gleam`. glinter hands a module rule the source and
    /// not the path.
    paths: Dict(String, String),
    /// Each table created inside one extension to that extension's name.
    table_owners: Dict(String, String),
  )
}

pub fn build(root: String) -> Index {
  let prefix = case string.ends_with(root, "/") {
    True -> root
    False -> root <> "/"
  }
  let files =
    list.append(gleam_files(prefix <> "src"), gleam_files(prefix <> "test"))
    |> list.filter_map(fn(file) {
      case simplifile.read(file) {
        Ok(source) ->
          Ok(#(string.drop_start(file, string.length(prefix)), source))
        Error(_) -> Error(Nil)
      }
    })
  Index(
    paths: list.map(files, fn(file) { #(file.1, file.0) }) |> dict.from_list,
    table_owners: owned_tables(files),
  )
}

/// The path of the file a module's source was read from, or an empty one.
pub fn path_of(index: Index, source: String) -> String {
  case dict.get(index.paths, source) {
    Ok(path) -> path
    Error(_) -> ""
  }
}

/// The extension a path belongs to, when it is inside one.
pub fn extension_of(path: String) -> Result(String, Nil) {
  case string.split(path, "src/albedo/harness/extensions/") {
    [_, rest] ->
      case string.split(rest, "/") {
        [name, _, ..] -> Ok(name)
        _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

fn gleam_files(directory: String) -> List(String) {
  case simplifile.get_files(directory) {
    Ok(files) -> list.filter(files, string.ends_with(_, ".gleam"))
    Error(_) -> []
  }
}

fn owned_tables(files: List(#(String, String))) -> Dict(String, String) {
  list.flat_map(files, fn(file) {
    case extension_of(file.0) {
      Ok(extension) ->
        created_tables(file.1)
        |> list.map(fn(table) { #(table, extension) })
      Error(_) -> []
    }
  })
  |> dict.from_list
}

fn created_tables(source: String) -> List(String) {
  let lowered = string.lowercase(source)
  case string.split(lowered, "create table ") {
    [] -> []
    [_, ..after] ->
      list.filter_map(after, fn(piece) {
        let name =
          string.replace(piece, "if not exists ", "")
          |> string.trim_start
          |> identifier
        case name {
          "" -> Error(Nil)
          name -> Ok(name)
        }
      })
  }
}

/// The identifier a string starts with.
pub fn identifier(text: String) -> String {
  string.to_graphemes(text)
  |> list.take_while(fn(character) {
    string.contains("abcdefghijklmnopqrstuvwxyz0123456789_", character)
  })
  |> string.concat
}
