"""Real provider and session fixtures for execution, persistence, and recovery."""

import json
import time
import unittest
import urllib.error
import urllib.parse

from harness import Albedo, Provider, operation_id, python, text


def contents(item):
    content = item.get("content", "")
    if isinstance(content, str):
        return content
    return " ".join(part.get("text", "") for part in content if isinstance(part, dict))


def script(request):
    inputs = request.get("messages", request.get("input", []))
    user = next(
        (contents(item) for item in reversed(inputs) if item.get("role") == "user"), ""
    )
    tools = sum(
        item.get("role") == "tool" or item.get("type") == "function_call_output"
        for item in inputs
    )
    if "continue from branch" in user:
        return text("finished")
    if "no first token" in user:
        return text("never streamed", hang=True)
    if "over 100 turns" in user:
        return text("finished") if tools >= 105 else python("1")
    if "workspace probe" in user:
        code = (
            "import os\nfrom pathlib import Path\n"
            "assert 'workspace_marker' not in globals()\n"
            "workspace_marker = os.getcwd()\nPath('cwd-probe').write_text(os.getcwd())"
        )
        done = (
            inputs[-1].get("role") == "tool"
            or inputs[-1].get("type") == "function_call_output"
        )
        return text("finished") if done else python(code)
    code = (
        "import asyncio, os\nfrom pathlib import Path\n"
        "Path('example.txt').write_text('hello\\n')\n"
        "saved = Path('example.txt').read_text()\n"
        "assert 'ALBEDO_API_KEY' not in os.environ\n"
        "assert 'ALBEDO_TOKEN' not in os.environ\n"
        + (
            "Path('recovery-started').write_text('ready')\n"
            if "hang then recover" in user
            else ""
        )
        + f"await asyncio.sleep({30 if 'hang' in user else 2 if 'first task' in user else 0.4})\nlen(saved)"
    )
    return (
        text("finished")
        if tools
        else python(code, reasoning="reasoning about the task")
    )


class IntegrationScenario(unittest.TestCase):
    def setUp(self):
        self.provider = Provider(script)
        self.addCleanup(self.provider.close)

    def app_for(self, protocol, *, prepare=None, providers=None):
        app = Albedo(
            self.provider, protocol=protocol, prepare=prepare, providers=providers
        )
        app.__enter__()
        self.addCleanup(app.__exit__, None, None, None)
        return app

    def read(self, app, path):
        with app.api(path) as response:
            return json.load(response)

    def change(self, app, session, fields):
        with app.api(f"/sessions/{session}?view=configuration") as response:
            configuration = json.load(response)
            etag = response.headers["ETag"]
        if "workspace" in fields:
            fields = {**fields, "family_revision": configuration["family_revision"]}
        with app.api(
            f"/sessions/{session}?view=configuration",
            fields,
            method="PATCH",
            headers={"If-Match": etag},
        ) as response:
            return json.load(response)

    def history(self, app, session):
        page = app.history(session)
        entries = page["items"]
        while page["older"]:
            page = self.read(
                app,
                f"/sessions/{session}/history?next={urllib.parse.quote(page['older'], safe='')}",
            )
            entries = page["items"] + entries
        return entries

    def entry_text(self, entry):
        return "".join(
            part["text"] for part in entry["content"] if part["kind"] == "text"
        )

    def send(self, app, session, message):
        app.prompt(session, message).close()
        app.idle(session, timeout=90)

    def settings(self, app, protocol, active="alpha", **models):
        other = "responses" if protocol == "chat_completions" else "chat_completions"
        configured = {
            "alpha": ("alpha-2", models.get("alpha", "fixture-alpha"), protocol),
            "beta": ("beta-1", models.get("beta", "fixture-beta"), protocol),
            "gamma": ("gamma-1", models.get("gamma", "fixture-gamma"), other),
        }
        providers = {
            name: {
                "baseUrl": self.provider.url + f"/{name}/v1",
                "apiKey": key,
                "model": model,
                "protocol": binding,
            }
            for name, (key, model, binding) in configured.items()
        }
        (app.home / "config.json").write_text(
            json.dumps({"active": active, "providers": providers})
        )

    def default_session(self, app):
        identity = operation_id()
        with app.api(
            f"/sessions/{identity}",
            {"kind": "new", "workspace": str(app.workspace)},
            method="PUT",
            headers={"If-None-Match": "*"},
        ) as response:
            self.assertEqual(json.load(response)["id"], identity)
        return identity

    def records(self, start):
        return self.provider.requests[start:]

    def wait_for_request(self, start):
        deadline = time.monotonic() + 15
        while len(self.provider.requests) <= start and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertGreater(len(self.provider.requests), start)

    def assert_projected(self, record, protocol, users):
        items = record["request"][
            "messages" if protocol == "chat_completions" else "input"
        ]
        serialized = json.dumps(items)
        for user in users:
            self.assertIn(user, serialized)
        self.assertIn("finished", serialized)
        if protocol == "chat_completions":
            calls = [
                call["id"]
                for item in items
                if item.get("role") == "assistant"
                for call in item.get("tool_calls", [])
            ]
            outputs = [
                item["tool_call_id"] for item in items if item.get("role") == "tool"
            ]
        else:
            calls = [
                item["call_id"] for item in items if item.get("type") == "function_call"
            ]
            outputs = [
                item["call_id"]
                for item in items
                if item.get("type") == "function_call_output"
            ]
        self.assertTrue(any(call.startswith("fixture-call-") for call in calls))
        self.assertTrue(set(calls) & set(outputs))

    def restart(self, app):
        app.restart(crash=True)
