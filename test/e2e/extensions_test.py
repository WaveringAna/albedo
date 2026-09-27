"""Extension catalog, commands, live reload, and compaction through a real daemon."""
import json
import os
import time
import unittest
import urllib.error

from harness import Albedo, Provider, exclusive, python, text


SKILL = "---\nname: demo\ndescription: catalog-only fixture description\n---\nBODY_MUST_NOT_AUTOLOAD\n"


def scripted(request):
    messages = request["input"]
    prompt = next((str(item.get("content", "")) for item in reversed(messages)
                   if item.get("role") == "user"), "")
    if "<newly-evicted-history>" in prompt:
        return text("older conversation summary")
    if messages[-1].get("type") == "function_call_output":
        return text("done")
    if "model probe via python" in prompt:
        return python("selection = await commands.model()\n"
                      "assert selection['model'] == 'fixture', selection\n"
                      "try:\n"
                      "    await commands.model('unreachable-model')\n"
                      "    assert False, 'switch must refuse from the model'\n"
                      "except CommandsError as error:\n"
                      "    assert 'user action' in str(error), error\n"
                      "print('MODEL_COMMAND_OK')")
    if "activate demo via python" in prompt:
        return python("activation = await commands.demo('python argument')\n"
                      "assert 'BODY_MUST_NOT_AUTOLOAD' in activation['instructions']\n"
                      "assert activation['arguments'] == 'python argument'\n"
                      "print('SKILL_PYTHON_ACTIVATION_OK')")
    if "hot probe before reload" in prompt:
        return python("names = [c['name'] for c in await commands.catalog()]\n"
                      "assert '/late' not in names, names\n"
                      "hot_marker = 'kernel-kept-running'\nprint('BEFORE_RELOAD_OK')")
    if "hot probe after reload" in prompt:
        return python("names = [c['name'] for c in await commands.catalog()]\n"
                      "assert '/late' in names, names\n"
                      "assert hot_marker == 'kernel-kept-running', 'kernel was restarted'\n"
                      "print('AFTER_RELOAD_OK')")
    if "lcm tool probe" in prompt:
        return python("first turn", tool_name="lcm_grep")
    if "fold list probe" in prompt:
        return python("", tool_name="lcm_list")
    return text("older conversation summary")


