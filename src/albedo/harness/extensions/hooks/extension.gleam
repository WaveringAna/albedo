//// Claude Code compatible command hooks from `$ALBEDO_HOME/hooks.json`,
//// built on the hook seam: each step of a turn runs the commands configured
//// for its Claude Code event (priv/python/albedo_hook_command.py) and answers
//// their merged verdict. See robot-docs/hooks.md.

import albedo/harness/extension
import albedo/harness/hook
import albedo/harness/settings
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string

pub fn extension() -> extension.Extension {
  extension.Extension(
    "hooks",
    "Claude Code compatible command hooks from $ALBEDO_HOME/hooks.json",
    [],
    [
      extension.ManagedPlugin(fn(_, session, workspace) {
        let config = settings.home() <> "/hooks.json"
        Ok(
          extension.Managed(
            ..extension.empty(),
            hook: Some(fire(config, session, workspace, _)),
          ),
        )
      }),
    ],
    extension.no_initialise,
  )
}

fn fire(
  config: String,
  session: String,
  workspace: String,
  event: hook.Event,
) -> hook.Verdict {
  let #(name, subject, fields) = case event {
    hook.Prompted(text) -> #("UserPromptSubmit", "", [#("prompt", quote(text))])
    hook.Calling(call) -> #("PreToolUse", tool(call.name), tool_fields(call))
    hook.Called(call, output, ..) -> #("PostToolUse", tool(call.name), [
      #("tool_response", raw(output)),
      ..tool_fields(call)
    ])
    hook.Stopping(reply, held) -> #("Stop", "", [
      #("stop_hook_active", json.to_string(json.bool(held > 0))),
      #("last_assistant_message", quote(reply)),
    ])
  }
  let input =
    object([
      #("session_id", quote(session)),
      #("cwd", quote(workspace)),
      #("hook_event_name", quote(name)),
      #("transcript_path", quote("")),
      #("permission_mode", quote("default")),
      ..fields
    ])
  let request =
    object([
      #("config", quote(config)),
      #("event", quote(name)),
      #("subject", quote(subject)),
      #("input", input),
    ])
  case run(config, name, request) {
    Ok(answer) ->
      json.parse(answer, verdict())
      |> result.lazy_unwrap(fn() { failed("its helper answered " <> answer) })
    Error(reason) -> failed(reason)
  }
}

/// The names Claude Code's matchers use for albedo's tools inside a cell.
fn tool(name: String) -> String {
  case name {
    "run" -> "Bash"
    "files.edit" -> "Edit"
    "files.write" -> "Write"
    _ -> name
  }
}

fn tool_fields(call: hook.Call) -> List(#(String, String)) {
  [
    #("tool_name", quote(tool(call.name))),
    #("tool_input", raw(call.arguments)),
    #("tool_use_id", quote(call.id)),
  ]
}

fn verdict() -> decode.Decoder(hook.Verdict) {
  let text = decode.optional(decode.string)
  let texts = decode.list(decode.string)
  use block <- decode.optional_field("block", None, text)
  use arguments <- decode.optional_field("arguments", None, text)
  use context <- decode.optional_field("context", [], texts)
  use notes <- decode.optional_field("notes", [], texts)
  use halt <- decode.optional_field("halt", None, text)
  decode.success(hook.Verdict(block, arguments, context, notes, halt))
}

fn failed(reason: String) -> hook.Verdict {
  hook.Verdict(..hook.proceed, notes: ["hooks failed open: " <> reason])
}

/// A JSON object from members that are already JSON text, so a tool call's
/// arguments ride along unparsed.
fn object(members: List(#(String, String))) -> String {
  "{"
  <> string.join(
    list.map(members, fn(member) { quote(member.0) <> ":" <> member.1 }),
    ",",
  )
  <> "}"
}

fn quote(text: String) -> String {
  json.to_string(json.string(text))
}

/// `text` itself if it is JSON, else a JSON string of it.
fn raw(text: String) -> String {
  case json.parse(text, decode.dynamic) {
    Ok(_) -> text
    Error(_) -> quote(text)
  }
}

/// Runs the commands `config` sets for `event`, answering the helper's
/// verdict, or `{}` without starting it when there are none.
@external(erlang, "albedo_hooks", "fire")
fn run(config: String, event: String, request: String) -> Result(String, String)
