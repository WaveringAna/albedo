//// One trusted CPython process per session. POSIX, Python 3.11+.

import albedo/daemon/image
import albedo/daemon/store
import albedo/harness/extensions/python/link
import albedo/harness/extensions/work/ledger as work
import albedo/harness/extensions/work/rpc
import albedo/harness/location
import albedo/harness/settings
import albedo/harness/ssh
import albedo/openai_api/types
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub type Kernel

pub type Observation {
  Observation(
    instance_id: String,
    build: Option(String),
    linked: Bool,
    stale: Option(Stale),
    live_job_count: Int,
    job_ids: List(String),
    running_jobs: List(Job),
  )
}

@external(erlang, "albedo_python", "observation")
pub fn observation(kernel: Kernel) -> Result(Observation, Nil)

pub type Error {
  Unavailable(String)
  Busy
  Lost
  Invalid(String)
  /// The cell outlived its deadline while the kernel was out of reach. It
  /// keeps running there; its result is journaled when the kernel is back.
  Detached
}

pub type Status {
  Succeeded
  Failed
  Interrupted
  Backgrounded
}

/// The wire name of a cell result's status.
pub fn status_name(status: Status) -> String {
  case status {
    Succeeded -> "ok"
    Failed -> "error"
    Interrupted -> "interrupted"
    Backgrounded -> "backgrounded"
  }
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
    /// Wall seconds the cell ran; unknown for cells journaled before timing.
    duration: Option(Float),
  )
}

/// Everything the port owner needs to start a kernel (`fresh`) or attach
/// to the one a record names.
type Boot {
  Boot(
    owner: process.Pid,
    python: String,
    bridge: String,
    cwd: String,
    host: fn(String) -> String,
    modules: String,
    link: link.Link,
    run_dir: String,
    kernel: String,
    token: String,
    grace: Int,
    out_seq: Int,
    owned: String,
    fresh: Bool,
    remote: Option(Remote),
  )
}

/// How the port owner reaches a kernel on another host: the commands it
/// runs there over ssh.
type Remote {
  Remote(commands: ssh.Commands, host: String)
}

/// A remote workspace's host as a boot finds it: probed now, or out of reach
/// and known only by name, which still lets a recorded kernel be attached
/// once ssh is back.
type Reach {
  Probed(Remote)
  Unprobed(target: String)
}

@external(erlang, "albedo_python", "start")
fn start_native(boot: Boot) -> Result(Kernel, Error)

/// A soft interrupt preserves variables; a forced stop returns Lost.
pub fn execute(
  kernel: Kernel,
  id: String,
  code: String,
  timeout_ms: Int,
) -> Result(Outcome, Error) {
  run(kernel, id, code, timeout_ms, False, types.max_image_edge)
}

/// `images` are the session provider's limits: `show_image` refuses an image
/// over them at the call, so the cell fails where the model can see why.
pub fn execute_saved(
  kernel: Kernel,
  id: String,
  code: String,
  timeout_ms: Int,
  images: types.ImageLimits,
) -> Result(Outcome, Error) {
  run(kernel, id, code, timeout_ms, True, images.max_edge)
}

fn run(
  kernel: Kernel,
  id: String,
  code: String,
  timeout_ms: Int,
  durable: Bool,
  max_edge: Int,
) -> Result(Outcome, Error) {
  let size = string.byte_size(code)
  case timeout_ms < 1 || timeout_ms > 3_600_000 || size > 1_048_576 {
    True ->
      Error(Invalid("cell must be <= 1 MiB; timeout must be 1..3600000 ms"))
    False -> {
      let command =
        json.object([
          #("type", json.string("execute")),
          #("id", json.string(id)),
          #("code", json.string(code)),
          #("durable", json.bool(durable)),
          #("max_edge", json.int(max_edge)),
          #("timeout_ms", json.int(timeout_ms)),
        ])
        |> json.to_string
      use response <- result.try(execute_native(kernel, command, timeout_ms))
      json.parse(response, outcome_decoder())
      |> result.replace_error(Unavailable("invalid kernel response"))
    }
  }
}

