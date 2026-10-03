//// Native directory and preview observations behind `/workspaces` and `/cd`.
//// A local path is
//// read on the daemon, so the picker only offers folders the daemon can
//// see; a `host:/path` is gathered on that host in one ssh round trip
//// (priv/python/albedo_gather.py) and read by the same code, through a
//// `Machine` that answers from the snapshot.

import albedo/harness/languages.{type Language}
import albedo/harness/location
import albedo/harness/ssh
import albedo/harness/vcs
import gleam/bool
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/set
import gleam/string

/// A request that cannot be answered: the status and the error body.
pub type Failure =
  #(Int, Json)

/// Where a browse reads: this machine, or one gathered snapshot of another.
type Machine {
  Machine(
    shell: vcs.Shell,
    entries: fn(String) -> List(Entry),
    file_size: fn(String) -> Result(Int, Nil),
    home: String,
    /// How a path there is spelled in an answer.
    show: fn(String) -> String,
  )
}

/// What a route needs gathered on a remote host.
type Route {
  Listing
  Preview
}

/// A directory entry preserves its link identity while following its target
/// to determine whether the folder picker can enter it.
pub type Entry {
  Entry(name: String, dir: Bool, modified: Int, symlink: Bool)
}

pub type DirectoryItem {
  DirectoryItem(
    name: String,
    location: String,
    vcs: Option(String),
    modified: Int,
    hidden: Bool,
  )
}

pub type Directory {
  Directory(
    location: String,
    parent: Option(String),
    home: String,
    items: List(DirectoryItem),
  )
}

pub fn directory(path: String) -> Result(Directory, Failure) {
  use #(machine, dir) <- result.try(open(path, Listing))
  let items =
    machine.entries(dir)
    |> list.filter(fn(entry) { entry.dir })
    |> list.sort(fn(a, b) { by_name(a.name, b.name) })
    |> list.map(fn(entry) {
      DirectoryItem(
        entry.name,
        machine.show(child(dir, entry.name)),
        option.map(vcs.at(machine.shell, child(dir, entry.name)), vcs_name),
        entry.modified,
        string.starts_with(entry.name, "."),
      )
    })
  let parent = case dir {
    "/" -> None
    _ -> Some(machine.show(parent_path(dir)))
  }
  Ok(Directory(machine.show(dir), parent, machine.show(machine.home), items))
}

fn parent_path(path: String) -> String {
  let parts =
    string.split(path, "/") |> list.reverse |> list.drop(1) |> list.reverse
  case string.join(parts, "/") {
    "" -> "/"
    parent -> parent
  }
}

pub type LanguageShare {
  LanguageShare(name: String, bytes: Int, share: Float, color: Option(String))
}

pub type TreeItem {
  TreeItem(
    name: String,
    directory: Bool,
    location: String,
    language: Option(String),
    changed: Int,
    children: List(TreeItem),
    more: Int,
    symlink: Bool,
  )
}

pub type PreviewObservation {
  PreviewObservation(
    repository: Option(vcs.Repo),
    languages: List(LanguageShare),
    tree: List(TreeItem),
    more: Int,
  )
}

pub fn observe_preview(path: String) -> Result(PreviewObservation, Failure) {
  use #(machine, dir) <- result.try(open(path, Preview))
  let shell = machine.shell
  let checkout = vcs.find(shell, dir)
  let #(tracked, changed, shows) = case checkout {
    Some(checkout) -> {
      let tracked = vcs.tracked(shell, checkout, dir) |> result.unwrap([])
      let changed =
        vcs.changes(shell, checkout)
        |> result.unwrap([])
        |> list.filter_map(inside(_, subpath(checkout.root, dir)))
      #(tracked, changed, known(tracked, changed))
    }
    None -> #([], [], fn(_) { True })
  }
  let #(shown, more) = visible(machine, dir, shows) |> list.split(tree_entries)
  let tree =
    list.map(shown, fn(entry) {
      let changed_inside = list.filter_map(changed, inside(_, entry.name))
      let #(children, more) = case entry.dir {
        True ->
          visible(machine, child(dir, entry.name), fn(name) {
            shows(entry.name <> "/" <> name)
          })
          |> list.split(tree_children)
        False -> #([], [])
      }
      let children =
        list.map(children, tree_item(
          machine,
          child(dir, entry.name),
          _,
          changed_inside,
          [],
          0,
        ))
      tree_item(machine, dir, entry, changed, children, list.length(more))
    })
  Ok(PreviewObservation(
    option.map(checkout, vcs.repo(shell, _)),
    language_shares(machine, tracked, dir),
    tree,
    list.length(more),
  ))
}

