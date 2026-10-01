//// The folder browser behind `/cd`: `/fs/list`, `/fs/repo` and
//// `/fs/preview`, as robot-docs/workspaces.md specifies. Everything is read
//// on the daemon, so the picker only offers folders the daemon can see.

import albedo/harness/languages.{type Language}
import albedo/harness/location
import albedo/harness/vcs
import gleam/bool
import gleam/dict
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{None, Some}
import gleam/order
import gleam/result
import gleam/set
import gleam/string

/// A request that cannot be answered: the status and the message.
pub type Failure =
  #(Int, String)

/// One directory entry, built by `albedo_folders.erl`; a symlink counts as
/// what it points at.
pub type Entry {
  Entry(name: String, dir: Bool, modified: Int)
}

const listed_entries = 2000

const tree_entries = 12

const tree_children = 4

const shown_languages = 4

/// Shares are by bytes over at most this many tracked files, so a huge
/// repository previews as quickly as a small one: past the cap, the shares
/// are those of the first files the vcs lists rather than of every file.
const counted_files = 20_000

/// The directories directly inside `path`.
pub fn list(path: String) -> Result(Json, Failure) {
  use dir <- result.map(directory(path))
  let #(shown, rest) =
    entries(dir)
    |> list.filter(fn(entry) { entry.dir })
    |> list.sort(fn(a, b) { by_name(a.name, b.name) })
    |> list.split(listed_entries)
  json.object([
    #("path", json.string(dir)),
    #("home", json.string(normalise(home()))),
    #("truncated", json.bool(rest != [])),
    #(
      "entries",
      json.array(shown, fn(entry) {
        json.object([
          #("name", json.string(entry.name)),
          #("modified", json.int(entry.modified)),
          #("hidden", json.bool(string.starts_with(entry.name, "."))),
          #(
            "vcs",
            json.nullable(vcs.at(child(dir, entry.name)), fn(checkout) {
              json.string(vcs_name(checkout))
            }),
          ),
        ])
      }),
    ),
  ])
}

/// The repository `path` is in, or null.
pub fn repo(path: String) -> Result(Json, Failure) {
  use dir <- result.map(directory(path))
  json.object([
    #("repo", json.nullable(vcs.find(dir) |> option.map(vcs.repo), repo_json)),
  ])
}

/// Everything the picker's preview pane shows for `path`.
pub fn preview(path: String) -> Result(Json, Failure) {
  use dir <- result.map(directory(path))
  let checkout = vcs.find(dir)
  let #(tracked, changed, shows) = case checkout {
    Some(checkout) -> {
      let tracked = vcs.tracked(checkout, dir) |> result.unwrap([])
      let changed =
        vcs.changes(checkout)
        |> result.unwrap([])
        |> list.filter_map(inside(_, subpath(checkout.root, dir)))
      #(tracked, changed, known(tracked, changed))
    }
    None -> #([], [], fn(_) { True })
  }
  let #(shown, more) = visible(dir, shows) |> list.split(tree_entries)
  json.object([
    #("path", json.string(dir)),
    #("repo", json.nullable(option.map(checkout, vcs.repo), repo_json)),
    #(
      "languages",
      json.array(shares(tracked, dir), fn(share) {
        let #(language, fraction) = share
        json.object([
          #("name", json.string(language.name)),
          #("color", json.nullable(language.color, json.string)),
          #("share", json.float(fraction)),
        ])
      }),
    ),
    #("tree", json.array(shown, top_entry_json(dir, _, changed, shows))),
    #("more", json.int(list.length(more))),
  ])
}

