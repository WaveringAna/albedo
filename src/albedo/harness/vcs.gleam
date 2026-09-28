//// Which repository a directory is in, and what git or jj says about it:
//// shared by anything that shows folders. Finding a repository is a stat;
//// everything else is one short-lived command per question, each with a
//// short deadline, run by `albedo_vcs.erl`. jj always runs with
//// `--ignore-working-copy`: asking never snapshots the working copy or
//// writes an operation, so its answers are as fresh as the last jj command.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/pair
import gleam/result
import gleam/string

/// A repository root, and which tool owns it. In a colocated repository jj
/// owns it: git only sees a detached HEAD there.
pub type Checkout {
  GitCheckout(root: String)
  JjCheckout(root: String)
}

/// The bookmark `@` works on, and how many changes `@` is past where it
/// left that bookmark's line.
pub type Bookmark {
  Bookmark(name: String, ahead: Int)
}

/// A repository's state. A field whose command failed or timed out is None.
pub type Repo {
  Git(
    root: String,
    /// None when HEAD is detached.
    branch: Option(String),
    /// The short HEAD id; None in an unborn repository.
    commit: Option(String),
    /// Entries `git status` reports, untracked included.
    changed: Option(Int),
    /// The last commit's time, in unix seconds.
    touched: Option(Int),
  )
  Jj(
    root: String,
    /// `@`'s shortest change id, at least four characters.
    change: Option(String),
    bookmark: Option(Bookmark),
    /// Files `@` changes.
    changed: Option(Int),
    /// `@`'s committer time, in unix seconds.
    touched: Option(Int),
  )
}

const deadline_ms = 2000

/// After every jj subcommand: never snapshot, never page, never colour.
const jj_flags = ["--ignore-working-copy", "--no-pager", "--color=never"]

/// The repository rooted at `dir` itself, if any.
pub fn at(dir: String) -> Option(Checkout) {
  case exists(child(dir, ".jj")), exists(child(dir, ".git")) {
    True, _ -> Some(JjCheckout(dir))
    False, True -> Some(GitCheckout(dir))
    False, False -> None
  }
}

/// The nearest repository enclosing the absolute, normalised `dir`.
pub fn find(dir: String) -> Option(Checkout) {
  case at(dir), parent(dir) {
    Some(checkout), _ -> Some(checkout)
    None, Some(up) -> find(up)
    None, None -> None
  }
}

pub fn repo(checkout: Checkout) -> Repo {
  case checkout {
    GitCheckout(root) -> git_repo(root)
    JjCheckout(root) -> jj_repo(root)
  }
}

/// The tracked files under `dir`, relative to it.
pub fn tracked(checkout: Checkout, dir: String) -> Result(List(String), Nil) {
  case checkout {
    GitCheckout(_) ->
      git(dir, ["ls-files", "-z"]) |> result.map(lines(_, "\u{0}"))
    JjCheckout(_) ->
      jj(dir, ["file", "list", "."]) |> result.map(lines(_, "\n"))
  }
}

/// The paths with uncommitted changes (for jj, the files `@` changes),
/// relative to the root. An untracked directory git has not looked inside
/// is one path.
pub fn changes(checkout: Checkout) -> Result(List(String), Nil) {
  case checkout {
    GitCheckout(root) ->
      git_status(root) |> result.map(fn(status) { status.paths })
    JjCheckout(root) ->
      jj(root, ["diff", "-r", "@", "--name-only"]) |> result.map(lines(_, "\n"))
  }
}

type Status {
  Status(branch: Option(String), born: Bool, paths: List(String))
}

fn git_repo(root: String) -> Repo {
  let status = git_status(root)
  let head = case status {
    Ok(Status(born: False, ..)) -> Error(Nil)
    _ ->
      git(root, ["log", "-1", "--format=%h%x09%ct"])
      |> result.try(fn(out) { string.split_once(string.trim(out), "\t") })
  }
  Git(
    root:,
    branch: status
      |> result.map(fn(status) { status.branch })
      |> option.from_result
      |> option.flatten,
    commit: head |> result.map(pair.first) |> option.from_result,
    changed: status
      |> result.map(fn(status) { list.length(status.paths) })
      |> option.from_result,
    touched: head
      |> result.try(fn(head) { int.parse(head.1) })
      |> option.from_result,
  )
}

fn git_status(root: String) -> Result(Status, Nil) {
  git(root, ["status", "--porcelain=v2", "--branch", "-z"])
  |> result.map(fn(out) {
    parse_status(string.split(out, "\u{0}"), Status(None, True, []))
  })
}

/// Porcelain v2 records, NUL-terminated: `# ` headers, then one record per
/// changed path, the path after a fixed number of fields for its kind. A
/// rename (`2`) carries its original path as the next record.
fn parse_status(records: List(String), status: Status) -> Status {
  let changed = fn(path, rest) {
    parse_status(rest, Status(..status, paths: [path, ..status.paths]))
  }
  case records {
    [] -> Status(..status, paths: list.reverse(status.paths))
    ["# branch.oid (initial)", ..rest] ->
      parse_status(rest, Status(..status, born: False))
    ["# branch.head (detached)", ..rest] -> parse_status(rest, status)
    ["# branch.head " <> name, ..rest] ->
      parse_status(rest, Status(..status, branch: Some(name)))
    ["1 " <> record, ..rest] -> changed(drop_fields(record, 7), rest)
    ["2 " <> record, _original, ..rest] -> changed(drop_fields(record, 8), rest)
    ["u " <> record, ..rest] -> changed(drop_fields(record, 9), rest)
    ["? " <> path, ..rest] -> changed(path, rest)
    [_, ..rest] -> parse_status(rest, status)
  }
}