fn tree_item(
  machine: Machine,
  dir: String,
  entry: Entry,
  changed: List(String),
  children: List(TreeItem),
  more: Int,
) -> TreeItem {
  TreeItem(
    entry.name,
    entry.dir,
    machine.show(child(dir, entry.name)),
    case entry.dir {
      True -> None
      False ->
        languages.detect(entry.name)
        |> option.map(fn(language) { language.name })
    },
    changed_at(changed, entry.name),
    children,
    more,
    entry.symlink,
  )
}

const tree_entries = 12

const tree_children = 4

const shown_languages = 4

/// Shares are by bytes over at most this many tracked files, so a huge
/// repository previews as quickly as a small one: past the cap, the shares
/// are those of the first files the vcs lists rather than of every file.
const counted_files = 20_000

/// The machine `path` is on, and the directory it names there, expanded
/// and normalised, when that is an existing directory.
fn open(path: String, route: Route) -> Result(#(Machine, String), Failure) {
  case path {
    "~" | "~/" <> _ | "/" <> _ -> {
      let machine =
        Machine(vcs.local(), entries, file_size, normalise(home()), fn(path) {
          path
        })
      let dir = normalise(expand(path, machine.home))
      case is_directory(dir) {
        True -> Ok(#(machine, dir))
        False -> Error(missing(dir))
      }
    }
    _ -> remote(path, route)
  }
}

fn expand(path: String, home: String) -> String {
  case path {
    "~" -> home
    "~/" <> rest -> home <> "/" <> rest
    _ -> path
  }
}

fn missing(dir: String) -> Failure {
  failure(404, dir <> " is not a directory")
}

fn failure(status: Int, message: String) -> Failure {
  #(status, json.object([#("error", json.string(message))]))
}

/// `[user@]host:/path` or `[user@]host:~/path`, gathered on that host.
fn remote(path: String, route: Route) -> Result(#(Machine, String), Failure) {
  let #(head, rest) = case string.split_once(path, ":~") {
    Ok(#(head, rest)) -> #(head, "~" <> rest)
    Error(_) -> #(path, "")
  }
  let parsed = case rest {
    "" -> location.parse(path)
    _ -> location.parse(head <> ":/")
  }
  use #(at, user, name, absolute) <- result.try(case parsed {
    Ok(location.Remote(user, host, absolute) as at) ->
      Ok(#(at, user, host, absolute))
    _ ->
      Error(failure(
        400,
        "path must be absolute, start with ~, or be host:/path",
      ))
  })
  use target <- result.try(
    location.ssh_target(at) |> result.replace_error(failure(400, "not a host")),
  )
  use host <- result.try(
    ssh.ready(target, ssh.boot_wait_ms)
    |> result.map_error(unreachable(target, _)),
  )
  let dir = case rest {
    "" -> absolute
    _ -> normalise(expand(rest, host.home))
  }
  let show = fn(path) { location.to_string(location.Remote(user, name, path)) }
  let request =
    json.object([
      #("route", json.string(route_name(route))),
      #("dir", json.string(dir)),
      #("plans", plans(route)),
      #(
        "tracked",
        json.object([#("git", tracked(False)), #("jj", tracked(True))]),
      ),
      #("deadline", json.float(int.to_float(vcs.deadline_ms) /. 1000.0)),
      #("counted", json.int(counted_files)),
    ])
  use answer <- result.try(
    ssh.gather(host, request, gather_ms) |> result.map_error(failure(502, _)),
  )
  use snapshot <- result.try(
    json.parse(answer, snapshot_decoder())
    |> result.replace_error(failure(
      502,
      "the gather on " <> target <> " answered badly",
    )),
  )
  case snapshot.directory {
    False -> Error(missing(show(dir)))
    True -> Ok(#(gathered(snapshot, host.home, show), dir))
  }
}

/// The vcs commands' own deadline on the host, plus the ssh round trip.
const gather_ms = 20_000

/// Whether a workspace's folder exists. A remote one is asked on its host
/// over the shared ControlMaster; a host not ready within `wait_ms` answers
/// why instead (0 takes only a recent probe, starting one in the background),
/// so an unreachable folder never reads as a missing one.
pub fn exists(
  workspace: location.Location,
  wait_ms: Int,
) -> Result(Bool, ssh.Failure) {
  case workspace, location.ssh_target(workspace) {
    location.Local(path), _ -> Ok(is_directory(path))
    location.Remote(path:, ..), Ok(target) -> {
      use host <- result.try(case wait_ms {
        0 -> ssh.known(target)
        _ -> ssh.ready(target, wait_ms)
      })
      let request =
        json.object([
          #("route", json.string("exists")),
          #("dir", json.string(path)),
        ])
      ssh.gather(host, request, exists_ms)
      |> result.try(fn(answer) {
        json.parse(
          answer,
          decode.field("directory", decode.bool, decode.success),
        )
        |> result.replace_error("the gather on " <> target <> " answered badly")
      })
      |> result.map_error(ssh.Unreachable)
    }
    location.Remote(..), Error(Nil) -> Error(ssh.Unreachable("not a host"))
  }
}

/// One stat on a host that already answered its probe.
pub const exists_ms = 5000

fn route_name(route: Route) -> String {
  case route {
    Listing -> "list"
    Preview -> "preview"
  }
}

fn plans(route: Route) -> Json {
  let plan = fn(jj) { json.array(vcs.plan(jj, route == Preview), command) }
  json.object([#("git", plan(False)), #("jj", plan(True))])
}

/// Which planned command lists a preview's tracked files, and how its
/// output splits.
fn tracked(jj: Bool) -> Json {
  json.object([
    #("command", command(vcs.tracked_command(jj))),
    #("separator", json.string(vcs.tracked_separator(jj))),
  ])
}

fn command(command: vcs.Command) -> Json {
  json.preprocessed_array([
    json.string(command.program),
    json.array(command.args, json.string),
    json.string(case command.at {
      vcs.AtRoot -> "root"
      vcs.AtDir -> "dir"
    }),
  ])
}

/// A host without a ready probe answers with the probe's state, so the
/// picker can show it on the row.
fn unreachable(target: String, why: ssh.Failure) -> Failure {
  let #(state, extra) = case why {
    ssh.NeedsAuth(_, control) -> #("needs_auth", [
      #("control_path", json.string(control)),
    ])
    ssh.Unreachable(_) -> #("unreachable", [])
    ssh.Unsupported(_) -> #("unsupported", [])
    ssh.Warming -> #("warming", [])
  }
  #(
    503,
    json.object([
      #("error", json.string(ssh.describe(target, why))),
      #("host", json.string(target)),
      #("state", json.string(state)),
      ..extra
    ]),
  )
}

