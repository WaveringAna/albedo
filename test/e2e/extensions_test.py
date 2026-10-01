"""Extension catalog, commands, live reload, and compaction through a real daemon."""

import json
import os
import threading
import time
import unittest
import urllib.error

from harness import Albedo, Provider, exclusive, python, text


SKILL = "---\nname: demo\ndescription: catalog-only fixture description\n---\nBODY_MUST_NOT_AUTOLOAD\n"


def scripted(request):
    messages = request["input"]
    prompt = next(
        (
            str(item.get("content", ""))
            for item in reversed(messages)
            if item.get("role") == "user"
        ),
        "",
    )
    if "<newly-evicted-history>" in prompt:
        return text("older conversation summary")
    if messages[-1].get("type") == "function_call_output":
        return text("done")
    if "model probe via python" in prompt:
        return python(
            "selection = await commands.model()\n"
            "assert selection['model'] == 'fixture', selection\n"
            "try:\n"
            "    await commands.model('unreachable-model')\n"
            "    assert False, 'switch must refuse from the model'\n"
            "except CommandsError as error:\n"
            "    assert 'user action' in str(error), error\n"
            "print('MODEL_COMMAND_OK')"
        )
    if "activate demo via python" in prompt:
        return python(
            "activation = await commands.demo('python argument')\n"
            "assert 'BODY_MUST_NOT_AUTOLOAD' in activation['instructions']\n"
            "assert activation['arguments'] == 'python argument'\n"
            "print('SKILL_PYTHON_ACTIVATION_OK')"
        )
    if "hot probe before reload" in prompt:
        return python(
            "names = [c['name'] for c in await commands.catalog()]\n"
            "assert '/late' not in names, names\n"
            "hot_marker = 'kernel-kept-running'\nprint('BEFORE_RELOAD_OK')"
        )
    if "hot probe after reload" in prompt:
        return python(
            "names = [c['name'] for c in await commands.catalog()]\n"
            "assert '/late' in names, names\n"
            "assert hot_marker == 'kernel-kept-running', 'kernel was restarted'\n"
            "print('AFTER_RELOAD_OK')"
        )
    if "lcm tool probe" in prompt:
        return python("first turn", tool_name="lcm_grep")
    if "fold list probe" in prompt:
        return python("", tool_name="lcm_list")
    return text("older conversation summary")