/// `path` expanded and normalised, when it names an existing directory.
fn directory(path: String) -> Result(String, Failure) {
  use absolute <- result.try(case path, location.parse(path) {
    "~", _ -> Ok(home())
    "~/" <> rest, _ -> Ok(home() <> "/" <> rest)
    "/" <> _, _ -> Ok(path)
    _, Ok(location.Remote(host:, ..)) ->
      Error(#(400, location.unavailable(host, "folders")))
    _, _ -> Error(#(400, "path must be absolute or start with ~"))
  })
  let dir = normalise(absolute)
  case is_directory(dir) {
    True -> Ok(dir)
    False -> Error(#(404, dir <> " is not a directory"))
  }
}

fn normalise(path: String) -> String {
  let parts =
    string.split(path, "/")
    |> list.fold([], fn(parts, part) {
      case part {
        "" | "." -> parts
        ".." -> list.drop(parts, 1)
        _ -> [part, ..parts]
      }
    })
  "/" <> string.join(list.reverse(parts), "/")
}

fn vcs_name(checkout: vcs.Checkout) -> String {
  case checkout {
    vcs.GitCheckout(_) -> "git"
    vcs.JjCheckout(_) -> "jj"
  }
}

fn repo_json(repo: vcs.Repo) -> Json {
  case repo {
    vcs.Git(root:, branch:, commit:, changed:, touched:) ->
      json.object([
        #("kind", json.string("git")),
        #("root", json.string(root)),
        #("branch", json.nullable(branch, json.string)),
        #("commit", json.nullable(commit, json.string)),
        #("changed", json.nullable(changed, json.int)),
        #("touched", json.nullable(touched, json.int)),
      ])
    vcs.Jj(root:, change:, bookmark:, changed:, touched:) ->
      json.object([
        #("kind", json.string("jj")),
        #("root", json.string(root)),
        #("change", json.nullable(change, json.string)),
        #(
          "bookmark",
          json.nullable(bookmark, fn(bookmark) {
            json.object([
              #("name", json.string(bookmark.name)),
              #("ahead", json.int(bookmark.ahead)),
            ])
          }),
        ),
        #("changed", json.nullable(changed, json.int)),
        #("touched", json.nullable(touched, json.int)),
      ])
  }
}

/// Inside a repository the tree shows only tracked or changed paths, so
/// build output and other ignored files stay out while new files show. A
/// path under a changed one shows too: git reports a new directory whole.
fn known(tracked: List(String), changed: List(String)) -> fn(String) -> Bool {
  let shown =
    list.append(tracked, changed)
    |> list.flat_map(fn(path) {
      case string.split(path, "/") {
        [top, next, ..] -> [top, top <> "/" <> next]
        _ -> [path]
      }
    })
    |> set.from_list
  fn(path) {
    set.contains(shown, path)
    || list.any(changed, fn(changed) {
      string.starts_with(path, changed <> "/")
    })
  }
}

/// The largest counted languages among `tracked`, the files under `dir`,
/// each with its share of all counted bytes. A language in a group counts
/// towards the group's language, as on github.
fn shares(tracked: List(String), dir: String) -> List(#(Language, Float)) {
  let bytes =
    tracked
    |> list.take(counted_files)
    |> list.filter_map(fn(file) {
      use language <- result.try(
        languages.detect(base_name(file))
        |> option.map(towards_group)
        |> option.to_result(Nil),
      )
      use <- bool.guard(!languages.counted(language), Error(Nil))
      use size <- result.map(file_size(child(dir, file)))
      #(language, size)
    })
    |> list.fold(dict.new(), fn(bytes, counted) {
      let #(language, size) = counted
      dict.upsert(bytes, language.name, fn(total) {
        case total {
          Some(#(_, total)) -> #(language, total + size)
          None -> #(language, size)
        }
      })
    })
    |> dict.values
  let total = list.fold(bytes, 0, fn(sum, counted) { sum + counted.1 })
  case total {
    0 -> []
    _ ->
      bytes
      |> list.sort(fn(a, b) { int.compare(b.1, a.1) })
      |> list.take(shown_languages)
      |> list.map(fn(counted) {
        #(counted.0, int.to_float(counted.1) /. int.to_float(total))
      })
  }
}

fn towards_group(language: Language) -> Language {
  language.group
  |> option.then(languages.named)
  |> option.unwrap(language)
}

fn top_entry_json(
  dir: String,
  entry: Entry,
  changed: List(String),
  shows: fn(String) -> Bool,
) -> Json {
  case entry.dir {
    False -> entry_json(entry, changed, [])
    True -> {
      let changed_inside = list.filter_map(changed, inside(_, entry.name))
      let #(children, more) =
        visible(child(dir, entry.name), fn(name) {
          shows(entry.name <> "/" <> name)
        })
        |> list.split(tree_children)
      entry_json(entry, changed, [
        #("more", json.int(list.length(more))),
        #("children", json.array(children, entry_json(_, changed_inside, []))),
      ])
    }
  }
}

/// A tree entry: its name, whether it is a directory, the changes at or
/// under it, and `fields` besides; a file also names its language.
fn entry_json(
  entry: Entry,
  changed: List(String),
  fields: List(#(String, Json)),
) -> Json {
  let fields = case entry.dir {
    True -> fields
    False -> [
      #(
        "language",
        json.nullable(
          languages.detect(entry.name) |> option.map(fn(l) { l.name }),
          json.string,
        ),
      ),
      ..fields
    ]
  }
  json.object([
    #("name", json.string(entry.name)),
    #("dir", json.bool(entry.dir)),
    #("changed", json.int(changed_at(changed, entry.name))),
    ..fields
  ])
}

/// The changed paths at or under `name`.
fn changed_at(changed: List(String), name: String) -> Int {
  list.count(changed, fn(path) {
    path == name || string.starts_with(path, name <> "/")
  })
}

/// Where `dir`, at or under `root`, sits inside it: "" for the root itself.
fn subpath(root: String, dir: String) -> String {
  case dir == root, root {
    True, _ -> ""
    False, "/" -> string.drop_start(dir, 1)
    False, _ -> string.drop_start(dir, string.length(root) + 1)
  }
}

/// `path` relative to `prefix`, when it lies inside it. A trailing slash
/// (git's untracked directories) is dropped.
fn inside(path: String, prefix: String) -> Result(String, Nil) {
  let path = case string.ends_with(path, "/") {
    True -> string.drop_end(path, 1)
    False -> path
  }
  case prefix, string.starts_with(path, prefix <> "/") {
    "", _ -> Ok(path)
    _, True -> Ok(string.drop_start(path, string.length(prefix) + 1))
    _, False -> Error(Nil)
  }
}

/// Entries `shows` keeps, without a leading dot: directories first, then
/// files, by name.
fn visible(dir: String, shows: fn(String) -> Bool) -> List(Entry) {
  entries(dir)
  |> list.filter(fn(entry) {
    !string.starts_with(entry.name, ".") && shows(entry.name)
  })
  |> list.sort(fn(a, b) {
    case a.dir, b.dir {
      True, False -> order.Lt
      False, True -> order.Gt
      _, _ -> by_name(a.name, b.name)
    }
  })
}

/// Case-insensitive, with exact order breaking ties.
fn by_name(a: String, b: String) -> order.Order {
  string.compare(string.lowercase(a), string.lowercase(b))
  |> order.break_tie(string.compare(a, b))
}

fn base_name(path: String) -> String {
  string.split(path, "/") |> list.last |> result.unwrap(path)
}

fn child(dir: String, name: String) -> String {
  case dir {
    "/" -> "/" <> name
    _ -> dir <> "/" <> name
  }
}

@external(erlang, "albedo_folders", "home")
fn home() -> String

@external(erlang, "filelib", "is_dir")
fn is_directory(path: String) -> Bool

@external(erlang, "albedo_folders", "entries")
fn entries(dir: String) -> List(Entry)

@external(erlang, "albedo_folders", "file_size")
fn file_size(path: String) -> Result(Int, Nil)
