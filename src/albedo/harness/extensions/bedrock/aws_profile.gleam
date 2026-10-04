//// AWS SigV4 credentials from the shared config/credentials files' active
//// profile: the same `credential_process` and static-key resolution the
//// aws CLI itself uses. Re-read fresh on every call, so an external
//// credential refresher (SSO wrapper, credential helper) just works; this
//// does not parse sso_session or cache anything.

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
  use config <- result.try(
    section(config_path(), config_header(profile))
    |> result.replace_error(
      "no [" <> config_header(profile) <> "] profile in " <> config_path(),
    ),
  )
  case dict.get(config, "credential_process") {
    Ok(command) -> from_process(command)
    Error(_) -> from_credentials_file(profile)
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
  case
    string.split(string.trim(command), " ")
    |> list.filter(fn(part) { part != "" })
  {
    [] -> Error("empty credential_process")
    [program, ..args] -> {
      let #(status, output) = run_command(program, args, None, Some(15_000))
      case status {
        0 -> credentials_from_process_output(output)
        _ ->
          Error(
            "credential_process exited "
            <> int.to_string(status)
            <> ": "
            <> output,
          )
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

fn from_credentials_file(profile: String) -> Result(sigv4.Credentials, String) {
  use creds <- result.try(
    section(credentials_path(), profile)
    |> result.replace_error(
      "no [" <> profile <> "] section in " <> credentials_path(),
    ),
  )
  credentials_from_section(creds, profile)
}

/// The pure half of `from_credentials_file`: an already-parsed `[profile]`
/// section, without touching disk.
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
) -> #(Int, String)

@external(erlang, "albedo_daemon", "env")
fn env(name: String) -> String
