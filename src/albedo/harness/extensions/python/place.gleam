//// Where the session's kernel runs, told to the model when that is not the
//// daemon's own machine: paths, `run` jobs and the kernel's view of the
//// filesystem are that host's.

import albedo/harness/location
import albedo/harness/ssh

/// One line for a session at a remote location, nothing for a local one.
/// The host's probe is usually cached by then (the turn warmed it); one that
/// is not ready yet gives the line without the os and arch.
pub fn context(workspace: String) -> Result(String, String) {
  case location.parse(workspace) {
    Ok(location.Remote(path:, ..) as at) ->
      case location.ssh_target(at) {
        Ok(target) -> Ok(line(target, path, ssh.ready(target, 3000)))
        Error(Nil) -> Ok("")
      }
    _ -> Ok("")
  }
}

fn line(
  target: String,
  path: String,
  host: Result(ssh.Host, ssh.Failure),
) -> String {
  let machine = case host {
    Ok(host) -> target <> " (" <> host.os <> " " <> host.arch <> ")"
    Error(_) -> target
  }
  let home = case host {
    Ok(host) -> " Its home is " <> host.home <> "."
    Error(_) -> ""
  }
  "Your python kernel and run jobs execute on "
  <> machine
  <> ", not on the machine albedo runs on; paths are that machine's, and the workspace is "
  <> path
  <> " there."
  <> home
  <> " Session tools (work, mail, agents, memory, skills) still run where albedo runs."
}