class ExtensionTests(unittest.TestCase):
    def setUp(self):
        self.provider = Provider(scripted)
        self.addCleanup(self.provider.close)
        self.app = Albedo(
            self.provider,
            protocol="responses",
            providers={
                f"fixture-{self.provider.route}": {
                    "baseUrl": self.provider.url,
                    "apiKey": "fixture-key",
                    "model": "fixture",
                    "protocol": "responses",
                }
            },
        )
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
            time.sleep(0.05)
        self.fail(f"compaction did not finish: {context}")

    def restart(self):
        self.app.restart()

    def rejected(self, path, body):
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self.post(path, body)
        self.assertEqual(caught.exception.code, 409)
        return caught.exception.read().decode()

    def output(self, request):
        return next(
            item["output"]
            for item in reversed(request["input"])
            if item.get("type") == "function_call_output"
        )

    def test_workspace_system_files_replace_base_and_append_before_project_instructions(
        self,
    ):
        (self.app.workspace / "SYSTEM.md").write_text("CUSTOM_BASE_ONLY")
        (self.app.workspace / "APPEND_SYSTEM.md").write_text("CUSTOM_APPEND_ONLY")
        (self.app.workspace / "AGENTS.md").write_text("PROJECT_CONVENTION_ONLY")
        (request,) = self.turn("inspect system files")
        prompt = request["instructions"]
        self.assertTrue(prompt.startswith("CUSTOM_BASE_ONLY\n"))
        self.assertNotIn("You are a coding agent operating inside albedo", prompt)
        self.assertLess(
            prompt.index("Local workspace context supplied by an enabled extension"),
            prompt.index("CUSTOM_APPEND_ONLY"),
        )
        self.assertLess(
            prompt.index('name="commands"'), prompt.index("CUSTOM_APPEND_ONLY")
        )
        self.assertLess(
            prompt.index("CUSTOM_APPEND_ONLY"), prompt.index("PROJECT_CONVENTION_ONLY")
        )
        self.assertNotIn("CUSTOM_APPEND_ONLY", json.dumps(request["input"]))
        (self.app.workspace / "SYSTEM.md").write_text("NEW_BASE_ONLY")
        (self.app.workspace / "APPEND_SYSTEM.md").write_text("NEW_APPEND_ONLY")
        self.command("/reload", args={"target": "session"})
        (pinned,) = self.turn("after system file reload")
        self.assertEqual(pinned["instructions"], prompt)
        self.assertIn("NEW_BASE_ONLY", json.dumps(pinned["input"]))
        self.assertIn("NEW_APPEND_ONLY", json.dumps(pinned["input"]))
        self.command("/compact")
        self.compacted()
        (current,) = self.turn("after prompt compaction")
        self.assertTrue(current["instructions"].startswith("NEW_BASE_ONLY\n"))
        self.assertIn("NEW_APPEND_ONLY", current["instructions"])
        self.assertNotIn("CUSTOM_APPEND_ONLY", current["instructions"])

    @exclusive
    def test_system_files_share_instruction_discovery_paths(self):
        home = self.app.root / "user-home"
        locations = [
            self.app.workspace,
            self.app.workspace / ".agents",
            self.app.workspace / ".albedo",
            home / ".agents",
            home / ".albedo",
        ]
        system = []
        for i, directory in enumerate(locations):
            directory.mkdir(exist_ok=True)
            base = directory / "SYSTEM.md"
            append = directory / "APPEND_SYSTEM.md"
            if i:
                base.write_text(f"BASE_{i}")
                system.append(base)
                self.addCleanup(base.unlink, missing_ok=True)
            append.write_text(f"APPEND_{i}")
            self.addCleanup(append.unlink, missing_ok=True)
        (self.app.workspace / "AGENTS.md").write_text("AGENT_CONVENTIONS")
        (request,) = self.turn("discover all prompt paths")
        prompt = request["instructions"]
        self.assertTrue(prompt.startswith("BASE_1\n"))
        self.assertEqual([prompt.count(f"APPEND_{i}") for i in range(5)], [1] * 5)
        self.assertEqual([prompt.count(f"BASE_{i}") for i in range(1, 5)], [1, 0, 0, 0])
        positions = [prompt.index(f"APPEND_{i}") for i in range(5)]
        self.assertEqual(positions, sorted(positions))
        self.assertLess(positions[-1], prompt.index("AGENT_CONVENTIONS"))

        root = locations[0] / "SYSTEM.md"
        root.write_text("BASE_0")
        self.addCleanup(root.unlink, missing_ok=True)
        for expected, removed in [
            (0, root),
            (1, system[0]),
            (2, system[1]),
            (3, system[2]),
            (4, system[3]),
        ]:
            session = self.app.session()
            (next_request,) = self.turn(f"system priority {expected}", session)
            self.assertTrue(
                next_request["instructions"].startswith(f"BASE_{expected}\n")
            )
            removed.unlink()

    def test_oversized_agent_instructions_warn_and_allow_turns(self):
        (self.app.workspace / "AGENTS.md").write_text("X" * (1024 * 1024 + 1))
        (self.app.workspace / "CLAUDE.md").write_text("USABLE_CONVENTION")
        (request,) = self.turn("continue without oversized instructions")
        self.assertIn("USABLE_CONVENTION", request["instructions"])
        self.assertNotIn("X" * 128, request["instructions"])
        with self.app.api(f"/sessions/{self.sid}/stream?after_seq=0") as stream:
            events = json.loads(
                next(line[6:] for line in stream if line.startswith(b"data: "))
            )["events"]
        warnings = [
            event["text"]
            for event in events
            if event.get("type") == "note" and "AGENTS.md" in event.get("text", "")
        ]
        self.assertEqual(
            warnings, ["Warning: AGENTS.md exceeds 1 MiB and was not loaded"]
        )
        self.turn("next turn still works")

    @exclusive
    def test_instruction_locations_concatenate_in_scope_and_directory_order(self):
        home = self.app.root / "user-home"
        files = [
            (self.app.workspace / "AGENTS.md", "ROOT_AGENTS"),
            (self.app.workspace / "cLaUdE.Md", "ROOT_CLAUDE"),
            (self.app.workspace / ".agents/a.MD", "PROJECT_AGENTS_A"),
            (self.app.workspace / ".agents/z.md", "PROJECT_AGENTS_Z"),
            (self.app.workspace / ".albedo/a.md", "PROJECT_ALBEDO"),
            (home / ".agents/a.md", "GLOBAL_AGENTS"),
            (home / ".albedo/a.md", "GLOBAL_ALBEDO"),
        ]
        for path, marker in reversed(files):
            path.parent.mkdir(exist_ok=True)
            path.write_text(marker)
        (self.app.workspace / "SYSTEM.md").write_text("ROOT_SYSTEM")
        (self.app.workspace / ".agents/SyStEm.Md").write_text("UNSELECTED_SYSTEM")
        (self.app.workspace / ".agents/ApPeNd_SyStEm.Md").write_text("APPENDED_SYSTEM")
        (self.app.workspace / ".agents/ignored.txt").write_text("NON_MARKDOWN")

        (request,) = self.turn("inspect instruction ordering")
        prompt = request["instructions"]
        positions = [prompt.index(marker) for _, marker in files]
        self.assertEqual(positions, sorted(positions))
        self.assertEqual(
            [prompt.count(marker) for _, marker in files], [1] * len(files)
        )
        self.assertLess(prompt.index("APPENDED_SYSTEM"), positions[0])
        self.assertEqual(prompt.count("APPENDED_SYSTEM"), 1)
        self.assertNotIn("UNSELECTED_SYSTEM", prompt)
        self.assertNotIn("NON_MARKDOWN", prompt)
        self.assertLess(positions[4], prompt.index("## Global user preferences"))
        self.assertLess(prompt.index("## Global user preferences"), positions[5])
        self.assertIn(".agents/a.MD", prompt)
        self.assertIn("~/.agents/a.md", prompt)

    def test_system_replacement_reads_only_highest_priority_match(self):
        root = self.app.workspace / "SYSTEM.md"
        root.write_text("VALID_REPLACEMENT")
        directory = self.app.workspace / ".agents"
        directory.mkdir()
        (directory / "system.md").write_bytes(b"\xff")

        (request,) = self.turn("ignore unreadable lower priority prompt")
        self.assertTrue(request["instructions"].startswith("VALID_REPLACEMENT\n"))
        root.unlink()
        error = self.rejected(
            f"/sessions/{self.sid}/commands",
            {"name": "/reload", "args": {"target": "session"}},
        )
        self.assertIn(".agents/system.md must be UTF-8 text", error)

    @exclusive
    def test_instruction_discovery_limit_applies_before_capability_filtering(self):
        directory = self.app.workspace / ".agents"
        directory.mkdir()
        choices = {}
        for i in range(128):
            name = f"instruction-{i:03}.md"
            (directory / name).write_text("DISABLED_INSTRUCTION")
            choices[f"project:.agents/{name}"] = False
        (self.app.home / "capabilities.json").write_text(
            json.dumps({"global": {"instructions": choices}})
        )
        (request,) = self.turn("128 disabled instructions remain usable")
        self.assertNotIn("DISABLED_INSTRUCTION", request["instructions"])

        (directory / "overflow.md").write_text("OVERFLOW_INSTRUCTION")
        choices["project:.agents/overflow.md"] = False
        (self.app.home / "capabilities.json").write_text(
            json.dumps({"global": {"instructions": choices}})
        )
        error = self.rejected(
            f"/sessions/{self.sid}/commands",
            {"name": "/reload", "args": {"target": "session"}},
        )
        self.assertIn("more than 128 instruction files were discovered", error)

    def test_workspace_system_files_are_optional(self):
        (request,) = self.turn("no custom system files")
        self.assertTrue(
            request["instructions"].startswith(
                "You are a coding agent operating inside albedo"
            )
        )

    def test_catalog_is_lazy_and_activation_submits_one_turn(self):
        self.assertIn("session_extensions", self.get("/health")["capabilities"])
        installed = self.get(self.route)
        names = {item["name"] for item in installed if item["enabled"]}
        self.assertTrue({"python", "run", "work", "files", "skills"} <= names)
        (request,) = self.turn("first turn")
        context = request["instructions"]
        self.assertIn("catalog-only fixture description", context)
        self.assertIn(str(self.skill.resolve()), context)
        self.assertNotIn("BODY_MUST_NOT_AUTOLOAD", json.dumps(request))
        self.assertNotIn(
            "catalog-only fixture description", json.dumps(request["input"])
        )
        self.assertIn("returning {content, next_offset, size, truncated}", context)
        skills = next(item for item in self.get(self.route) if item["name"] == "skills")
        self.assertEqual(skills["requires"], ["python", "commands"])
        self.assertIn("skills", skills["python_modules"])
        self.assertEqual(skills["tools"], [])
        self.assertFalse(
            {"skills_read", "skills_list"} & {tool["name"] for tool in request["tools"]}
        )
        catalog = self.get(f"/sessions/{self.sid}/commands")
        self.assertEqual(
            [item for item in catalog if item["name"] == "/demo"],
            [
                {
                    "name": "/demo",
                    "description": "catalog-only fixture description",
                    "method": "demo",
                    "usage": "/demo [arguments]",
                    "arguments": [
                        {
                            "name": "arguments",
                            "description": "arguments for the skill",
                            "required": False,
                        }
                    ],
                    "modelCallable": True,
                    "userTurn": True,
                    "page": False,
                }
            ],
        )
        self.assertTrue(
            {"/model", "/context", "/compact"} <= {item["name"] for item in catalog}
        )
        before = len(self.provider.requests)
        self.assertEqual(
            self.command("/demo", arguments="one  two", clientId="fixture-client"),
            {"submitted": True},
        )
        self.app.idle(self.sid)
        self.assertEqual(len(self.provider.requests), before + 1)
        activation = json.dumps(self.provider.requests[-1]["request"]["input"])
        self.assertIn("BODY_MUST_NOT_AUTOLOAD", activation)
        self.assertIn("one  two", activation)
        self.assertIn(str(self.skill.resolve()), activation)
        self.assertEqual(self.get(f"/sessions/{self.sid}/commands"), catalog)
        self.skill.write_text(
            SKILL.replace("catalog-only fixture description", "changed on disk")
        )
        self.assertEqual(self.get(f"/sessions/{self.sid}/commands"), catalog)
        self.skill.write_text(SKILL)
        before = len(self.provider.requests)
        self.command("/demo", arguments="slash argument")
        self.app.idle(self.sid)
        self.assertEqual(len(self.provider.requests), before + 1)
        user = next(
            item["content"]
            for item in reversed(self.provider.requests[-1]["request"]["input"])
            if item.get("role") == "user"
        )
        activation = json.loads(user.split("\n", 1)[1])
        self.assertEqual(
            (activation["name"], activation["arguments"], activation["source"]),
            ("demo", "slash argument", str(self.skill.resolve())),
        )
        self.assertIn("BODY_MUST_NOT_AUTOLOAD", activation["instructions"])

    @exclusive
    def test_python_activation_and_user_only_model_switch(self):
        (self.app.home / "models.json").write_text("{}")
        requests = self.turn("activate demo via python", expected=2)
        self.assertIn("SKILL_PYTHON_ACTIVATION_OK", self.output(requests[-1]))
        session = self.app.session()
        requests = self.turn("model probe via python", session, expected=2)
        self.assertIn("MODEL_COMMAND_OK", self.output(requests[-1]))
        route = f"/sessions/{session}/commands"
        switched = self.post(
            route, {"name": "/model", "args": {"model": "switched-model"}}
        )["result"]
        self.assertEqual(
            (switched["model"], switched["provider"]),
            ("switched-model", self.app.profile),
        )
        self.assertEqual(
            next(s for s in self.get("/sessions") if s["id"] == session)["model"],
            "switched-model",
        )
        self.rejected(route, {"name": "/effort"})
        selected = self.post(route, {"name": "/model", "args": {"model": "o3-mini"}})[
            "result"
        ]
        self.assertEqual((selected["model"], selected["effort"]), ("o3-mini", "medium"))
        effort = self.post(route, {"name": "/effort"})["result"]
        self.assertEqual(
            (effort["effort"], effort["available"]),
            ("medium", ["low", "medium", "high"]),
        )
        self.rejected(route, {"name": "/effort", "args": {"level": "bogus"}})
        effort = self.post(route, {"name": "/effort", "args": {"level": "high"}})[
            "result"
        ]
        self.assertEqual(effort["effort"], "high")
        self.assertIn("reasoning effort set to high", effort["message"])
        self.assertEqual(
            next(s for s in self.get("/sessions") if s["id"] == session)["effort"],
            "high",
        )
        picked = self.post(
            route, {"name": "/model", "args": {"model": "o3-mini", "effort": "low"}}
        )
        self.assertEqual(picked["result"]["effort"], "low")
        self.rejected(
            route, {"name": "/model", "args": {"model": "o3-mini", "effort": "max"}}
        )
        self.rejected(
            route,
            {"name": "/model", "args": {"model": "switched-model", "effort": "low"}},
        )
        self.assertEqual(
            next(s for s in self.get("/sessions") if s["id"] == session)["model"],
            "o3-mini",
        )

    def test_work_page_queues_agent_note_without_starting_turn(self):
        command = next(
            c
            for c in self.get(f"/sessions/{self.sid}/commands")
            if c["name"] == "/work"
        )
        self.assertTrue(command["page"])
        self.assertFalse(command["modelCallable"])
        page = self.command("/work", args={})["result"]["page"]
        self.assertEqual(page["title"], "work")
        self.assertTrue(
            {"a", "d", "x"} <= {action["key"] for action in page["actions"]}
        )
        added = self.command(
            "/work", args={"action": "add", "details": "write the release notes"}
        )
        self.assertIn("the agent will be told", added["result"]["message"])
        before = len(self.provider.requests)
        time.sleep(0.3)
        self.assertEqual(len(self.provider.requests), before)
        (request,) = self.turn("anything new on the ledger?")
        context = json.dumps(request["input"])
        self.assertIn("The user added work item", context)
        note = next(
            item["content"]
            for item in request["input"]
            if item.get("role") == "user"
            and "The user added work item" in item.get("content", "")
        )
        self.assertEqual(
            (note.count("<system-note>"), note.count("</system-note>")), (1, 1)
        )
        self.assertLess(
            context.index("The user added work item"),
            context.index("anything new on the ledger?"),
        )
        page = self.command("/work", args={})["result"]["page"]
        self.assertTrue(
            any(
                row["text"] == "write the release notes"
                for row in page["glance"]["rows"]
            )
        )

    def test_work_command_is_scoped_to_each_workspace(self):
        workspaces = [self.app.root / "work-one", self.app.root / "work-two"]
        for workspace in workspaces:
            workspace.mkdir()
        sessions = [self.app.session(workspace) for workspace in workspaces]

        def invoke(session, args):
            return self.post(
                f"/sessions/{session}/commands", {"name": "/work", "args": args}
            )

        invoke(sessions[0], {"action": "add", "details": "first workspace item"})
        first_page = invoke(sessions[0], {})
        second_page = invoke(sessions[1], {})
        self.assertIn("first workspace item", json.dumps(first_page))
        self.assertNotIn("first workspace item", json.dumps(second_page))
        invoke(sessions[1], {"action": "add", "details": "second workspace item"})
        self.assertNotIn("second workspace item", json.dumps(invoke(sessions[0], {})))
        self.assertIn("second workspace item", json.dumps(invoke(sessions[1], {})))

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
        self.assertEqual(
            self.get(f"/sessions/{self.sid}/tree?after=0&limit=100")["items"], original
        )
        (request,) = self.turn("after manual compaction")
        self.assertIn("older conversation summary", json.dumps(request["input"]))
        context = self.get(f"/sessions/{self.sid}/context")
        self.assertEqual(
            (context["state"], context["compaction"]["status"]), ("ready", "compacted")
        )
        with self.app.api(f"/sessions/{self.sid}/stream?after_seq=0") as stream:
            events = json.loads(
                next(line[6:] for line in stream if line.startswith(b"data: "))
            )["events"]
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
        late.write_text(
            "---\nname: late\ndescription: added after the session opened\n---\nLATE_BODY\n"
        )
        self.skill.write_text(
            SKILL.replace(
                "catalog-only fixture description", "updated demo description"
            )
        )
        self.assertNotIn(
            "/late", {c["name"] for c in self.get(f"/sessions/{self.sid}/commands")}
        )
        requests = self.turn("hot probe before reload", expected=2)
        self.assertIn("BEFORE_RELOAD_OK", self.output(requests[-1]))
        cached = requests[-1]
        reloaded = self.command("/reload", args={"target": "session"})
        self.assertEqual(reloaded["result"]["reloaded"], "session")
        self.assertIn(
            "/late", {c["name"] for c in self.get(f"/sessions/{self.sid}/commands")}
        )
        (request,) = self.turn("after session reload")
        self.assertEqual(request["instructions"], cached["instructions"])
        updates = [
            item["content"]
            for item in request["input"]
            if item.get("role") == "user"
            and str(item.get("content", "")).startswith("<system-note")
            and "capabilities changed" in item["content"]
        ]
        self.assertEqual(len(updates), 1)
        self.assertIn("commands.catalog()", updates[0])
        self.assertIn("updated demo description", updates[0])
        self.assertIn("<name>demo</name>", updates[0])
        self.assertIn("/late", updates[0])
        self.assertNotIn("catalog-only fixture description", updates[0])
        self.assertNotIn("LATE_BODY", updates[0])
        self.assertNotIn("BODY_MUST_NOT_AUTOLOAD", updates[0])
        requests = self.turn("hot probe after reload", expected=2)
        self.assertIn("AFTER_RELOAD_OK", self.output(requests[-1]))
        newer = self.app.workspace / ".agents/skills/newer/SKILL.md"
        newer.parent.mkdir(parents=True)
        newer.write_text(
            "---\nname: newer\ndescription: another live skill\n---\nNEWER_BODY\n"
        )
        late.unlink()
        self.command("/reload", args={"target": "session"})
        (request,) = self.turn("after second reload")
        self.assertEqual(request["instructions"], cached["instructions"])
        update = next(
            item["content"]
            for item in reversed(request["input"])
            if item.get("role") == "user"
            and "capabilities changed" in str(item.get("content", ""))
        )
        self.assertIn("another live skill", update)
        self.assertIn("supersedes any earlier version", update)
        self.assertNotIn("<command>/late</command>", update)
        self.assertNotIn("  /late ", update)
        self.assertNotIn("catalog-only fixture description", update)
        self.assertNotIn("NEWER_BODY", update)
        self.assertIn("/newer", update)
        self.assertEqual(
            sum(
                "capabilities changed" in str(item.get("content", ""))
                for item in request["input"]
                if item.get("role") == "user"
            ),
            2,
        )
        self.restart()
        (request,) = self.turn("reload pin survives restart")
        self.assertEqual(request["instructions"], cached["instructions"])
        self.turn("one more turn before compaction")
        self.command("/compact")
        self.compacted()
        self.app.idle(self.sid)
        first = self.get(f"/sessions/{self.sid}/context/instructions/0")
        snapshot = "".join(
            self.get(f"/sessions/{self.sid}/context/instructions/{page}")["content"]
            for page in range(first["pages"])
        )
        self.assertNotIn("added after the session opened", snapshot)
        self.assertIn("updated demo description", snapshot)
        self.assertIn("another live skill", snapshot)
        (request,) = self.turn("after compaction following reload")
        self.assertNotIn("added after the session opened", request["instructions"])
        self.assertIn("updated demo description", request["instructions"])
        self.assertIn("another live skill", request["instructions"])
        (request,) = self.turn("pin stays released")
        self.assertIn("another live skill", request["instructions"])

    @exclusive
    def test_auto_compaction_releases_pin_on_first_turn_after_restart(self):
        for index in range(4):
            self.turn(f"older turn {index}: " + "history " * 8000)
        self.skill.write_text(
            SKILL.replace(
                "catalog-only fixture description", "reloaded skill description"
            )
        )
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
        self.assertNotIn(
            "catalog-only fixture description", requests[-1]["instructions"]
        )
        self.assertIn("older conversation summary", json.dumps(requests[-1]["input"]))

    @exclusive
    def test_live_toggles_guard_dependencies_busy_turns_and_persist(self):
        self.turn("first turn")
        installed = self.get(self.route)
        self.rejected(self.route, {"name": "not-installed", "enabled": False})
        self.rejected(self.route, {"name": "python", "enabled": False})
        self.assertEqual(self.get(self.route), installed)
        disabled = self.post(self.route, {"name": "skills", "enabled": False})
        self.assertFalse(
            next(item["enabled"] for item in disabled if item["name"] == "skills")
        )
        self.rejected(
            f"/sessions/{self.sid}/commands",
            {"name": "/demo", "arguments": "must not run"},
        )
        pid = self.app.connection["pid"]
        (request,) = self.turn("extension disabled")
        self.assertIn("<available_skills>", request["instructions"])
        self.assertIn("Context removed: skills", json.dumps(request["input"]))
        self.assertNotIn(
            "skills",
            {
                module
                for item in disabled
                if item["enabled"]
                for module in item["python_modules"]
            },
        )
        self.assertFalse(
            {"skills_read", "skills_list"} & {tool["name"] for tool in request["tools"]}
        )
        self.assertEqual(
            json.loads((self.app.home / "daemon.json").read_text())["pid"], pid
        )
        # The provider holds this turn active while configuration changes are
        # refused, until the test releases it.
        release = threading.Event()
        self.addCleanup(release.set)

        def held(_request):
            release.wait(30)
            return text("done")

        self.provider.script = held
        self.app.prompt(self.sid, "hold this turn").close()
        deadline = time.monotonic() + 10
        while len(self.provider.requests) < 3 and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertGreaterEqual(len(self.provider.requests), 3)
        self.rejected(self.route, {"name": "skills", "enabled": True})
        self.rejected(
            f"/sessions/{self.sid}/commands",
            {"name": "/model", "args": {"model": "mid-run"}},
        )
        self.rejected(f"/sessions/{self.sid}/commands", {"name": "/compact"})
        self.assertEqual(self.get(self.route), disabled)
        release.set()
        self.app.idle(self.sid)
        self.provider.script = scripted
        self.restart()
        self.assertFalse(
            next(
                item["enabled"]
                for item in self.get(self.route)
                if item["name"] == "skills"
            )
        )
        self.skill.write_text(
            SKILL.replace(
                "catalog-only fixture description", "refreshed catalog description"
            )
        )
        self.post(self.route, {"name": "skills", "enabled": True})
        (request,) = self.turn("extension reloaded")
        self.assertIn("refreshed catalog description", request["instructions"])
        self.assertNotIn("BODY_MUST_NOT_AUTOLOAD", request["instructions"])

    @exclusive
    def test_compaction_strategies_preserve_lcm_folds_across_switch_and_restart(self):
        self.turn("first turn")
        self.turn("second turn")
        self.turn("third turn")
        self.turn("fourth turn")
        self.assertIn(
            "unknown compaction strategy skills",
            self.rejected(
                f"/sessions/{self.sid}/commands",
                {"name": "/compact", "arguments": "skills"},
            ),
        )
        self.assertFalse(
            next(
                item["enabled"]
                for item in self.get(self.route)
                if item["name"] == "lcm"
            )
        )
        result = self.command("/compact", arguments="lcm")["result"]
        self.assertEqual((result["strategy"], result["started"]), ("lcm", True))
        self.app.idle(self.sid)
        selected = self.get(self.route)
        self.assertTrue(
            next(item["enabled"] for item in selected if item["name"] == "lcm")
        )
        self.assertFalse(
            next(item["enabled"] for item in selected if item["name"] == "rolling")
        )
        self.rejected(self.route, {"name": "lcm", "enabled": False})
        (request,) = self.turn("lcm preflight")
        self.assertTrue(
            {"lcm_list", "lcm_grep", "lcm_describe", "lcm_expand"}
            <= {tool["name"] for tool in request["tools"]}
        )
        requests = self.turn("lcm tool probe", expected=2)
        self.assertIn("LCM summary node #", json.dumps(requests[0]["input"]))
        self.assertIn("source_count", self.output(requests[-1]))
        self.assertIn("first turn", self.output(requests[-1]))
        self.assertEqual(
            self.get(f"/sessions/{self.sid}/context")["compaction"]["strategy"], "lcm"
        )
        selected = self.post(self.route, {"name": "rolling", "enabled": True})
        self.assertTrue(
            next(item["enabled"] for item in selected if item["name"] == "rolling")
        )
        self.assertFalse(
            next(item["enabled"] for item in selected if item["name"] == "lcm")
        )
        (request,) = self.turn("folded under rolling")
        self.assertIn("LCM summary node #", json.dumps(request["input"]))
        requests = self.turn("fold list probe", expected=2)
        self.assertGreater(json.loads(self.output(requests[-1]))["total"], 0)
        self.assertEqual(
            self.get(f"/sessions/{self.sid}/context")["compaction"]["strategy"],
            "rolling",
        )
        self.restart()
        selected = self.get(self.route)
        self.assertTrue(
            next(item["enabled"] for item in selected if item["name"] == "rolling")
        )
        self.assertFalse(
            next(item["enabled"] for item in selected if item["name"] == "lcm")
        )
        (request,) = self.turn("folded after restart")
        self.assertIn("LCM summary node #", json.dumps(request["input"]))