fn drop_fields(record: String, count: Int) -> String {
  case count, string.split_once(record, " ") {
    0, _ | _, Error(_) -> record
    _, Ok(#(_, rest)) -> drop_fields(rest, count - 1)
  }
}

fn jj_repo(root: String) -> Repo {
  let at =
    jj(root, [
      "log", "-r", "@", "--no-graph", "-T",
      "change_id.shortest(4) ++ \"\\t\" ++ self.diff().files().len() ++ \"\\t\" ++ committer.timestamp().format(\"%s\")",
    ])
    |> result.map(fn(out) { string.split(string.trim(out), "\t") })
  let field = fn(index) {
    at
    |> result.try(fn(fields) { list.drop(fields, index) |> list.first })
    |> option.from_result
  }
  let number = fn(index) {
    field(index) |> option.then(fn(n) { int.parse(n) |> option.from_result })
  }
  Jj(
    root:,
    change: field(0),
    bookmark: nearest_bookmark(root),
    changed: number(1),
    touched: number(2),
  )
}

/// Where `@`'s line of work left the bookmarks: the newest change in its
/// history that a bookmark also contains.
const fork = "heads(::@ & ::bookmarks())"

/// The bookmark `@` works on, and how many changes it is past the fork. A
/// bookmark can move on without `@`, so the nearest bookmark behind `@` is
/// often an old backup instead. This is a name at the fork itself, local or
/// remote (such as git's `@git` view in a colocated repository), else the
/// newest bookmark that grew from the fork.
fn nearest_bookmark(root: String) -> Option(Bookmark) {
  let within = fn(revset, mark) {
    "if(self.contained_in(\"" <> revset <> "\"), \"" <> mark <> "\", \"\")"
  }
  let names = fn(refs) { refs <> ".map(|b| b.name()).join(\",\")" }
  // Per change: on `@`'s path, the fork, local names, all names, time.
  let template =
    [
      within(fork <> "::@", "@"),
      within(fork, "fork"),
      names("local_bookmarks"),
      names("bookmarks"),
      "committer.timestamp().format(\"%s\")",
    ]
    |> string.join(" ++ \"\\t\" ++ ")
    |> string.append(" ++ \"\\n\"")
  let revset = fork <> "::@ | roots(" <> fork <> ":: & bookmarks())"
  jj(root, ["log", "-r", revset, "--no-graph", "-T", template])
  |> result.try(fn(out) {
    let changes = lines(out, "\n") |> list.map(string.split(_, "\t"))
    let ahead =
      list.count(changes, fn(change) { list.first(change) == Ok("@") })
    use name <- result.map(fork_bookmark(changes))
    Bookmark(name, ahead - 1)
  })
  |> option.from_result
}

fn fork_bookmark(changes: List(List(String))) -> Result(String, Nil) {
  let named = fn(names) {
    string.split(names, ",") |> list.find(fn(name) { name != "" })
  }
  let at_fork =
    list.find_map(changes, fn(change) {
      case change {
        [_, "fork", local, any, _] ->
          named(local) |> result.lazy_or(fn() { named(any) })
        _ -> Error(Nil)
      }
    })
  use <- result.lazy_or(at_fork)
  changes
  |> list.filter_map(fn(change) {
    case change {
      ["", _, local, _, time] ->
        named(local)
        |> result.map(pair.new(_, int.parse(time) |> result.unwrap(0)))
      _ -> Error(Nil)
    }
  })
  |> list.sort(fn(a, b) { int.compare(b.1, a.1) })
  |> list.first
  |> result.map(pair.first)
}

fn git(dir: String, args: List(String)) -> Result(String, Nil) {
  run("git", ["--no-optional-locks", ..args], dir, deadline_ms)
}

fn jj(dir: String, args: List(String)) -> Result(String, Nil) {
  run("jj", list.append(args, jj_flags), dir, deadline_ms)
}

fn lines(out: String, separator: String) -> List(String) {
  string.split(out, separator) |> list.filter(fn(line) { line != "" })
}

fn child(dir: String, name: String) -> String {
  case dir {
    "/" -> "/" <> name
    _ -> dir <> "/" <> name
  }
}

fn parent(dir: String) -> Option(String) {
  case dir, list.reverse(string.split(dir, "/")) {
    "/", _ -> None
    _, [_, ""] -> Some("/")
    _, [_, ..rest] -> Some(rest |> list.reverse |> string.join("/"))
    _, [] -> None
  }
}

/// A file or directory: `.git` is a file in a worktree.
@external(erlang, "filelib", "is_file")
fn exists(path: String) -> Bool

@external(erlang, "albedo_vcs", "run")
fn run(
  program: String,
  args: List(String),
  cwd: String,
  timeout_ms: Int,
) -> Result(String, Nil)