type Snapshot {
  Snapshot(
    directory: Bool,
    entries: Dict(String, List(Entry)),
    exists: List(String),
    outputs: Dict(String, String),
    sizes: Dict(String, Int),
  )
}

fn snapshot_decoder() -> decode.Decoder(Snapshot) {
  let entry = {
    use name <- decode.field(0, decode.string)
    use dir <- decode.field(1, decode.bool)
    use modified <- decode.field(2, decode.int)
    use symlink <- decode.field(3, decode.bool)
    decode.success(Entry(name, dir, modified, symlink))
  }
  use directory <- decode.field("directory", decode.bool)
  use entries <- decode.optional_field(
    "entries",
    dict.new(),
    decode.dict(decode.string, decode.list(entry)),
  )
  use exists <- decode.optional_field("exists", [], decode.list(decode.string))
  use outputs <- decode.optional_field(
    "outputs",
    dict.new(),
    decode.dict(decode.string, decode.string),
  )
  use sizes <- decode.optional_field(
    "sizes",
    dict.new(),
    decode.dict(decode.string, decode.int),
  )
  decode.success(Snapshot(directory, entries, exists, outputs, sizes))
}

/// A machine that answers from one gathered snapshot: what was not gathered
/// does not exist, and a command that did not answer failed.
fn gathered(
  snapshot: Snapshot,
  home: String,
  show: fn(String) -> String,
) -> Machine {
  let exists = set.from_list(snapshot.exists)
  let shell =
    vcs.Shell(exists: set.contains(exists, _), run: fn(command, _cwd) {
      dict.get(
        snapshot.outputs,
        string.join([command.program, ..command.args], "\u{0}"),
      )
    })
  Machine(
    shell:,
    entries: fn(dir) { dict.get(snapshot.entries, dir) |> result.unwrap([]) },
    file_size: dict.get(snapshot.sizes, _),
    home:,
    show:,
  )
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
fn language_shares(
  machine: Machine,
  tracked: List(String),
  dir: String,
) -> List(LanguageShare) {
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
      use size <- result.map(machine.file_size(child(dir, file)))
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
        LanguageShare(
          counted.0.name,
          counted.1,
          int.to_float(counted.1) /. int.to_float(total),
          counted.0.color,
        )
      })
  }
}

fn towards_group(language: Language) -> Language {
  language.group
  |> option.then(languages.named)
  |> option.unwrap(language)
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
fn visible(
  machine: Machine,
  dir: String,
  shows: fn(String) -> Bool,
) -> List(Entry) {
  machine.entries(dir)
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
