//// Which repository a directory is in, and what git or jj says about it:
//// shared by anything that shows folders. Finding a repository is a stat;
//// everything else is one short-lived command per question, each with a
//// short deadline. jj always runs with `--ignore-working-copy`: asking never
//// snapshots the working copy or writes an operation, so its answers are as
//// fresh as the last jj command.
////
//// Every question goes through a `Shell`: `local` stats and runs here (in
//// `albedo_vcs.erl`); a remote host's shell answers from what one gather
//// over ssh collected, running the commands `plan` names. Either way the
//// answers are read by the same code below.

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

pub const deadline_ms = 2000

/// How questions about a machine's files are answered.
pub type Shell {
  Shell(
    /// A file or directory exists at the path.
    exists: fn(String) -> Bool,
    /// One command's stdout, run in a directory, when it exits 0 in time.
    run: fn(Command, String) -> Result(String, Nil),
  )
}

/// One command a question runs: a program, its arguments, and where.
pub type Command {
  Command(program: String, args: List(String), at: Place)
}

pub type Place {
  /// The repository root.
  AtRoot
  /// The directory asked about.
  AtDir
}

/// This machine.
pub fn local() -> Shell {
  Shell(exists:, run: fn(command: Command, cwd) {
    run(command.program, command.args, cwd, deadline_ms)
  })
}

/// Every command `repo` (and, for a preview, `tracked` and `changes`) may
/// run for a checkout of this kind, for a gather that runs them elsewhere.
pub fn plan(jj: Bool, preview: Bool) -> List(Command) {
  case jj, preview {
    False, False -> [git_status, git_head]
    False, True -> [git_status, git_head, git_tracked]
    True, False -> [jj_at, jj_bookmarks()]
    True, True -> [jj_at, jj_bookmarks(), jj_tracked, jj_changes]
  }
}

const git_status =
  Command(
    "git",
    ["--no-optional-locks", "status", "--porcelain=v2", "--branch", "-z"],
    AtRoot,
  )

const git_head =
  Command(
    "git",
    ["--no-optional-locks", "log", "-1", "--format=%h%x09%ct"],
    AtRoot,
  )

const git_tracked =
  Command("git", ["--no-optional-locks", "ls-files", "-z"], AtDir)

const jj_at =
  Command(
    "jj",
    [
      "log",
      "-r",
      "@",
      "--no-graph",
      "-T",
      "change_id.shortest(4) ++ \"\\t\" ++ self.diff().files().len() ++ \"\\t\" ++ committer.timestamp().format(\"%s\")",
      ..jj_flags
    ],
    AtRoot,
  )

const jj_tracked = Command("jj", ["file", "list", ".", ..jj_flags], AtDir)

const jj_changes =
  Command("jj", ["diff", "-r", "@", "--name-only", ..jj_flags], AtRoot)

/// After every jj subcommand: never snapshot, never page, never colour.
const jj_flags = ["--ignore-working-copy", "--no-pager", "--color=never"]

/// The repository rooted at `dir` itself, if any.
pub fn at(shell: Shell, dir: String) -> Option(Checkout) {
  case shell.exists(child(dir, ".jj")), shell.exists(child(dir, ".git")) {
    True, _ -> Some(JjCheckout(dir))
    False, True -> Some(GitCheckout(dir))
    False, False -> None
  }
}

/// The nearest repository enclosing the absolute, normalised `dir`.
pub fn find(shell: Shell, dir: String) -> Option(Checkout) {
  case at(shell, dir), parent(dir) {
    Some(checkout), _ -> Some(checkout)
    None, Some(up) -> find(shell, up)
    None, None -> None
  }
}

pub fn repo(shell: Shell, checkout: Checkout) -> Repo {
  case checkout {
    GitCheckout(root) -> git_repo(shell, root)
    JjCheckout(root) -> jj_repo(shell, root)
  }
}

/// The tracked files under `dir`, relative to it.
pub fn tracked(
  shell: Shell,
  checkout: Checkout,
  dir: String,
) -> Result(List(String), Nil) {
  case checkout {
    GitCheckout(_) ->
      shell.run(git_tracked, dir) |> result.map(lines(_, "\u{0}"))
    JjCheckout(_) -> shell.run(jj_tracked, dir) |> result.map(lines(_, "\n"))
  }
}

/// The command `tracked` runs, for a gather that sizes what it lists.
pub fn tracked_command(jj: Bool) -> Command {
  case jj {
    True -> jj_tracked
    False -> git_tracked
  }
}

/// How `tracked` output splits into paths, for a gather that sizes them.
pub fn tracked_separator(jj: Bool) -> String {
  case jj {
    True -> "\n"
    False -> "\u{0}"
  }
}

/// The paths with uncommitted changes (for jj, the files `@` changes),
/// relative to the root. An untracked directory git has not looked inside
/// is one path.
pub fn changes(shell: Shell, checkout: Checkout) -> Result(List(String), Nil) {
  case checkout {
    GitCheckout(root) ->
      status(shell, root) |> result.map(fn(status) { status.paths })
    JjCheckout(root) ->
      shell.run(jj_changes, root) |> result.map(lines(_, "\n"))
  }
}

type Status {
  Status(branch: Option(String), born: Bool, paths: List(String))
}

fn git_repo(shell: Shell, root: String) -> Repo {
  let status = status(shell, root)
  let head = case status {
    Ok(Status(born: False, ..)) -> Error(Nil)
    _ ->
      shell.run(git_head, root)
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

fn status(shell: Shell, root: String) -> Result(Status, Nil) {
  shell.run(git_status, root)
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

fn jj_repo(shell: Shell, root: String) -> Repo {
  let at =
    shell.run(jj_at, root)
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
    bookmark: nearest_bookmark(shell, root),
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
fn nearest_bookmark(shell: Shell, root: String) -> Option(Bookmark) {
  shell.run(jj_bookmarks(), root)
  |> result.try(fn(out) {
    let changes = lines(out, "\n") |> list.map(string.split(_, "\t"))
    let ahead =
      list.count(changes, fn(change) { list.first(change) == Ok("@") })
    use name <- result.map(fork_bookmark(changes))
    Bookmark(name, ahead - 1)
  })
  |> option.from_result
}

/// One line per change on `@`'s path and the bookmarks grown from the fork.
fn jj_bookmarks() -> Command {
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
  Command(
    "jj",
    ["log", "-r", revset, "--no-graph", "-T", template, ..jj_flags],
    AtRoot,
  )
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
