//// One trusted CPython process per session. POSIX, Python 3.11+.

import albedo/daemon/image
import albedo/harness/extensions/work/ledger as work
import albedo/harness/extensions/work/rpc
import albedo/openai_api/types
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/result

pub type Kernel

pub type Error {
  Unavailable(String)
  Busy
  Lost
  Invalid(String)
}

pub type Status {
  Succeeded
  Failed
  Interrupted
}

pub type Outcome {
  Outcome(
    id: String,
    status: Status,
    output: String,
    value: String,
    truncated: Bool,
    /// Images the cell returned with show_image, read from their own headers.
    images: List(types.Image),
    /// Why an image the kernel sent could not be read; it is never sent on.
    image_errors: List(String),
  )
}

/// executable and script must be absolute paths; cwd is the session workspace.
pub fn start(
  store: work.Store,
  executable: String,
  script: String,
  cwd: String,
) -> Result(Kernel, Error) {
  start_native(
    work.owner(store),
    executable,
    script,
    cwd,
    rpc.handle(store, cwd, _),
    ["run", "work"],
  )
}

@external(erlang, "albedo_python", "start")
fn start_native(
  owner: process.Pid,
  executable: String,
  script: String,
  cwd: String,
  host: fn(String) -> String,
  modules: List(String),
) -> Result(Kernel, Error)

/// A soft interrupt preserves variables; a forced stop returns Lost.
pub fn execute(
  kernel: Kernel,
  id: String,
  code: String,
  timeout_ms: Int,
) -> Result(Outcome, Error) {
  run(kernel, id, code, timeout_ms, False)
}

pub fn execute_saved(
  kernel: Kernel,
  id: String,
  code: String,
  timeout_ms: Int,
) -> Result(Outcome, Error) {
  run(kernel, id, code, timeout_ms, True)
}

fn run(
  kernel: Kernel,
  id: String,
  code: String,
  timeout_ms: Int,
  durable: Bool,
) -> Result(Outcome, Error) {
  case timeout_ms < 1 || timeout_ms > 3_600_000 || byte_size(code) > 1_048_576 {
    True ->
      Error(Invalid("cell must be <= 1 MiB; timeout must be 1..3600000 ms"))
    False -> {
      let command =
        json.object([
          #("type", json.string("execute")),
          #("id", json.string(id)),
          #("code", json.string(code)),
          #("durable", json.bool(durable)),
        ])
        |> json.to_string
      use response <- result.try(execute_native(kernel, command, timeout_ms))
      json.parse(response, outcome_decoder())
      |> result.replace_error(Unavailable("invalid kernel response"))
    }
  }
}

@external(erlang, "erlang", "byte_size")
fn byte_size(value: String) -> Int

@external(erlang, "albedo_python", "execute")
fn execute_native(
  kernel: Kernel,
  command: String,
  timeout_ms: Int,
) -> Result(String, Error)

