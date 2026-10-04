//// AWS credential_process and static keys in the active shared profile.
//// Re-read each call; SSO, role chaining and instance metadata are not resolved.

import albedo/harness/extensions/bedrock/sigv4
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string

pub fn resolve() -> Result(sigv4.Credentials, String) {
  let profile = active_profile()
  let config =
    section(config_path(), config_header(profile)) |> result.unwrap(dict.new())
  let shared = section(credentials_path(), profile) |> result.unwrap(dict.new())
  // A complete static credential source wins over credential_process. Never
  // mix keys or session tokens from two files.
  case dict.has_key(shared, "aws_access_key_id") {
    True -> credentials_from_section(shared, profile)
    False ->
      case dict.has_key(config, "aws_access_key_id") {
        True -> credentials_from_section(config, profile)
        False ->
          case dict.get(config, "credential_process") {
            Ok(command) -> from_process(command)
            Error(_) -> credentials_from_section(config, profile)
          }
      }
  }
}

/// `AWS_REGION`, else `AWS_DEFAULT_REGION`, else the active `AWS_PROFILE`'s
/// own `region` key in `~/.aws/config` (every other field there, including
/// `credential_process`, is read the same way). `""` when none name one.
pub fn region() -> String {
  case env("AWS_REGION") {
    "" ->
      case env("AWS_DEFAULT_REGION") {
        "" -> profile_region()
        region -> region
      }
    region -> region
  }
}

fn profile_region() -> String {
  let profile = active_profile()
  case section(config_path(), config_header(profile)) {
    Ok(config) -> dict.get(config, "region") |> result.unwrap("")
    Error(Nil) -> ""
  }
}

fn active_profile() -> String {
  case env("AWS_PROFILE") {
    "" -> "default"
    name -> name
  }
}

fn from_process(command: String) -> Result(sigv4.Credentials, String) {
  use argv <- result.try(command_argv(command))
  case argv {
    [] -> Error("empty credential_process")
    [program, ..args] -> {
      // A trusted user-configured AWS helper inherits the daemon environment.
      // The usage feed keeps its separate allowlist; supervision stays shared.
      let #(status, output) = run_command(program, args, None, Some(15_000), [])
      case status {
        0 -> credentials_from_process_output(output)
        _ -> Error("credential_process exited " <> int.to_string(status))
      }
    }
  }
}

/// Quote-aware argv only: no shell, interpolation, expansion or evaluation.
pub fn command_argv(command: String) -> Result(List(String), String) {
  argv_loop(string.to_graphemes(command), None, False, False, [], [])
}

fn argv_loop(
  chars: List(String),
  quote: option.Option(String),
  escaped: Bool,
  started: Bool,
  word: List(String),
  args: List(String),
) -> Result(List(String), String) {
  case chars {
    [] ->
      case quote, escaped {
        None, False ->
          Ok(
            list.reverse(case started {
              True -> [string.join(list.reverse(word), ""), ..args]
              False -> args
            }),
          )
        _, _ -> Error("credential_process has an unfinished quote or escape")
      }
    [char, ..rest] ->
      case escaped {
        True -> {
          let word = case quote, char {
            Some("\""), "\n" -> word
            Some("\""), "\\"
            | Some("\""), "\""
            | Some("\""), "$"
            | Some("\""), "`"
            -> [char, ..word]
            Some("\""), _ -> [char, "\\", ..word]
            _, _ -> [char, ..word]
          }
          argv_loop(rest, quote, False, True, word, args)
        }
        False ->
          case char, quote {
            "\\", Some("'") ->
              argv_loop(rest, quote, False, True, [char, ..word], args)
            "\\", _ -> argv_loop(rest, quote, True, True, word, args)
            "'", None -> argv_loop(rest, Some("'"), False, True, word, args)
            "\"", None -> argv_loop(rest, Some("\""), False, True, word, args)
            _, Some(q) if char == q ->
              argv_loop(rest, None, False, True, word, args)
            " ", None | "\t", None | "\n", None | "\r", None ->
              case started {
                True ->
                  argv_loop(rest, None, False, False, [], [
                    string.join(list.reverse(word), ""),
                    ..args
                  ])
                False -> argv_loop(rest, None, False, False, [], args)
              }
            _, _ -> argv_loop(rest, quote, False, True, [char, ..word], args)
          }
      }
  }
}

