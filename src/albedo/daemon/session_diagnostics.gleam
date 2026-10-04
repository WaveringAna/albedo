//// Typed facts for native diagnostics inspecting a live session state.

import albedo/daemon/session_state.{type State}
import albedo/daemon/tool_progress
import albedo/daemon/turn
import gleam/erlang/process.{type Pid}
import gleam/list
import gleam/option.{type Option, None}

pub fn watcher_owners(state: State(message)) -> List(Pid) {
  list.map(state.watchers, fn(watcher) { watcher.owner })
}

pub fn sequence(state: State(message)) -> Int {
  state.sequence
}

pub fn history_unloaded(state: State(message)) -> Bool {
  state.history == None
}

pub fn progress(state: State(message)) -> tool_progress.Projection {
  state.tool_progress
}

pub fn worker(state: State(message), run_id: String) -> Option(Pid) {
  turn.owner(state.activity, run_id)
  |> option.map(fn(run) { run.pid })
}