/// Names carried across a kernel's life: saved or restored, and those that could not be.
pub type Saved {
  Saved(names: List(String), missed: List(#(String, String)), engine: String)
}

/// Write the namespace to path. The kernel must be idle; a busy kernel answers Busy.
pub fn snapshot(
  kernel: Kernel,
  path: String,
  timeout_ms: Int,
) -> Result(Saved, Error) {
  state(kernel, "snapshot", path, timeout_ms)
}

/// Revive a namespace written earlier. A missing file is an ordinary Invalid error.
pub fn restore(
  kernel: Kernel,
  path: String,
  timeout_ms: Int,
) -> Result(Saved, Error) {
  state(kernel, "restore", path, timeout_ms)
}

fn state(
  kernel: Kernel,
  kind: String,
  path: String,
  timeout_ms: Int,
) -> Result(Saved, Error) {
  let command =
    json.object([
      #("type", json.string(kind)),
      #("id", json.string(kind)),
      #("path", json.string(path)),
    ])
    |> json.to_string
  use response <- result.try(execute_native(kernel, command, timeout_ms))
  use saved <- result.try(
    json.parse(response, decode.field("state", saved_decoder(), decode.success))
    |> result.replace_error(Unavailable("invalid kernel response")),
  )
  saved
}

fn saved_decoder() -> decode.Decoder(Result(Saved, Error)) {
  let entry = {
    use name <- decode.field("name", decode.string)
    use reason <- decode.field("reason", decode.string)
    decode.success(#(name, reason))
  }
  let names = decode.list(decode.string)
  let entries = decode.list(entry)
  use saved <- decode.optional_field("saved", [], names)
  use restored <- decode.optional_field("restored", [], names)
  use skipped <- decode.optional_field("skipped", [], entries)
  use failed <- decode.optional_field("failed", [], entries)
  use engine <- decode.optional_field("engine", "", decode.string)
  use failure <- decode.optional_field("error", "", decode.string)
  decode.success(case failure {
    "" ->
      Ok(Saved(
        list.append(saved, restored),
        list.append(skipped, failed),
        engine,
      ))
    message -> Error(Invalid(message))
  })
}

/// The kernel's own process id, for supervision and memory accounting.
@external(erlang, "albedo_python", "os_pid")
pub fn os_pid(kernel: Kernel) -> Result(Int, Nil)

/// Live background jobs the kernel still supervises, local groups plus remote
/// jobs its remote plugin reported. Zero when the kernel cannot answer.
@external(erlang, "albedo_python", "job_count")
pub fn job_count(kernel: Kernel) -> Int

@external(erlang, "albedo_python", "interrupt")
pub fn interrupt(kernel: Kernel) -> Nil

/// End the kernel and every process group it owns. An error names what survived.
@external(erlang, "albedo_python", "stop")
pub fn stop(kernel: Kernel) -> Result(Nil, String)

/// Swap the live host RPC closure: a refreshed extension snapshot rebinds the
/// routes Python reaches without restarting the kernel, so skills.read and its
/// sibling routes resolve against the new catalog immediately. A host call
/// already in flight finishes on the routes it captured.
@external(erlang, "albedo_python", "rebind")
pub fn rebind(kernel: Kernel, host: fn(String) -> String) -> Result(Nil, Error)

/// Drain up to 100 background completion notifications.
@external(erlang, "albedo_python", "events")
pub fn events(kernel: Kernel) -> List(String)

@external(erlang, "albedo_python", "alive")
pub fn alive(kernel: Kernel) -> Bool

pub fn outcome_decoder() {
  use id <- decode.field("id", decode.string)
  use status <- decode.field("status", decode.string)
  use output <- decode.field("output", decode.string)
  use value <- decode.field("value", decode.string)
  use truncated <- decode.field("truncated", decode.bool)
  use encoded <- decode.optional_field("images", [], decode.list(decode.string))
  let #(images, image_errors) = read_images(encoded)
  let outcome = Outcome(id, _, output, value, truncated, images, image_errors)
  case status {
    "ok" -> decode.success(outcome(Succeeded))
    "error" -> decode.success(outcome(Failed))
    "interrupted" -> decode.success(outcome(Interrupted))
    _ -> decode.failure(outcome(Failed), "cell status")
  }
}

/// One unreadable image costs only itself, not the cell's whole result.
/// Both lists keep the order the cell showed its images in.
fn read_images(encoded: List(String)) -> #(List(types.Image), List(String)) {
  let #(images, errors) =
    encoded
    |> list.index_map(fn(data, index) {
      image.from_base64(data)
      |> result.map_error(fn(reason) {
        "image " <> int.to_string(index + 1) <> ": " <> reason
      })
    })
    |> result.partition
  // result.partition returns both lists reversed.
  #(list.reverse(images), list.reverse(errors))
}

/// Start with python3 from PATH and albedo's packaged kernel script.
pub fn local(store: work.Store, cwd: String) -> Result(Kernel, Error) {
  use #(executable, script) <- result.try(local_paths())
  start(store, executable, script, cwd)
}

@external(erlang, "albedo_python", "local_paths")
fn local_paths() -> Result(#(String, String), Error)

pub fn local_with_host(
  store: work.Store,
  cwd: String,
  host: fn(String) -> String,
) -> Result(Kernel, Error) {
  use #(executable, script) <- result.try(local_paths())
  start_native(work.owner(store), executable, script, cwd, host, [
    "run",
    "work",
  ])
}

pub fn local_with_plugins(
  store: work.Store,
  cwd: String,
  host: fn(String) -> String,
  modules: List(String),
) -> Result(Kernel, Error) {
  use #(executable, script) <- result.try(local_paths())
  start_native(work.owner(store), executable, script, cwd, host, modules)
}
