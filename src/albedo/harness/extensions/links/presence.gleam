import albedo/clock
import albedo/daemon/folders
import albedo/harness/location
import albedo/harness/ssh
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/result

/// What albedo can tell about a member's folder.
pub type Presence {
  Here
  Gone
  /// Its host did not answer, so whether the folder exists is unknown.
  Unknown(target: String, why: ssh.Failure)
}

/// A remote member is asked on its host; `wait_ms` bounds the wait for a
/// host that is not ready yet.
fn presence(member: String, wait_ms: Int) -> Presence {
  case location.parse(member) {
    Error(_) -> Here
    Ok(at) ->
      case folders.exists(at, wait_ms) {
        Ok(True) -> Here
        Ok(False) -> Gone
        Error(why) ->
          Unknown(location.ssh_target(at) |> result.unwrap(member), why)
      }
  }
}

/// Every member's presence at once, so members whose hosts are slow to answer
/// wait side by side rather than one after another. A check still running at
/// the deadline (it crashed, or the machine is starved) is ended, so no late
/// answer lands in the caller's mailbox, and reads as unreachable.
pub fn presences(members: List(String), wait_ms: Int) -> List(Presence) {
  let started =
    list.map(members, fn(member) {
      let answer = process.new_subject()
      let check =
        process.spawn_unlinked(fn() {
          process.send(answer, presence(member, wait_ms))
        })
      #(member, answer, check)
    })
  let deadline = clock.monotonic_ms() + wait_ms + folders.exists_ms + 1000
  list.map(started, fn(started) {
    let #(member, answer, check) = started
    process.receive(answer, int.max(0, deadline - clock.monotonic_ms()))
    |> result.lazy_unwrap(fn() {
      process.kill(check)
      Unknown(member, ssh.Unreachable("the check did not answer in time"))
    })
  })
}
