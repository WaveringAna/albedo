//// Remote hosts as albedo reaches them over ssh: one probe opens the
//// ControlMaster, checks python >= 3.11 and stages the bundle, and answers
//// what the host is. The daemon's kernels, the `/hosts` routes and the
//// model's own `remote.connect()` share the same control sockets.
//// robot-docs/kernel.md has the remote section.

import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/option.{type Option, None, Some}
import gleam/result

/// A host that is ready for a kernel.
pub type Host {
  Host(
    target: String,
    os: String,
    arch: String,
    home: String,
    cpus: Int,
    commands: Commands,
  )
}

/// What the daemon runs on a host, built (and quoted) by albedo_ssh.py:
/// the ssh argv up to and including the target, then one of the complete
/// remote commands. Their inputs travel on stdin.
pub type Commands {
  Commands(
    argv: List(String),
    bridge: String,
    signal: String,
    remove: String,
    gather: String,
    auth_sock: Option(String),
  )
}

pub type Failure {
  /// ssh needs a person: a passphrase, a second factor, a new host key.
  NeedsAuth(detail: String, control: String)
  Unreachable(String)
  Unsupported(String)
  /// The probe is still running.
  Warming
}

/// Seconds a caller that needs the host waits for its probe: connecting,
/// and staging the bundle the first time.
pub const boot_wait_ms = 150_000

/// The host, probed now unless a recent answer is cached.
pub fn ready(target: String, wait_ms: Int) -> Result(Host, Failure) {
  case probe(target, wait_ms) {
    Ok(answer) -> decoded(answer)
    Error(Nil) -> Error(Warming)
  }
}

/// The host as a recent probe found it, without waiting: a stale or missing
/// answer starts a probe in the background and reads as still warming.
pub fn known(target: String) -> Result(Host, Failure) {
  case peek(target) {
    Ok(answer) -> decoded(answer)
    Error(Nil) -> Error(Warming)
  }
}

/// The host's home directory, for resolving `host:~/x`.
pub fn home(target: String) -> Result(String, String) {
  ready(target, 30_000)
  |> result.map(fn(host) { host.home })
  |> result.map_error(describe(target, _))
}

/// What a refusal says about a host that is not ready.
pub fn describe(target: String, failure: Failure) -> String {
  case failure {
    NeedsAuth(detail, _) -> target <> " needs you to sign in: " <> detail
    Unreachable(detail) -> "can't reach " <> target <> ": " <> detail
    Unsupported(detail) -> target <> " can't run albedo's kernel: " <> detail
    Warming -> "still connecting to " <> target
  }
}

pub type Observation {
  Observation(
    target: String,
    state: String,
    detail: Option(String),
    host: Option(Host),
    control: Option(String),
    step: Option(String),
  )
}

/// Read cached facts without starting a probe, or explicitly start/join one.
pub fn observe(target: String, start: Bool) -> Observation {
  let #(answer, probing) = case observe_cached(target, start) {
    Ok(answer) -> #(decoded(answer), False)
    Error(probing) -> #(Error(Warming), probing)
  }
  case answer {
    Ok(host) -> Observation(target, "ready", None, Some(host), None, None)
    Error(NeedsAuth(detail, control)) ->
      Observation(target, "needs_auth", Some(detail), None, Some(control), None)
    Error(Unreachable(detail)) ->
      Observation(target, "unreachable", Some(detail), None, None, None)
    Error(Unsupported(detail)) ->
      Observation(target, "unsupported", Some(detail), None, None, None)
    Error(Warming) ->
      Observation(
        target,
        case probing {
          True -> "probing"
          False -> "unknown"
        },
        None,
        None,
        None,
        case probing {
          True ->
            case step(target) {
              "staging" -> Some("staging")
              _ -> None
            }
          False -> None
        },
      )
  }
}

/// The `Host` names of ~/.ssh/config and its includes, patterns left out.
pub fn config_hosts() -> List(String) {
  config_hosts_json()
  |> result.try(fn(answer) {
    json.parse(answer, decode.list(decode.string)) |> result.replace_error(Nil)
  })
  |> result.unwrap([])
}

fn decoded(answer: String) -> Result(Host, Failure) {
  let decoder = {
    use state <- decode.field("state", decode.string)
    use detail <- decode.optional_field("detail", "", decode.string)
    case state {
      "ready" -> {
        use target <- decode.field("host", decode.string)
        use os <- decode.field("os", decode.string)
        use arch <- decode.field("arch", decode.string)
        use home <- decode.field("home", decode.string)
        use cpus <- decode.field("cpus", decode.int)
        use commands <- decode.then(commands_decoder())
        decode.success(Ok(Host(target, os, arch, home, cpus, commands)))
      }
      "needs_auth" -> {
        use control <- decode.optional_field("control", "", decode.string)
        decode.success(Error(NeedsAuth(detail, control)))
      }
      "unsupported" -> decode.success(Error(Unsupported(detail)))
      _ -> decode.success(Error(Unreachable(detail)))
    }
  }
  json.parse(answer, decoder)
  |> result.unwrap(Error(Unreachable("the host probe answered badly")))
}

/// The commands for a host whose home is already known, without reaching
/// it: a kernel recorded there can be attached again once ssh is back.
pub fn offline(target: String, home: String) -> Result(Commands, String) {
  use answer <- result.try(
    local_commands(target, home)
    |> result.replace_error("albedo_ssh.py could not build the commands"),
  )
  json.parse(answer, commands_decoder())
  |> result.replace_error("albedo_ssh.py answered badly")
}

fn commands_decoder() -> decode.Decoder(Commands) {
  use argv <- decode.field("argv", decode.list(decode.string))
  use bridge <- decode.field("bridge", decode.string)
  use signal <- decode.field("signal", decode.string)
  use remove <- decode.field("remove", decode.string)
  use gather <- decode.field("gather", decode.string)
  use auth_sock <- decode.optional_field(
    "auth_sock",
    None,
    decode.optional(decode.string),
  )
  decode.success(Commands(argv, bridge, signal, remove, gather, auth_sock))
}

/// One gather on the host (priv/python/albedo_gather.py): its snapshot for
/// a request, within the deadline.
pub fn gather(
  host: Host,
  request: Json,
  timeout_ms: Int,
) -> Result(String, String) {
  let commands = host.commands
  exec(
    commands.argv,
    commands.gather,
    commands.auth_sock,
    json.to_string(request) <> "\n",
    timeout_ms,
  )
  |> result.map_error(fn(why) {
    "gathering on " <> host.target <> " failed: " <> why
  })
}

@external(erlang, "albedo_ssh", "exec")
fn exec(
  argv: List(String),
  command: String,
  auth_sock: Option(String),
  input: String,
  timeout_ms: Int,
) -> Result(String, String)

@external(erlang, "albedo_ssh", "commands")
fn local_commands(target: String, home: String) -> Result(String, Nil)

@external(erlang, "albedo_ssh", "probe")
fn probe(target: String, wait_ms: Int) -> Result(String, Nil)

@external(erlang, "albedo_ssh", "observe")
fn observe_cached(target: String, refresh: Bool) -> Result(String, Bool)

@external(erlang, "albedo_ssh", "config_hosts")
fn config_hosts_json() -> Result(String, Nil)

/// What a running probe is doing past connecting: `staging` while it copies
/// albedo's bundle to the host, "" otherwise.
@external(erlang, "albedo_ssh", "step")
pub fn step(target: String) -> String

@external(erlang, "albedo_ssh", "peek")
fn peek(target: String) -> Result(String, Nil)
