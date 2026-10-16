//// The Python helpers under priv/python, run as ports by `albedo_discord.erl`.
//// A helper's lines reach `on_line` raw; it closes when its opener exits.

import gleam/erlang/process.{type Pid}

/// Starts `script` with `env` added to the daemon's environment.
@external(erlang, "albedo_discord", "open")
pub fn open(
  script: String,
  env: List(#(String, String)),
  on_line: fn(String) -> Nil,
) -> Result(Pid, String)

/// One request answered by a bot process's `reply`, within `timeout` ms.
@external(erlang, "albedo_discord", "call")
pub fn call(pid: Pid, request: String, timeout: Int) -> Result(String, String)

/// One raw line to the helper's stdin.
@external(erlang, "albedo_discord", "write")
pub fn write(pid: Pid, line: String) -> Nil

@external(erlang, "albedo_discord", "close")
pub fn close(pid: Pid) -> Nil
