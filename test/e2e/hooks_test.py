"""Command hooks through the real loop and kernel: gates must stop effects
before they happen, rewrites and context must reach the provider, and the
Stop continuation must stay bounded. Every test owns the global hooks.json."""

import json
import time
import unittest

from harness import Albedo, Provider, exclusive, python, text


@exclusive
class HooksTests(unittest.TestCase):
    def setUp(self):
        self.replies = []
        self.provider = Provider(
            lambda _: self.replies.pop(0) if self.replies else text("done")
        )
        self.addCleanup(self.provider.close)
        self.app = Albedo(self.provider, protocol="responses")
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)
        with self.app.api("/settings?group=extensions") as response:
            validator = response.getheader("ETag")
            response.read()
        self.app.api(
            "/settings?group=extensions",
            {"defaults": {"hooks": True}},
            method="PATCH",
            headers={"If-Match": validator},
        ).close()
        self.sid = self.app.session()

    def configure(self, *definitions):
        hooks = {}
        for n, (event, matcher, body, timeout) in enumerate(definitions):
            script = self.app.workspace / f"hook-{n}.sh"
            script.write_text(body)
            command = {"type": "command", "command": f"sh {script}", "timeout": timeout}
            hooks.setdefault(event, []).append({"matcher": matcher, "hooks": [command]})
        (self.app.home / "hooks.json").write_text(json.dumps({"hooks": hooks}))

    def turn(self, prompt="test hooks"):
        before = len(self.provider.requests)
        self.cursor = self.app.stream_page(self.sid)
        self.app.prompt(self.sid, prompt).close()
        self.app.idle(self.sid)
        return [r["request"] for r in self.provider.requests[before:]]

    def events(self):
        return json.dumps(self.app.stream_page(self.sid, self.cursor)["events"])

    def test_tool_gates_stop_effects_and_reach_the_model(self):
        self.configure(
            ("PreToolUse", "^python$", "grep -q forbidden && exit 2; exit 0", 5),
            (
                "PostToolUse",
                "^python$",
                """echo '{"hookSpecificOutput":{"additionalContext":"POST_CONTEXT"}}'""",
                5,
            ),
        )
        self.replies[:] = [
            python("files.write('effect', 'forbidden')"),
            python("print('allowed')"),
            text("done"),
        ]
        requests = self.turn()
        self.assertFalse((self.app.workspace / "effect").exists())
        self.assertIn("blocked by a hook", json.dumps(requests[1]["input"]))
        self.assertIn("POST_CONTEXT", json.dumps(requests[2]["input"]))

    def test_prompt_context_payload_and_block(self):
        self.configure(
            ("UserPromptSubmit", "", "cat > prompt-input; echo PROMPT_CONTEXT", 5)
        )
        requests = self.turn("actual prompt")
        self.assertIn("PROMPT_CONTEXT", json.dumps(requests[0]["input"]))
        payload = json.loads((self.app.workspace / "prompt-input").read_text())
        self.assertEqual(payload["prompt"], "actual prompt")
        self.assertEqual(payload["session_id"], self.sid)
        self.assertEqual(payload["cwd"], str(self.app.workspace))
        # The transcript shows hook context as a note from the extension, not
        # as something the user wrote.
        notes = [
            item
            for item in self.app.history(self.sid)["items"]
            if "PROMPT_CONTEXT" in json.dumps(item)
        ]
        self.assertEqual([item["kind"] for item in notes], ["note"])
        self.assertIn('"origin"', json.dumps(notes))
        self.assertIn("hooks", json.dumps(notes))

        self.configure(("UserPromptSubmit", "", "echo PROMPT_DENIED >&2; exit 2", 5))
        self.assertEqual(self.turn(), [])
        self.assertIn("PROMPT_DENIED", self.events())

    def test_stop_continues_and_is_capped(self):
        self.configure(
            (
                "Stop",
                "",
                "cat >> stop-inputs; echo >> stop-inputs; "
                "[ -f once ] || { touch once; echo CONTINUE >&2; exit 2; }",
                5,
            )
        )
        requests = self.turn()
        self.assertEqual(len(requests), 2)
        self.assertIn("CONTINUE", json.dumps(requests[1]["input"]))
        firings = (self.app.workspace / "stop-inputs").read_text().splitlines()
        active = [json.loads(line)["stop_hook_active"] for line in firings if line]
        self.assertEqual(active, [False, True])
        self.configure(("Stop", "", "echo ALWAYS >&2; exit 2", 5))
        self.assertEqual(len(self.turn()), 9)

    def test_inner_calls_are_gated_and_failures_fail_open(self):
        self.configure(
            ("PreToolUse", "^Bash$", "grep -q forbidden && exit 2; exit 0", 5),
            (
                "PreToolUse",
                "^Write$",
                """echo '{"hookSpecificOutput":{"updatedInput":"""
                """{"file_path":"rewritten","content":"safe"}}}'""",
                5,
            ),
            (
                "PostToolUse",
                "^Bash$",
                """echo '{"hookSpecificOutput":{"additionalContext":"POST_BASH"}}'""",
                5,
            ),
            ("PreToolUse", "^python$", "echo CRASH >&2; exit 1", 5),
            ("PreToolUse", "^python$", "echo '{invalid'", 5),
            ("PreToolUse", "^python$", "sleep 30", 0.2),
        )
        self.replies[:] = [
            python(
                "try:\n    run('touch', 'forbidden')\n"
                "except PermissionError as e:\n    print('REFUSED', e)\n"
                "files.write('original', 'oops')\n"
                "job = run('true'); await job; print(job.tail())"
            ),
            text("done"),
        ]
        requests = self.turn()
        self.assertFalse((self.app.workspace / "forbidden").exists())
        self.assertFalse((self.app.workspace / "original").exists())
        self.assertEqual((self.app.workspace / "rewritten").read_text(), "safe")
        result = json.dumps(requests[-1]["input"])
        self.assertIn("REFUSED", result)
        self.assertIn("POST_BASH", result)
        events = self.events()
        for report in ("CRASH", "invalid hook JSON", "timed out"):
            self.assertIn(report, events)

    def test_async_plugin_calls_are_gated_and_rewritten(self):
        other = self.app.session()
        rewrite = {
            "hookSpecificOutput": {"updatedInput": {"to": other, "body": "REWRITTEN"}}
        }
        self.configure(
            ("PreToolUse", "^mail\\.submit$", f"echo '{json.dumps(rewrite)}'", 5),
            (
                "PostToolUse",
                "^mail\\.submit$",
                """echo '{"hookSpecificOutput":{"additionalContext":"POST_MAIL"}}'""",
                5,
            ),
        )
        self.replies[:] = [
            python(f"r = await mail.submit({other!r}, 'original'); print(r.status)"),
            text("done"),
        ]
        requests = self.turn()
        self.assertTrue(any("POST_MAIL" in json.dumps(r["input"]) for r in requests))
        deadline = time.monotonic() + 20
        while "REWRITTEN" not in json.dumps(self.app.history(other)):
            self.assertLess(
                time.monotonic(), deadline, "the rewritten letter never arrived"
            )
            time.sleep(0.1)
        self.assertNotIn("original", json.dumps(self.app.history(other)))


if __name__ == "__main__":
    unittest.main()
