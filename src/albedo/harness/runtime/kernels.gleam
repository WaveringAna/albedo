//// Kernel plumbing for the runtime actor: opening, resuming, and ending a
//// session's Python kernel, and the routes a kernel's host calls come in on.

import albedo/harness/extension
import albedo/harness/extensions/python/kernel as python
import albedo/harness/extensions/work/ledger as work
import albedo/harness/rpc
import albedo/harness/runtime/state as runtime_state
import gleam/dict
import gleam/io
import gleam/option.{type Option}
import gleam/result
import gleam/string

/// End the kernel, or let it go when the daemon is shutting down.
pub fn release_kernel(
  state: runtime_state.State,
  id: String,
  context: String,
) -> Nil {
  case state.detaching, dict.get(state.sessions, id) {
    True, Ok(session) -> python.detach(session.kernel)
    False, Ok(session) -> drop_kernel(context, session)
    _, Error(_) -> Nil
  }
}

/// End the kernel process only: the prepared composition, and any managed
/// resources it holds, stay ready for the next open.
pub fn drop_kernel(context: String, session: runtime_state.Session) -> Nil {
  case python.stop(session.kernel) {
    Ok(_) -> Nil
    Error(report) -> io.println_error(context <> ": " <> report)
  }
}

pub fn drop_kernel_at(
  state: runtime_state.State,
  id: String,
  context: String,
) -> Nil {
  case dict.get(state.sessions, id) {
    Ok(session) -> drop_kernel(context, session)
    Error(_) -> Nil
  }
}

pub fn close_cached_at(state: runtime_state.State, id: String) -> Nil {
  case dict.get(state.compositions, id) {
    Ok(cached) -> extension.close(cached.composition)
    Error(_) -> Nil
  }
}

pub fn checked_id(id: String) -> Result(String, python.Error) {
  case string.trim(id) == "" || string.byte_size(id) > 256 {
    True ->
      Error(python.Invalid("session id must be nonempty and <= 256 bytes"))
    False -> Ok(id)
  }
}

pub fn kernel_routes(
  owner: work.Store,
  id: String,
  composition: extension.Composition,
) -> fn(String) -> String {
  // Partial application captures its expressions, not just their results.
  // Keep only this session's routes: the callback is copied for every RPC.
  let routes = extension.routes(composition)
  rpc.handle(routes, owner, id, _)
}

/// Boot a kernel over one composition. A failed boot keeps the composition:
/// it is valid, and the next open retries only the kernel.
pub fn open_kernel(
  owner: work.Store,
  id: String,
  cached: runtime_state.Cached,
) -> Result(runtime_state.Session, python.Error) {
  python.open(
    owner,
    id,
    cached.cwd,
    kernel_routes(owner, id, cached.composition),
    extension.python_modules(cached.composition),
  )
  |> result.map(fn(opened) {
    let origin = case opened.1 {
      True -> runtime_state.Resumed
      False -> runtime_state.Fresh
    }
    session_over(owner, id, cached, opened.0, origin)
  })
}

pub fn session_over(
  owner: work.Store,
  id: String,
  cached: runtime_state.Cached,
  kernel: python.Kernel,
  origin: runtime_state.Origin,
) -> runtime_state.Session {
  runtime_state.Session(
    id,
    cached.cwd,
    kernel,
    owner,
    cached.composition,
    cached.instructions,
    cached.context,
    origin,
  )
}

/// Swap a stale kernel for one on the current bundle and modules, carrying
/// its namespace: the session over the new kernel, and what came across.
pub fn upgrade(
  owner: work.Store,
  id: String,
  cached: runtime_state.Cached,
  kernel: python.Kernel,
) -> Result(#(runtime_state.Session, python.Carried), python.UpgradeFailure) {
  python.upgrade(
    owner,
    id,
    cached.cwd,
    kernel_routes(owner, id, cached.composition),
    extension.python_modules(cached.composition),
    kernel,
  )
  |> result.map(fn(upgraded) {
    let #(kernel, carried) = upgraded
    #(
      session_over(owner, id, cached, kernel, runtime_state.Upgraded(carried)),
      carried,
    )
  })
}

/// The session's recorded kernel attached again, or None when it is gone.
pub fn resume_kernel(
  owner: work.Store,
  id: String,
  cached: runtime_state.Cached,
) -> Option(runtime_state.Session) {
  python.resume(
    owner,
    id,
    cached.cwd,
    kernel_routes(owner, id, cached.composition),
    extension.python_modules(cached.composition),
  )
  |> option.map(fn(kernel) {
    session_over(owner, id, cached, kernel, runtime_state.Resumed)
  })
}
