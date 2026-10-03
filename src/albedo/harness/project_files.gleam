//// Project files the daemon itself reads from a workspace (AGENTS.md and the
//// other instruction files, project skills). A local workspace is read in
//// place. A remote one is gathered from its host in one ssh round trip into
//// a daemon-side mirror under `$ALBEDO_HOME/mirror/`, which the same readers
//// then read as if it were the workspace. A mirror is refreshed at most
//// every few seconds, so composing one session reads the host once.

import albedo/harness/location
import albedo/harness/settings
import albedo/harness/ssh
import gleam/bit_array
import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

/// Observe an existing mirror without contacting its host or refreshing files.
/// A missing mirror leaves only the daemon's home sources for inspection.
pub fn observed(workspace: String) -> Option(String) {
  case location.parse(workspace) {
    Ok(location.Remote(..)) -> {
      let mirror = settings.home() <> "/mirror/" <> digest(workspace)
      case mirrored(mirror) {
        True -> Some(mirror)
        False -> None
      }
    }
    _ -> Some(workspace)
  }
}

@external(erlang, "albedo_project_mirror", "observed")
fn mirrored(mirror: String) -> Bool

/// The directory to read `workspace`'s project files from, or why there is
/// none right now (a host out of reach), which the readers report as a
/// warning while the home directories still count.
pub fn readable(workspace: String) -> Result(String, String) {
  case location.parse(workspace) {
    Ok(location.Remote(path:, ..) as at) -> {
      use target <- result.try(
        location.ssh_target(at) |> result.replace_error("not a remote host"),
      )
      let mirror = settings.home() <> "/mirror/" <> digest(workspace)
      case fresh(mirror, fresh_ms) {
        True -> Ok(mirror)
        False -> refresh(target, path, mirror)
      }
    }
    _ -> Ok(workspace)
  }
}

const fresh_ms = 5000

fn refresh(
  target: String,
  path: String,
  mirror: String,
) -> Result(String, String) {
  use host <- result.try(
    ssh.ready(target, 10_000) |> result.map_error(ssh.describe(target, _)),
  )
  let request =
    json.object([
      #("route", json.string("project")),
      #("dir", json.string(path)),
    ])
  use answer <- result.try(ssh.gather(host, request, 20_000))
  let decoder = {
    use directory <- decode.field("directory", decode.bool)
    use files <- decode.optional_field(
      "files",
      dict.new(),
      decode.dict(decode.string, decode.string),
    )
    decode.success(#(directory, files))
  }
  use #(directory, files) <- result.try(
    json.parse(answer, decoder)
    |> result.replace_error("the gather on " <> target <> " answered badly"),
  )
  case directory {
    False -> Error(path <> " is not a folder on " <> target)
    True -> {
      let files =
        dict.to_list(files)
        |> list.filter_map(fn(file) {
          bit_array.base64_decode(file.1)
          |> result.map(fn(data) { #(file.0, data) })
        })
      replace(mirror, files)
      |> result.replace(mirror)
    }
  }
}

@external(erlang, "albedo_project_mirror", "digest")
fn digest(workspace: String) -> String

@external(erlang, "albedo_project_mirror", "fresh")
fn fresh(mirror: String, within_ms: Int) -> Bool

@external(erlang, "albedo_project_mirror", "replace")
fn replace(
  mirror: String,
  files: List(#(String, BitArray)),
) -> Result(Nil, String)
