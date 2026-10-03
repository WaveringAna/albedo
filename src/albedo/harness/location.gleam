//// Where a session works: a directory on the daemon's own machine, or one on
//// another host reached over ssh. robot-docs/workspaces.md has the forms.
////
//// A local location is a plain path, stored exactly as workspaces always
//// were. A remote one is `[user@]host:/abs/path`; its path must be absolute,
//// so one remote directory never gets two keys.

import albedo/harness/ssh
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub type Location {
  Local(path: String)
  Remote(user: Option(String), host: String, path: String)
}

pub type Failure {
  Invalid(detail: String)
  Unavailable(detail: String)
}

/// A workspace as a client or the store spells it. Anything starting with `/`
/// or `~` (the daemon's home) is local and kept verbatim; existence is the
/// caller's question.
pub fn parse(text: String) -> Result(Location, String) {
  case text {
    "" -> Error("workspace is empty")
    "/" <> _ | "~" <> _ -> Ok(Local(text))
    _ -> remote(text)
  }
}

fn remote(text: String) -> Result(Location, String) {
  let #(user, rest) = case string.split_once(text, "@") {
    Ok(#(user, rest)) ->
      case string.contains(user, "/") || string.contains(user, ":") {
        True -> #(None, text)
        False -> #(Some(user), rest)
      }
    Error(_) -> #(None, text)
  }
  use #(host, path) <- result.try(case rest {
    "[" <> bracketed ->
      case string.split_once(bracketed, "]:") {
        Ok(split) -> Ok(split)
        Error(_) -> Error("expected [address]:/path after the host")
      }
    _ ->
      string.split_once(rest, ":")
      |> result.replace_error(
        "workspace must be an absolute path or host:/absolute/path",
      )
  })
  use _ <- result.try(case string.contains(host, "/") {
    True -> Error("workspace must be an absolute path or host:/absolute/path")
    False -> Ok(Nil)
  })
  use host <- result.try(case rest {
    "[" <> _ -> address(host)
    _ -> name("host", host)
  })
  use user <- result.try(case user {
    Some(user) -> name("user", user) |> result.map(Some)
    None -> Ok(None)
  })
  case path {
    "/" <> _ -> Ok(Remote(user, host, normalise(path)))
    "~" <> _ ->
      Error(
        "a path on "
        <> host
        <> " must be absolute: ~ there is only resolved when a session is created or moved there",
      )
    _ -> Error("a path on " <> host <> " must be absolute")
  }
}

/// A user or host name ssh takes as one: starting with a letter or digit, so
/// never an option, and without spaces.
fn name(what: String, value: String) -> Result(String, String) {
  let starts =
    string.first(value)
    |> result.map(string.contains(alphanumeric, _))
    |> result.unwrap(False)
  let spaced = list.any([" ", "\t", "\n", "\r", "@"], string.contains(value, _))
  case starts && !spaced {
    True -> Ok(value)
    False -> Error("not a valid " <> what <> " name: " <> value)
  }
}

/// A bracketed IPv6 address.
fn address(value: String) -> Result(String, String) {
  let valid =
    value != ""
    && list.all(string.to_graphemes(value), string.contains(
      "0123456789abcdefABCDEF:.",
      _,
    ))
  case valid {
    True -> Ok(value)
    False -> Error("not a valid address: [" <> value <> "]")
  }
}

const alphanumeric = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

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

/// A workspace a session can be created in or moved to: an existing absolute
/// local directory, or a remote location. A remote `~` is resolved against
/// that host's home, which connects to it (bounded); an absolute remote path
/// is taken as it is.
pub fn workspace(text: String) -> Result(Location, Failure) {
  use text <- result.try(remote_home(text))
  use location <- result.try(parse(text) |> result.map_error(Invalid))
  case location {
    Local(path) ->
      case is_directory(path) {
        True -> Ok(location)
        False ->
          Error(Invalid("workspace must be an existing absolute directory"))
      }
    Remote(..) -> Ok(location)
  }
}

/// `host:~/x` with the host's home in place of `~`; anything else as it is.
fn remote_home(text: String) -> Result(String, Failure) {
  case text, string.split_once(text, ":~") {
    "/" <> _, _ | "~" <> _, _ | _, Error(_) -> Ok(text)
    _, Ok(#(head, rest)) ->
      case string.contains(head, "/"), rest {
        True, _ -> Ok(text)
        False, "" | False, "/" <> _ -> {
          // Parse the head with a placeholder path, so a malformed host is
          // refused before anything connects to it.
          use location <- result.try(
            parse(head <> ":/") |> result.map_error(Invalid),
          )
          use target <- result.try(
            ssh_target(location)
            |> result.replace_error(Invalid("not a remote host")),
          )
          use home <- result.try(
            ssh.home(target) |> result.map_error(Unavailable),
          )
          Ok(head <> ":" <> home <> rest)
        }
        False, _ ->
          Error(Invalid("only ~ and ~/path can be resolved on a remote host"))
      }
  }
}

/// The ssh target for a remote location, `[user@]host` (an IPv6 host bare).
pub fn ssh_target(location: Location) -> Result(String, Nil) {
  case location {
    Local(_) -> Error(Nil)
    Remote(Some(user), host, _) -> Ok(user <> "@" <> host)
    Remote(None, host, _) -> Ok(host)
  }
}

/// The stored, canonical spelling.
pub fn to_string(location: Location) -> String {
  case location {
    Local(path) -> path
    Remote(user, host, path) -> {
      let host = case string.contains(host, ":") {
        True -> "[" <> host <> "]"
        False -> host
      }
      case user {
        Some(user) -> user <> "@" <> host <> ":" <> path
        None -> host <> ":" <> path
      }
    }
  }
}

/// How a client shows the host: the alias, with `user@` only when it differs
/// from the user ssh would pick for it anyway. ssh config is read with
/// `ssh -G`, which never touches the network; without ssh the user stays.
pub fn label(location: Location) -> Option(String) {
  case location {
    Local(_) -> None
    Remote(None, host, _) -> Some(host)
    Remote(Some(user), host, _) ->
      case ssh_user(host) {
        Ok(default) if default == user -> Some(host)
        _ -> Some(user <> "@" <> host)
      }
  }
}

/// The session info wire: `{host, user, path, label}`, nulls when local.
pub fn to_json(location: Location) -> Json {
  let #(user, host, path) = case location {
    Local(path) -> #(None, None, path)
    Remote(user, host, path) -> #(user, Some(host), path)
  }
  json.object([
    #("host", json.nullable(host, json.string)),
    #("user", json.nullable(user, json.string)),
    #("path", json.string(path)),
    #("label", json.nullable(label(location), json.string)),
  ])
}

@external(erlang, "albedo_location", "is_directory")
fn is_directory(path: String) -> Bool

@external(erlang, "albedo_location", "ssh_user")
fn ssh_user(host: String) -> Result(String, Nil)
