//// Known SSH targets from session workspaces and SSH configuration.
//// Discovery reads cached configuration and never probes a host.

import albedo/daemon/conversation
import albedo/harness/location
import albedo/harness/ssh
import gleam/list
import gleam/result
import gleam/string

pub fn targets(sessions: List(conversation.Info)) -> List(String) {
  let recent =
    list.filter_map(sessions, fn(info) {
      use at <- result.try(
        location.parse(info.cwd) |> result.replace_error(Nil),
      )
      location.ssh_target(at)
    })
  list.unique(list.append(recent, ssh.config_hosts()))
  |> list.sort(string.compare)
}