@external(erlang, "albedo_python", "execute")
fn execute_native(
  kernel: Kernel,
  command: String,
  timeout_ms: Int,
) -> Result(String, Error)

/// Names carried across a kernel's life: saved or restored, and those that could not be.
pub type Saved {
  Saved(
    names: List(String),
    missed: List(#(String, String)),
    engine: String,
    defs: List(String),
    largest: List(#(String, Int)),
  )
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
  json.parse(response, decode.field("state", saved_decoder(), decode.success))
  |> result.replace_error(Unavailable("invalid kernel response"))
  |> result.flatten
}

fn saved_decoder() -> decode.Decoder(Result(Saved, Error)) {
  let entry = {
    use name <- decode.field("name", decode.string)
    use reason <- decode.field("reason", decode.string)
    decode.success(#(name, reason))
  }
  let names = decode.list(decode.string)
  let entries = decode.list(entry)
  let largest_entry = {
    use name <- decode.field("name", decode.string)
    use bytes <- decode.field("bytes", decode.int)
    decode.success(#(name, bytes))
  }
  use saved <- decode.optional_field("saved", [], names)
  use restored <- decode.optional_field("restored", [], names)
  use skipped <- decode.optional_field("skipped", [], entries)
  use failed <- decode.optional_field("failed", [], entries)
  use engine <- decode.optional_field("engine", "", decode.string)
  use defs <- decode.optional_field("defs", [], names)
  use largest <- decode.optional_field(
    "largest",
    [],
    decode.list(largest_entry),
  )
  use failure <- decode.optional_field("error", "", decode.string)
  decode.success(case failure {
    "" ->
      Ok(Saved(
        list.append(saved, restored),
        list.append(skipped, failed),
        engine,
        defs,
        largest,
      ))
    message -> Error(Invalid(message))
  })
}

/// The kernel's own process id, for supervision and memory accounting.
@external(erlang, "albedo_python", "os_pid")
pub fn os_pid(kernel: Kernel) -> Result(Int, Nil)

/// A live background job. A `service` job was started to keep running, so
/// nothing waits on its end.
pub type Job {
  Job(
    id: String,
    pid: Option(Int),
    command: String,
    service: Bool,
    started_at: Int,
  )
}

pub fn job_json(job: Job) -> json.Json {
  json.object([
    #("id", json.string(job.id)),
    #("pid", json.nullable(job.pid, json.int)),
    #("command", json.string(job.command)),
    #("started_at", json.int(job.started_at)),
  ])
}

/// Wire fields shared by the command result and the jobs resource page.
pub fn jobs_fields(
  jobs: List(Job),
  live_job_count: Option(Int),
) -> List(#(String, json.Json)) {
  [
    #("items", json.array(jobs, job_json)),
    #("live_job_count", json.nullable(live_job_count, json.int)),
  ]
}

/// Live background jobs the kernel still supervises, local groups plus remote
/// jobs its remote plugin reported. Zero when the kernel cannot answer.
@external(erlang, "albedo_python", "job_count")
pub fn job_count(kernel: Kernel) -> Int

/// Stop one background job's process group.
@external(erlang, "albedo_python", "stop_job")
pub fn stop_job(kernel: Kernel, id: String) -> Result(Nil, String)

@external(erlang, "albedo_python", "interrupt")
pub fn interrupt(kernel: Kernel) -> Nil

/// End the kernel and every process group it owns. An error names what survived.
@external(erlang, "albedo_python", "stop")
pub fn stop(kernel: Kernel) -> Result(Nil, String)

@external(erlang, "albedo_python", "stop_jobs")
pub fn stop_jobs(kernel: Kernel) -> Result(List(String), String)

@external(erlang, "albedo_python", "stop_recorded")
fn stop_recorded_native(
  record: link.Record,
  remote: Option(Remote),
) -> Result(Nil, String)

/// Supervise a saved namespace directly; never boot or prepare one to delete it.
pub fn stop_recorded(
  store: work.Store,
  session: String,
) -> Result(Nil, String) {
  use published <- result.try(link.lookup(store, session))
  use stages <- result.try(link.stages(store))
  let records =
    list.append(
      option.values([published]),
      list.filter(stages, fn(record) { record.session == session }),
    )
  list.try_each(records, stop_recorded_instance(store, _))
}

pub fn stop_recorded_instance(
  store: work.Store,
  record: link.Record,
) -> Result(Nil, String) {
  let remote = case location.parse(record.cwd) {
    Ok(location.Remote(..) as at) -> {
      use target <- result.try(
        location.ssh_target(at)
        |> result.replace_error("invalid recorded remote location"),
      )
      use #(home, _) <- result.try(
        string.split_once(record.run_dir, remote_runs <> "/")
        |> result.replace_error("invalid recorded remote run directory"),
      )
      ssh.offline(target, home)
      |> result.map(fn(commands) { Some(Remote(commands, target)) })
    }
    Ok(location.Local(_)) -> Ok(None)
    Error(_) -> Error("invalid recorded kernel location")
  }
  use remote <- result.try(remote)
  use _ <- result.try(stop_recorded_native(record, remote))
  link.forget(store, record)
}

/// Let go of the kernel without ending it, as a daemon that is shutting down
/// does: it keeps its namespace and jobs for its grace period, and the next
/// `open` for its session attaches to it again.
@external(erlang, "albedo_python", "detach")
pub fn detach(kernel: Kernel) -> Nil

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

pub fn outcome_decoder() -> decode.Decoder(Outcome) {
  use id <- decode.field("id", decode.string)
  use status <- decode.field("status", decode.string)
  use output <- decode.field("output", decode.string)
  use value <- decode.field("value", decode.string)
  use truncated <- decode.field("truncated", decode.bool)
  use encoded <- decode.optional_field("images", [], decode.list(decode.string))
  use duration <- decode.optional_field(
    "duration",
    None,
    decode.map(decode.float, Some),
  )
  let #(images, image_errors) = read_images(encoded)
  let outcome = Outcome(
    id,
    _,
    output,
    value,
    truncated,
    images,
    image_errors,
    duration,
  )
  case status {
    "ok" -> decode.success(outcome(Succeeded))
    "error" -> decode.success(outcome(Failed))
    "interrupted" -> decode.success(outcome(Interrupted))
    "backgrounded" -> decode.success(outcome(Backgrounded))
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
  local_with_plugins(store, cwd, rpc.handle(store, cwd, _), ["run", "work"])
}

/// A kernel no session will look for again.
pub fn local_with_plugins(
  store: work.Store,
  cwd: String,
  host: fn(String) -> String,
  modules: List(String),
) -> Result(Kernel, Error) {
  open(store, "local-" <> new_id(), cwd, host, modules)
  |> result.map(fn(opened) { opened.0 })
}

@external(erlang, "albedo_python", "paths")
fn paths() -> Result(#(String, String), Error)

/// Seconds a kernel outlives its last attach: ALBEDO_KERNEL_GRACE_SECONDS,
/// else an hour.
@external(erlang, "albedo_python", "grace")
fn grace() -> Int

@external(erlang, "albedo_native", "new_id")
fn new_id() -> String

/// The session's kernel: the one it recorded, attached again, when that one
/// is still alive, otherwise a fresh one. The flag says it was attached, so
/// its namespace is the one the session left.
pub fn open(
  store: work.Store,
  session: String,
  cwd: String,
  host: fn(String) -> String,
  modules: List(String),
) -> Result(#(Kernel, Bool), Error) {
  use _ <- result.try(
    reconcile_stages(store, session) |> result.map_error(Unavailable),
  )
  use #(modules, runs, boot) <- result.try(booter(store, cwd, host, modules))
  case reattach(store, session, cwd, modules, boot) {
    Some(kernel) -> Ok(#(kernel, True))
    None ->
      boot_fresh(store, session, cwd, modules, runs, boot, False)
      |> result.map(fn(value) { #(value.0, False) })
  }
}

/// Prepare a replacement beside the currently published namespace.
pub fn stage(
  store: work.Store,
  session: String,
  cwd: String,
  host: fn(String) -> String,
  modules: List(String),
) -> Result(#(Kernel, link.Record), Error) {
  use _ <- result.try(
    reconcile_stages(store, session) |> result.map_error(Unavailable),
  )
  use #(modules, runs, boot) <- result.try(booter(store, cwd, host, modules))
  boot_fresh(store, session, cwd, modules, runs, boot, True)
}

fn boot_fresh(
  store: work.Store,
  session: String,
  cwd: String,
  modules: String,
  runs: Result(String, Error),
  boot: fn(link.Record, Bool) -> Result(Kernel, Error),
  staged: Bool,
) -> Result(#(Kernel, link.Record), Error) {
  use runs <- result.try(runs)
  let kernel = string.slice(new_id(), 0, 16)
  let record =
    link.Record(
      session: session,
      kernel: kernel,
      token: new_id(),
      run_dir: runs <> "/" <> kernel,
      cwd: cwd,
      modules: modules,
      out_seq: 0,
      owned: "{}",
    )
  use _ <- result.try(
    case staged {
      False -> link.create(store, record)
      True -> link.stage(store, record)
    }
    |> result.map_error(Unavailable),
  )
  case boot(record, True) {
    Ok(kernel) -> Ok(#(kernel, record))
    Error(error) -> {
      let cleanup = {
        use records <- result.try(link.stages(store))
        case list.find(records, fn(item) { item.kernel == record.kernel }) {
          Ok(saved) -> stop_recorded_instance(store, saved)
          Error(_) -> Ok(Nil)
        }
      }
      case cleanup {
        Ok(_) -> Error(error)
        Error(reason) ->
          Error(Unavailable(
            describe(error) <> "; staged cleanup failed: " <> reason,
          ))
      }
    }
  }
}

/// The session's recorded kernel attached again, never a fresh one.
pub fn resume(
  store: work.Store,
  session: String,
  cwd: String,
  host: fn(String) -> String,
  modules: List(String),
) -> Option(Kernel) {
  case booter(store, cwd, host, modules) {
    Ok(#(modules, _, boot)) -> reattach(store, session, cwd, modules, boot)
    Error(_) -> None
  }
}

/// Every session with a recorded kernel, and the workspace it booted in.
/// Sessions of kernels nobody looks for again are left to their grace.
pub fn recorded(store: work.Store) -> List(#(String, String)) {
  link.all(store)
  |> list.filter(fn(record) { !string.starts_with(record.session, "local-") })
  |> list.map(fn(record) { #(record.session, record.cwd) })
}

/// How to start or attach to a kernel for this workspace and module set,
/// with the modules as the record stores them and the directory new run
/// directories go under (an error when a fresh kernel can't boot there now).
fn booter(
  store: work.Store,
  cwd: String,
  host: fn(String) -> String,
  modules: List(String),
) -> Result(
  #(
    String,
    Result(String, Error),
    fn(link.Record, Bool) -> Result(Kernel, Error),
  ),
  Error,
) {
  use #(python, bridge) <- result.try(paths())
  use #(path, runs, reach) <- result.try(place(cwd))
  let modules = json.to_string(json.array(modules, json.string))
  Ok(
    #(modules, runs, fn(record: link.Record, fresh) {
      use remote <- result.try(reached(reach, record))
      start_native(Boot(
        owner: work.owner(store),
        python: python,
        bridge: bridge,
        cwd: path,
        host: host,
        modules: modules,
        link: link.bind(store, record),
        run_dir: record.run_dir,
        kernel: record.kernel,
        token: record.token,
        grace: grace(),
        out_seq: record.out_seq,
        owned: record.owned,
        fresh: fresh,
        remote: remote,
      ))
    }),
  )
}

/// The recorded kernel, when it still answers and still fits this session.
fn reattach(
  store: work.Store,
  session: String,
  cwd: String,
  modules: String,
  boot: fn(link.Record, Bool) -> Result(Kernel, Error),
) -> Option(Kernel) {
  use record <- option.then(link.find(store, session))
  case boot(record, False) {
    Error(_) -> {
      // Gone. The port owner forgets what it found gone; this also covers a
      // bridge that never started.
      let _ = link.forget(store, record)
      None
    }
    Ok(kernel) if record.cwd == cwd && record.modules == modules -> Some(kernel)
    // Another module set: kept, like an older bundle, and swapped at the
    // session's next idle moment so its variables come along.
    Ok(kernel) if record.cwd == cwd -> {
      mark_stale(kernel, Modules)
      Some(kernel)
    }
    // Another workspace is a move, which never keeps the namespace.
    Ok(kernel) -> {
      io.println_error(
        "kernel "
        <> record.kernel
        <> " belongs to another workspace; replacing it",
      )
      let _ = stop(kernel)
      None
    }
  }
}

/// Where a workspace's kernel runs: the directory it starts in, the root
/// its run directories go under, and the host when that is not this
/// machine. A remote host is probed (or its recent probe reused) first, so
/// the bundle is staged there before the bridge needs it. A host out of
/// reach still lets a recorded kernel be attached; only a fresh boot needs
/// it now, and one that can never run a kernel refuses outright.
fn place(
  cwd: String,
) -> Result(#(String, Result(String, Error), Option(Reach)), Error) {
  case location.parse(cwd) {
    Ok(location.Remote(path:, ..) as at) -> {
      use target <- result.try(
        location.ssh_target(at)
        |> result.replace_error(Invalid("not a remote location")),
      )
      case ssh.ready(target, ssh.boot_wait_ms) {
        Ok(host) -> {
          let remote = Remote(host.commands, target)
          Ok(#(path, Ok(host.home <> remote_runs), Some(Probed(remote))))
        }
        Error(ssh.Unsupported(_) as failure) ->
          Error(Unavailable(ssh.describe(target, failure)))
        Error(failure) -> {
          let fresh = Error(Unavailable(ssh.describe(target, failure)))
          Ok(#(path, fresh, Some(Unprobed(target))))
        }
      }
    }
    _ -> Ok(#(cwd, Ok(settings.home() <> "/run"), None))
  }
}

/// Run directories under a remote home.
const remote_runs = "/.albedo-remote/run"

/// The remote a boot uses. A host out of reach is rebuilt from the record:
/// its run directory names the home, so the commands need no probe, and
/// the port owner keeps trying until ssh is back.
fn reached(
  reach: Option(Reach),
  record: link.Record,
) -> Result(Option(Remote), Error) {
  case reach {
    None -> Ok(None)
    Some(Probed(remote)) -> Ok(Some(remote))
    Some(Unprobed(target)) -> {
      use #(home, _) <- result.try(
        string.split_once(record.run_dir, remote_runs <> "/")
        |> result.replace_error(Unavailable("can't reach " <> target)),
      )
      ssh.offline(target, home)
      |> result.map(fn(commands) { Some(Remote(commands, target)) })
      |> result.map_error(Unavailable)
    }
  }
}

/// Whether the session has a kernel on record, which a turn may wait to
/// attach to again even while its host is out of reach.
pub fn recorded_for(store: work.Store, session: String) -> Bool {
  option.is_some(link.find(store, session))
}

/// Why a kernel should give way to a current one.
pub type Stale {
  /// It runs another python bundle than the daemon's.
  Bundle
  /// It booted with another module set than its session has now.
  Modules
  /// It speaks another session protocol; only its frozen frames still work.
  Protocol
}

/// Why this kernel should be swapped; None while it is current.
@external(erlang, "albedo_python", "stale")
pub fn stale(kernel: Kernel) -> Option(Stale)

@external(erlang, "albedo_python", "mark_stale")
pub fn mark_stale(kernel: Kernel, reason: Stale) -> Nil

/// What a swap carried: the names restored and those that were not, with why.
pub type Carried {
  Carried(reason: Stale, saved: Saved, stopped_jobs: List(String))
}

/// Replace a stale kernel with a fresh one on the current bundle and module
/// set, carrying its namespace: a snapshot in its own run directory, a fresh
/// kernel, a restore, then the old kernel and whatever jobs it still had end.
/// A busy kernel (a cell still running) answers Busy and stays; so does one
/// whose namespace could not be written, unless it speaks another protocol,
/// which is replaced with nothing carried.
pub type UpgradeFailure {
  UpgradeFailure(reason: Error, stopped_jobs: List(String))
}

pub fn upgrade(
  store: work.Store,
  session: String,
  cwd: String,
  host: fn(String) -> String,
  modules: List(String),
  old: Kernel,
) -> Result(#(Kernel, Carried), UpgradeFailure) {
  let prepared = {
    use reason <- result.try(
      stale(old) |> option.to_result(Invalid("the kernel is current")),
    )
    use record <- result.try(
      link.lookup(store, session) |> result.map_error(Unavailable),
    )
    use record <- result.try(
      record
      |> option.to_result(Unavailable("the session has no recorded kernel")),
    )
    let path = record.run_dir <> "/namespace.state"
    use saved <- result.try(case snapshot(old, path, state_timeout), reason {
      Ok(saved), _ -> Ok(Some(saved))
      Error(_), Protocol -> Ok(None)
      Error(error), _ -> Error(error)
    })
    use staged <- result.try(stage(store, session, cwd, host, modules))
    Ok(#(reason, path, saved, staged))
  }
  use #(reason, path, saved, #(kernel, staged)) <- result.try(
    prepared |> result.map_error(fn(error) { UpgradeFailure(error, []) }),
  )
  let validated = {
    use observed <- result.try(
      observation(kernel)
      |> result.replace_error(Unavailable(
        "staged kernel observation unavailable",
      )),
    )
    use _ <- result.try(case observed.linked && observed.stale == None {
      True -> Ok(Nil)
      False ->
        Error(Unavailable("replacement kernel is not current and attached"))
    })
    use restored <- result.try(case saved {
      None ->
        Ok(
          Saved(
            [],
            [#("namespace", "the old kernel could not save it")],
            "",
            [],
            [],
          ),
        )
      Some(snapshot) ->
        restore(kernel, path, state_timeout)
        |> result.map(fn(restored) {
          Saved(
            ..restored,
            missed: list.append(snapshot.missed, restored.missed),
            largest: snapshot.largest,
          )
        })
    })
    use _ <- result.try(
      link.ready(store, staged) |> result.map_error(Unavailable),
    )
    Ok(restored)
  }
  let completed = {
    use restored <- result.try(
      validated |> result.map_error(fn(error) { UpgradeFailure(error, []) }),
    )
    use stopped <- result.try(
      stop_jobs(old)
      |> result.map_error(fn(reason) { UpgradeFailure(Unavailable(reason), []) }),
    )
    use _ <- result.try(
      link.publish(store, staged)
      |> result.map_error(fn(reason) {
        UpgradeFailure(Unavailable(reason), stopped)
      }),
    )
    Ok(#(kernel, Carried(reason, restored, stopped)))
  }
  case completed {
    Ok(value) -> Ok(value)
    Error(failure) ->
      case stop(kernel) {
        Ok(_) -> Error(failure)
        Error(cleanup) ->
          Error(UpgradeFailure(
            Unavailable(
              describe(failure.reason)
              <> "; replacement cleanup failed: "
              <> cleanup,
            ),
            failure.stopped_jobs,
          ))
      }
  }
}

/// A failed replacement may have left a staged process whose shutdown was
/// not confirmed. Reap it before another boot can replace its durable identity.
fn reconcile_stages(
  storage: work.Store,
  session: String,
) -> Result(Nil, String) {
  use tables <- result.try(store.read(
    storage,
    "SELECT name FROM sqlite_master WHERE type='table' AND name='kernel_stages'",
    [],
    decode.field(0, decode.string, decode.success),
  ))
  use stages <- result.try(case tables {
    [] -> Ok([])
    _ -> link.stages(storage)
  })
  stages
  |> list.filter(fn(record) { record.session == session })
  |> list.try_each(stop_recorded_instance(storage, _))
}

/// Reap unpublished candidates left by a daemon that stopped during staging.
/// A ready candidate whose old link is absent was published by link.apply.
pub fn recover_staged(storage: work.Store) -> Result(Nil, String) {
  use stages <- result.try(link.stages(storage))
  list.try_each(stages, stop_recorded_instance(storage, _))
}

const state_timeout = 30_000

fn describe(error: Error) -> String {
  case error {
    Unavailable(message) | Invalid(message) -> message
    Busy -> "the kernel was busy"
    Lost -> "the kernel was lost"
    Detached -> "the kernel was out of reach"
  }
}
