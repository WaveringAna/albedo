//// What an agent may ask of the daemon that only the session registry can do:
//// start a child, stop or close one, see whether it runs, and list models.
//// Extensions reach the registry through this seam, so the harness never
//// imports the server; the server registers the handler when it starts.

import gleam/json

pub type Op {
  /// `parent` starts a child named `name` on `model` ("" for its own) with
  /// `task` as its first letter.
  Spawn(parent: String, name: String, task: String, model: String)
  /// Interrupt a running turn; the session and its work stay.
  Stop(session: String)
  /// Stop, mark closed, and release the kernel. Transcript and files stay.
  Close(session: String)
  /// Whether a session is running a turn right now.
  Running(session: String)
  /// The models a child of `session` may run on.
  Models(session: String)
}

pub fn call(op: Op) -> Result(json.Json, String) {
  registry_call(op)
}

pub fn register(handler: fn(Op) -> Result(json.Json, String)) -> Nil {
  registry_register(handler)
}

@external(erlang, "albedo_agents", "call")
fn registry_call(op: Op) -> Result(json.Json, String)

@external(erlang, "albedo_agents", "register")
fn registry_register(handler: fn(Op) -> Result(json.Json, String)) -> Nil
