//// `folders.read_file` on a local workspace: how a path resolves against
//// the workspace, and which files are refused. E2E would need a file at
//// exactly the byte limit and one past it, and invalid UTF-8, for every
//// case; here each boundary is one direct read.

import albedo/daemon/folders
import albedo/harness/location
import gleam/string

@external(erlang, "albedo_runtime_test_support", "temporary_workspace")
fn temporary_workspace() -> String

@external(erlang, "albedo_runtime_test_support", "cleanup_workspace")
fn cleanup_workspace(path: String) -> Nil

@external(erlang, "albedo_folders_test_support", "write")
fn write(path: String, bytes: BitArray) -> Nil

@external(erlang, "albedo_folders_test_support", "make_dir")
fn make_dir(path: String) -> Nil

fn in_workspace(run: fn(String, location.Location) -> Nil) -> Nil {
  let dir = temporary_workspace()
  run(dir, location.Local(dir))
  cleanup_workspace(dir)
}

pub fn relative_and_absolute_paths_read_the_same_file_test() -> Nil {
  use dir, workspace <- in_workspace
  make_dir(dir <> "/sub")
  write(dir <> "/sub/notes.md", <<"hello\n":utf8>>)
  let assert Ok(folders.File(location, 6, modified, "hello\n")) =
    folders.read_file(workspace, "sub/notes.md")
  let assert True = location == dir <> "/sub/notes.md"
  let assert True = modified > 0
  let assert Ok(folders.File(again, ..)) =
    folders.read_file(workspace, "./sub/../sub/notes.md")
  let assert True = again == location
  let assert Ok(folders.File(absolute, ..)) =
    folders.read_file(workspace, dir <> "/sub/notes.md")
  let assert True = absolute == location
  Nil
}

pub fn files_at_the_limit_are_read_and_past_it_refused_test() -> Nil {
  use dir, workspace <- in_workspace
  let limit = folders.file_limit
  write(dir <> "/full.txt", <<string.repeat("x", limit):utf8>>)
  write(dir <> "/over.txt", <<string.repeat("x", limit + 1):utf8>>)
  let assert Ok(folders.File(size:, ..)) =
    folders.read_file(workspace, "full.txt")
  let assert True = size == limit
  let assert Error(folders.TooLarge(_, over)) =
    folders.read_file(workspace, "over.txt")
  let assert True = over == limit + 1
  Nil
}

pub fn binary_and_invalid_utf8_are_not_text_test() -> Nil {
  use dir, workspace <- in_workspace
  write(dir <> "/nul.bin", <<"a":utf8, 0, "b":utf8>>)
  write(dir <> "/latin1.txt", <<"caf":utf8, 0xE9>>)
  let assert Error(folders.NotText(_)) = folders.read_file(workspace, "nul.bin")
  let assert Error(folders.NotText(_)) =
    folders.read_file(workspace, "latin1.txt")
  Nil
}

pub fn missing_files_directories_and_other_hosts_are_refused_test() -> Nil {
  use dir, workspace <- in_workspace
  make_dir(dir <> "/sub")
  let assert Error(folders.NotAFile(_, "does not exist")) =
    folders.read_file(workspace, "absent.txt")
  let assert Error(folders.NotAFile(_, "does not exist")) =
    folders.read_file(workspace, "absent/inner.txt")
  let assert Error(folders.NotAFile(_, "is a directory")) =
    folders.read_file(workspace, "sub")
  let assert Error(folders.BadPath(_)) = folders.read_file(workspace, "")
  let assert Error(folders.BadPath(_)) =
    folders.read_file(workspace, "chernobog:/etc/hosts")
  Nil
}
