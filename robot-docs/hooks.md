# hooks

A hook is asked as each turn goes and may steer it. Any extension
contributes one through its managed plugin, `Managed(..extension.empty(),
hook: Some(ask))`, where `ask: fn(hook.Event) -> hook.Verdict`
([`hook.gleam`](../src/albedo/harness/hook.gleam)). The installed `hooks`
extension builds Claude Code compatible command hooks on it; an exporter of
traces, a policy, or an audit log is an extension of the same shape.

## events

| event | when | a verdict can |
| --- | --- | --- |
| `Prompted(text)` | a turn's newest input is a user message, before the first model call | block (the turn ends without a model call, the user is told why), add context |
| `Calling(call)` | a tool call is about to run | block (the call's result is the refusal), rewrite its JSON `arguments`, add context |
| `Called(call, output, started_ms, finished_ms)` | once the call has a result, a refusal included | add context; a block is context too, since the call already ran |
| `Stopping(reply, held)` | the model ended its turn without a tool call | block or add context, which continues the turn, at most 8 times |

Any verdict can carry `notes` (shown to the user, never the model) and `halt`
(the turn ends with that reason; after `Called`, once its result is
committed). Context is committed as user input ahead of the next model call.

`call` is a model tool call (`name` is the tool, `arguments` its JSON), or a
call made inside a cell: `run` (`{"command"}`), `files.edit`
(`{"file_path", "old_string", "new_string"}`) and `files.write`
(`{"file_path", "content"}`), whose `within` is the model call that ran the
cell. The inner argument names are Claude Code's, so command hooks read them
unchanged. The kernel reports inner calls through the core `hook.call` and
`hook.called` host routes (`priv/python/albedo_plugins/hook.py`, which the
kernel loads only while some extension hooks the session); a block raises
`PermissionError` in the cell, context and notes print into the cell's output,
and `run` reports `Called` when its job ends, with `{"exit_code",
"timed_out"}` as output and the hooks' lines appended to the job's output. A
kernel that cannot reach the daemon within 30 s runs the call anyway.

## combining

`runtime.hook` asks every hook of the session's composition in registry
order, each in the turn's process (inner calls: in the host call's process),
synchronously. The first block, rewrite and halt win; context and notes
concatenate. A later hook sees the arguments an earlier one rewrote. A hook
that crashes is a note and the turn goes on. A session without hooks pays one
list walk per step and nothing inside cells.

A hook that only watches answers `hook.proceed` at once, handing the event to
a process of its own. Together with `observe` (`CallSent` carries each model
call's request, usage and timing; `TurnEnded` closes the turn) that is a
whole trace: `Prompted` opens a turn span, `Called` gives each tool span its
start and end, and `within` nests inner calls under the cell's span.

```gleam
extension.ManagedPlugin(fn(_, session, _) {
  let exporter = start_exporter(session)
  Ok(extension.Managed(
    ..extension.empty(),
    observe: fn(_, event) { process.send(exporter, Observed(event)) },
    hook: Some(fn(event) {
      process.send(exporter, Hooked(event))
      hook.proceed
    }),
    close: fn() { process.send(exporter, Close) },
  ))
})
```

## command hooks

`hooks` is installed and off; enable it with `/extensions`. It reads
`$ALBEDO_HOME/hooks.json` at each event, in Claude Code's format. Only that
file is read: a checkout cannot plant hooks.

```json
{
  "hooks": {
    "PreToolUse": [{
      "matcher": "Bash|Write",
      "hooks": [{"type": "command", "command": "my-hook", "timeout": 10}]
    }]
  }
}
```

Events map to `UserPromptSubmit`, `PreToolUse`, `PostToolUse` and `Stop`.
Matchers are Python regular expressions searched in the tool name (`Bash`,
`Edit` and `Write` for the inner calls, the model tool's own name otherwise);
empty or `*` matches everything. When the file configures an event, the
daemon starts `priv/python/albedo_hook_command.py` with python3 and the
model tools' clean environment; it runs the matching commands concurrently
(eight at a time) with `sh -c` in the session workspace, each in its own
process group with the payload on stdin (`session_id`, `cwd`,
`hook_event_name`, `transcript_path` (empty), `permission_mode` (`default`),
and `prompt`, `tool_name`/`tool_input`/`tool_use_id`/`tool_response`, or
`stop_hook_active`/`last_assistant_message`). `timeout` is in seconds,
default 600; the group is killed at the timeout and when the command ends.
Commands are not sandboxed.

Exit 2 blocks with stderr as the reason. Exit 0 may print JSON:
`continue: false`/`stopReason` halts, `decision: "block"`/`reason` blocks,
`hookSpecificOutput.permissionDecision: "deny"`/`permissionDecisionReason`
blocks, `hookSpecificOutput.updatedInput` rewrites the arguments,
`hookSpecificOutput.additionalContext` adds context (10,000 characters,
labelled with the event), `systemMessage` is a note. A `UserPromptSubmit`
command's plain stdout is context. Any other exit, a timeout, invalid JSON or a
broken `hooks.json` fails open with a note.

Not yet: `SessionStart`/`SessionEnd`, compaction and subagent events, Python
callbacks registered from a cell, and per-workspace hook files.

`test/e2e/hooks_test.py` covers the command hooks through the real loop and
kernel.