/// The pure half of `from_process`: a `credential_process`-documented JSON
/// reply, without running anything.
pub fn credentials_from_process_output(
  output: String,
) -> Result(sigv4.Credentials, String) {
  json.parse(output, process_decoder())
  |> result.replace_error(
    "credential_process did not print the documented JSON",
  )
}

fn process_decoder() -> decode.Decoder(sigv4.Credentials) {
  use access <- decode.field("AccessKeyId", decode.string)
  use secret <- decode.field("SecretAccessKey", decode.string)
  use token <- decode.optional_field(
    "SessionToken",
    None,
    decode.optional(decode.string),
  )
  decode.success(sigv4.Credentials(access, secret, token))
}

/// Static credentials from one parsed profile section, without touching disk.
pub fn credentials_from_section(
  creds: Dict(String, String),
  profile: String,
) -> Result(sigv4.Credentials, String) {
  use access <- result.try(
    dict.get(creds, "aws_access_key_id")
    |> result.replace_error(
      "profile " <> profile <> " has no aws_access_key_id",
    ),
  )
  use secret <- result.try(
    dict.get(creds, "aws_secret_access_key")
    |> result.replace_error(
      "profile " <> profile <> " has no aws_secret_access_key",
    ),
  )
  let token = dict.get(creds, "aws_session_token") |> option.from_result
  Ok(sigv4.Credentials(access, secret, token))
}

pub fn config_header(profile: String) -> String {
  case profile {
    "default" -> "default"
    _ -> "profile " <> profile
  }
}

fn config_path() -> String {
  case env("AWS_CONFIG_FILE") {
    "" -> env("HOME") <> "/.aws/config"
    path -> path
  }
}

fn credentials_path() -> String {
  case env("AWS_SHARED_CREDENTIALS_FILE") {
    "" -> env("HOME") <> "/.aws/credentials"
    path -> path
  }
}

/// `[header]`'s `key = value` lines, up to the next `[...]` line or EOF.
fn section(path: String, header: String) -> Result(Dict(String, String), Nil) {
  use text <- result.try(read_file(path))
  parse_section(text, header)
}

/// The pure half of `section`: INI text already in hand, no disk access.
pub fn parse_section(
  text: String,
  header: String,
) -> Result(Dict(String, String), Nil) {
  text
  |> string.split("\n")
  |> list.map(string.trim)
  |> find_section(header)
  |> option.to_result(Nil)
}

fn find_section(
  lines: List(String),
  header: String,
) -> option.Option(Dict(String, String)) {
  case lines {
    [] -> None
    [line, ..rest] ->
      case is_header(line, header) {
        True -> Some(collect(rest, dict.new()))
        False -> find_section(rest, header)
      }
  }
}

fn is_header(line: String, header: String) -> Bool {
  string.starts_with(line, "[")
  && string.ends_with(line, "]")
  && string.trim(string.slice(line, 1, string.length(line) - 2)) == header
}

fn collect(
  lines: List(String),
  acc: Dict(String, String),
) -> Dict(String, String) {
  case lines {
    [] -> acc
    [line, ..rest] ->
      case string.starts_with(line, "[") {
        True -> acc
        False ->
          case string.split(line, "=") {
            [] | [_] -> collect(rest, acc)
            [key, ..value] ->
              collect(
                rest,
                dict.insert(
                  acc,
                  string.trim(key),
                  string.trim(string.join(value, "=")),
                ),
              )
          }
      }
  }
}

fn read_file(path: String) -> Result(String, Nil) {
  use bytes <- result.try(read_file_raw(path) |> result.replace_error(Nil))
  bit_array.to_string(bytes) |> result.replace_error(Nil)
}

@external(erlang, "file", "read_file")
fn read_file_raw(path: String) -> Result(BitArray, Dynamic)

@external(erlang, "albedo_usage_core", "run_command")
fn run_command(
  command: String,
  args: List(String),
  stdin: option.Option(String),
  timeout_ms: option.Option(Int),
  environment: List(#(String, String)),
) -> #(Int, String)

@external(erlang, "albedo_daemon", "env")
fn env(name: String) -> String