class ExtensionTests(unittest.TestCase):
    def setUp(self):
        self.provider = Provider(scripted)
        self.addCleanup(self.provider.close)
        self.app = Albedo(self.provider, protocol="responses", providers={
            f"fixture-{self.provider.route}": {"baseUrl": self.provider.url, "apiKey": "fixture-key",
                        "model": "fixture", "protocol": "responses"}})
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)
        self.skill = self.app.workspace / ".albedo/skills/demo/SKILL.md"
        self.skill.parent.mkdir(parents=True)
        self.skill.write_text(SKILL)
        self.sid = self.app.session()
        self.route = f"/sessions/{self.sid}/extensions"

    def get(self, path):
        with self.app.api(path) as response:
            return json.load(response)

    def post(self, path, body):
        with self.app.api(path, body) as response:
            return json.load(response)

    def command(self, name, **args):
        return self.post(f"/sessions/{self.sid}/commands", {"name": name, **args})

    def turn(self, prompt, session=None, *, expected=1):
        sid = session or self.sid
        before = len(self.provider.requests)
        self.app.prompt(sid, prompt).close()
        self.app.idle(sid)
        self.assertEqual(len(self.provider.requests) - before, expected)
        return [entry["request"] for entry in self.provider.requests[before:]]

    def compacted(self):
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            context = self.get(f"/sessions/{self.sid}/context")
            if context["compaction"]["status"] == "compacted":
                return context
            time.sleep(.05)
        self.fail(f"compaction did not finish: {context}")

    def restart(self):
        self.app.restart()

    def rejected(self, path, body):
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self.post(path, body)
        self.assertEqual(caught.exception.code, 409)
        return caught.exception.read().decode()

    def output(self, request):
        return next(item["output"] for item in reversed(request["input"])
                    if item.get("type") == "function_call_output")

    def test_catalog_is_lazy_and_activation_submits_one_turn(self):
        self.assertIn("session_extensions", self.get("/health")["capabilities"])
        installed = self.get(self.route)
        names = {item["name"] for item in installed if item["enabled"]}
        self.assertTrue({"python", "run", "work", "files", "skills"} <= names)
        request, = self.turn("first turn")
        context = request["instructions"]
        self.assertIn("catalog-only fixture description", context)
        self.assertIn(str(self.skill.resolve()), context)
        self.assertNotIn("BODY_MUST_NOT_AUTOLOAD", json.dumps(request))
        self.assertNotIn("catalog-only fixture description", json.dumps(request["input"]))
        self.assertIn("returning {content, next_offset, size, truncated}", context)
        skills = next(item for item in self.get(self.route) if item["name"] == "skills")
        self.assertEqual(skills["requires"], ["python", "commands"])
        self.assertIn("skills", skills["python_modules"])
        self.assertEqual(skills["tools"], [])
        self.assertFalse({"skills_read", "skills_list"} & {tool["name"] for tool in request["tools"]})
        catalog = self.get(f"/sessions/{self.sid}/commands")
        self.assertEqual([item for item in catalog if item["name"] == "/demo"], [{
            "name": "/demo", "description": "catalog-only fixture description",
            "method": "demo", "usage": "/demo [arguments]",
            "arguments": [{"name": "arguments", "description": "arguments for the skill", "required": False}],
            "modelCallable": True, "userTurn": True, "page": False}])
        self.assertTrue({"/model", "/context", "/compact"} <= {item["name"] for item in catalog})
        before = len(self.provider.requests)
        self.assertEqual(self.command("/demo", arguments="one  two", clientId="fixture-client"),
                         {"submitted": True})
        self.app.idle(self.sid)
        self.assertEqual(len(self.provider.requests), before + 1)
        activation = json.dumps(self.provider.requests[-1]["request"]["input"])
        self.assertIn("BODY_MUST_NOT_AUTOLOAD", activation)
        self.assertIn("one  two", activation)
        self.assertIn(str(self.skill.resolve()), activation)
        self.assertEqual(self.get(f"/sessions/{self.sid}/commands"), catalog)
        self.skill.write_text(SKILL.replace("catalog-only fixture description", "changed on disk"))
        self.assertEqual(self.get(f"/sessions/{self.sid}/commands"), catalog)
        self.skill.write_text(SKILL)
        before = len(self.provider.requests)
        self.command("/demo", arguments="slash argument")
        self.app.idle(self.sid)
        self.assertEqual(len(self.provider.requests), before + 1)
        user = next(item["content"] for item in reversed(self.provider.requests[-1]["request"]["input"])
                    if item.get("role") == "user")
        activation = json.loads(user.split("\n", 1)[1])
        self.assertEqual((activation["name"], activation["arguments"], activation["source"]),
                         ("demo", "slash argument", str(self.skill.resolve())))
        self.assertIn("BODY_MUST_NOT_AUTOLOAD", activation["instructions"])

    @exclusive
    def test_python_activation_and_user_only_model_switch(self):
        requests = self.turn("activate demo via python", expected=2)
        self.assertIn("SKILL_PYTHON_ACTIVATION_OK", self.output(requests[-1]))
        session = self.app.session()
        requests = self.turn("model probe via python", session, expected=2)
        self.assertIn("MODEL_COMMAND_OK", self.output(requests[-1]))
        route = f"/sessions/{session}/commands"
        switched = self.post(route, {"name": "/model", "args": {"model": "switched-model"}})["result"]
        self.assertEqual((switched["model"], switched["provider"]), ("switched-model", self.app.profile))
        self.assertEqual(next(s for s in self.get("/sessions") if s["id"] == session)["model"],
                         "switched-model")
        self.rejected(route, {"name": "/effort"})
        selected = self.post(route, {"name": "/model", "args": {"model": "o3-mini"}})["result"]
        self.assertEqual((selected["model"], selected["effort"]), ("o3-mini", "medium"))
        effort = self.post(route, {"name": "/effort"})["result"]
        self.assertEqual((effort["effort"], effort["available"]),
                         ("medium", ["low", "medium", "high"]))
        self.rejected(route, {"name": "/effort", "args": {"level": "bogus"}})
        effort = self.post(route, {"name": "/effort", "args": {"level": "high"}})["result"]
        self.assertEqual(effort["effort"], "high")
        self.assertIn("reasoning effort set to high", effort["message"])
        self.assertEqual(next(s for s in self.get("/sessions") if s["id"] == session)["effort"], "high")
        picked = self.post(route, {"name": "/model", "args": {"model": "o3-mini", "effort": "low"}})
        self.assertEqual(picked["result"]["effort"], "low")
        self.rejected(route, {"name": "/model", "args": {"model": "o3-mini", "effort": "max"}})
        self.rejected(route, {"name": "/model", "args": {"model": "switched-model", "effort": "low"}})
        self.assertEqual(next(s for s in self.get("/sessions") if s["id"] == session)["model"], "o3-mini")

    def test_work_page_queues_agent_note_without_starting_turn(self):
        command = next(c for c in self.get(f"/sessions/{self.sid}/commands") if c["name"] == "/work")
        self.assertTrue(command["page"])
        self.assertFalse(command["modelCallable"])
        page = self.command("/work", args={})["result"]["page"]
        self.assertEqual(page["title"], "work")
        self.assertTrue({"a", "d", "x"} <= {action["key"] for action in page["actions"]})
        added = self.command("/work", args={"action": "add", "details": "write the release notes"})
        self.assertIn("the agent will be told", added["result"]["message"])
        before = len(self.provider.requests)
        time.sleep(.3)
        self.assertEqual(len(self.provider.requests), before)
        request, = self.turn("anything new on the ledger?")
        context = json.dumps(request["input"])
        self.assertIn("The user added work item", context)
        note = next(item["content"] for item in request["input"] if item.get("role") == "user"
                    and "The user added work item" in item.get("content", ""))
        self.assertEqual((note.count("<system-note>"), note.count("</system-note>")), (1, 1))
        self.assertLess(context.index("The user added work item"), context.index("anything new on the ledger?"))
        page = self.command("/work", args={})["result"]["page"]
        self.assertTrue(any(row["text"] == "write the release notes" for row in page["glance"]["rows"]))

    def test_manual_compaction_keeps_tree_and_reuses_summary(self):
        self.turn("first turn")
        self.turn("second turn")
        self.turn("third turn")
        self.turn("fourth turn")
        original = self.get(f"/sessions/{self.sid}/tree?after=0&limit=100")["items"]
        before = len(self.provider.requests)
        started = self.command("/compact")["result"]
        self.assertEqual((started["strategy"], started["started"]), ("rolling", True))
        self.compacted()
        self.assertEqual(len(self.provider.requests), before + 1)
        self.assertEqual(self.get(f"/sessions/{self.sid}/tree?after=0&limit=100")["items"], original)
        request, = self.turn("after manual compaction")
        self.assertIn("older conversation summary", json.dumps(request["input"]))
        context = self.get(f"/sessions/{self.sid}/context")
        self.assertEqual((context["state"], context["compaction"]["status"]), ("ready", "compacted"))
        with self.app.api(f"/sessions/{self.sid}/stream?after_seq=0") as stream:
            events = json.loads(next(line[6:] for line in stream if line.startswith(b"data: ")))["events"]
        compacted = next(event for event in events if event.get("type") == "compacted")
        self.assertGreater(compacted["evicted"], 0)
        self.assertIn("older conversation summary", compacted["summary"])
        history = self.get(f"/sessions/{self.sid}/context/history/0")["content"]
        self.assertIn("older conversation summary", history)

    @exclusive
    def test_reload_pins_system_prompt_until_compaction(self):
        self.turn("first turn")
        late = self.app.workspace / ".agents/skills/late/SKILL.md"
        late.parent.mkdir(parents=True)
        late.write_text("---\nname: late\ndescription: added after the session opened\n---\nLATE_BODY\n")
        self.assertNotIn("/late", {c["name"] for c in self.get(f"/sessions/{self.sid}/commands")})
        requests = self.turn("hot probe before reload", expected=2)
        self.assertIn("BEFORE_RELOAD_OK", self.output(requests[-1]))
        cached = requests[-1]
        reloaded = self.command("/reload", args={"target": "session"})
        self.assertEqual(reloaded["result"]["reloaded"], "session")
        self.assertIn("/late", {c["name"] for c in self.get(f"/sessions/{self.sid}/commands")})
        request, = self.turn("after session reload")
        self.assertEqual(request["instructions"], cached["instructions"])
        self.assertNotIn("added after the session opened", json.dumps(request["input"]))
        updates = [item["content"] for item in request["input"] if item.get("role") == "user"
                   and str(item.get("content", "")).startswith("<system-note")
                   and "capabilities changed" in item["content"]]
        self.assertEqual(len(updates), 1)
        self.assertIn("commands.catalog()", updates[0])
        self.assertNotIn("/late", updates[0])
        requests = self.turn("hot probe after reload", expected=2)
        self.assertIn("AFTER_RELOAD_OK", self.output(requests[-1]))
        newer = self.app.workspace / ".agents/skills/newer/SKILL.md"
        newer.parent.mkdir(parents=True)
        newer.write_text("---\nname: newer\ndescription: another live skill\n---\nNEWER_BODY\n")
        self.command("/reload", args={"target": "session"})
        request, = self.turn("after second reload")
        self.assertEqual(request["instructions"], cached["instructions"])
        self.assertNotIn("another live skill", json.dumps(request["input"]))
        self.assertEqual(sum("capabilities changed" in str(item.get("content", ""))
                             for item in request["input"] if item.get("role") == "user"), 2)
        self.restart()
        request, = self.turn("reload pin survives restart")
        self.assertEqual(request["instructions"], cached["instructions"])
        self.turn("one more turn before compaction")
        self.command("/compact")
        self.compacted()
        self.app.idle(self.sid)
        first = self.get(f"/sessions/{self.sid}/context/instructions/0")
        snapshot = "".join(self.get(f"/sessions/{self.sid}/context/instructions/{page}")["content"]
                           for page in range(first["pages"]))
        self.assertIn("added after the session opened", snapshot)
        self.assertIn("another live skill", snapshot)
        request, = self.turn("after compaction following reload")
        self.assertIn("added after the session opened", request["instructions"])
        request, = self.turn("pin stays released")
        self.assertIn("added after the session opened", request["instructions"])

    @exclusive
    def test_auto_compaction_releases_pin_on_first_turn_after_restart(self):
        for index in range(4):
            self.turn(f"older turn {index}: " + "history " * 8000)
        self.skill.write_text(SKILL.replace(
            "catalog-only fixture description", "reloaded skill description"))
        self.command("/reload", args={"target": "session"})
        settings_path = self.app.home / "extensions.json"
        settings = json.loads(settings_path.read_text())
        settings["rolling"] = {"contextWindowTokens": 50000}
        settings_path.write_text(json.dumps(settings))
        self.restart()
        before = len(self.provider.requests)
        self.app.prompt(self.sid, "first turn after restart").close()
        self.app.idle(self.sid)
        requests = [entry["request"] for entry in self.provider.requests[before:]]
        self.assertGreater(len(requests), 1, "expected automatic summarization")
        self.assertIn("reloaded skill description", requests[-1]["instructions"])
        self.assertNotIn("catalog-only fixture description",
                         requests[-1]["instructions"])
        self.assertIn("older conversation summary", json.dumps(requests[-1]["input"]))

    @exclusive
    def test_live_toggles_guard_dependencies_busy_turns_and_persist(self):
        self.turn("first turn")
        installed = self.get(self.route)
        self.rejected(self.route, {"name": "not-installed", "enabled": False})
        self.rejected(self.route, {"name": "python", "enabled": False})
        self.assertEqual(self.get(self.route), installed)
        disabled = self.post(self.route, {"name": "skills", "enabled": False})
        self.assertFalse(next(item["enabled"] for item in disabled if item["name"] == "skills"))
        self.rejected(f"/sessions/{self.sid}/commands", {"name": "/demo", "arguments": "must not run"})
        pid = self.app.connection["pid"]
        request, = self.turn("extension disabled")
        self.assertIn("<available_skills>", request["instructions"])
        self.assertIn("capabilities changed", json.dumps(request["input"]))
        self.assertNotIn("<available_skills>", json.dumps(request["input"]))
        self.assertNotIn("skills", {module for item in disabled if item["enabled"]
                                    for module in item["python_modules"]})
        self.assertFalse({"skills_read", "skills_list"} & {tool["name"] for tool in request["tools"]})
        self.assertEqual(json.loads((self.app.home / "daemon.json").read_text())["pid"], pid)
        # The delayed provider keeps this turn active while configuration changes are refused.
        self.provider.script = lambda request: text("done", delay=2)
        self.app.prompt(self.sid, "hold this turn").close()
        deadline = time.monotonic() + 10
        while len(self.provider.requests) < 3 and time.monotonic() < deadline:
            time.sleep(.02)
        self.assertGreaterEqual(len(self.provider.requests), 3)
        self.rejected(self.route, {"name": "skills", "enabled": True})
        self.rejected(f"/sessions/{self.sid}/commands", {"name": "/model", "args": {"model": "mid-run"}})
        self.rejected(f"/sessions/{self.sid}/commands", {"name": "/compact"})
        self.assertEqual(self.get(self.route), disabled)
        self.app.idle(self.sid)
        self.provider.script = scripted
        self.restart()
        self.assertFalse(next(item["enabled"] for item in self.get(self.route) if item["name"] == "skills"))
        self.skill.write_text(SKILL.replace("catalog-only fixture description", "refreshed catalog description"))
        self.post(self.route, {"name": "skills", "enabled": True})
        request, = self.turn("extension reloaded")
        self.assertIn("refreshed catalog description", request["instructions"])
        self.assertNotIn("BODY_MUST_NOT_AUTOLOAD", request["instructions"])

    @exclusive
    def test_compaction_strategies_preserve_lcm_folds_across_switch_and_restart(self):
        self.turn("first turn")
        self.turn("second turn")
        self.turn("third turn")
        self.turn("fourth turn")
        self.assertIn("unknown compaction strategy skills",
                      self.rejected(f"/sessions/{self.sid}/commands",
                                    {"name": "/compact", "arguments": "skills"}))
        self.assertFalse(next(item["enabled"] for item in self.get(self.route) if item["name"] == "lcm"))
        result = self.command("/compact", arguments="lcm")["result"]
        self.assertEqual((result["strategy"], result["started"]), ("lcm", True))
        self.app.idle(self.sid)
        selected = self.get(self.route)
        self.assertTrue(next(item["enabled"] for item in selected if item["name"] == "lcm"))
        self.assertFalse(next(item["enabled"] for item in selected if item["name"] == "rolling"))
        self.rejected(self.route, {"name": "lcm", "enabled": False})
        request, = self.turn("lcm preflight")
        self.assertTrue({"lcm_list", "lcm_grep", "lcm_describe", "lcm_expand"}
                        <= {tool["name"] for tool in request["tools"]})
        requests = self.turn("lcm tool probe", expected=2)
        self.assertIn("LCM summary node #", json.dumps(requests[0]["input"]))
        self.assertIn("source_count", self.output(requests[-1]))
        self.assertIn("first turn", self.output(requests[-1]))
        self.assertEqual(self.get(f"/sessions/{self.sid}/context")["compaction"]["strategy"], "lcm")
        selected = self.post(self.route, {"name": "rolling", "enabled": True})
        self.assertTrue(next(item["enabled"] for item in selected if item["name"] == "rolling"))
        self.assertFalse(next(item["enabled"] for item in selected if item["name"] == "lcm"))
        request, = self.turn("folded under rolling")
        self.assertIn("LCM summary node #", json.dumps(request["input"]))
        requests = self.turn("fold list probe", expected=2)
        self.assertGreater(json.loads(self.output(requests[-1]))["total"], 0)
        self.assertEqual(self.get(f"/sessions/{self.sid}/context")["compaction"]["strategy"], "rolling")
        self.restart()
        selected = self.get(self.route)
        self.assertTrue(next(item["enabled"] for item in selected if item["name"] == "rolling"))
        self.assertFalse(next(item["enabled"] for item in selected if item["name"] == "lcm"))
        request, = self.turn("folded after restart")
        self.assertIn("LCM summary node #", json.dumps(request["input"]))


if __name__ == "__main__":
    unittest.main()
