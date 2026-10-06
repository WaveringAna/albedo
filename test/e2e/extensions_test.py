"""Extension catalog, commands, live reload, and compaction through a real daemon."""

import json
from pathlib import Path
import threading
import unittest
import urllib.error
import urllib.parse

from harness import Albedo, Provider, exclusive, operation_id, python, text


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


def capability_notes(request):
    """The capability notes a request carries as inputs of their own; the
    rolling recap may quote the newest one too."""
    return [
        item["content"]
        for item in request["input"]
        if item.get("role") == "user"
        and str(item.get("content", "")).startswith(
            '<system-note origin="capabilities changed">'
        )
    ]


class ExtensionTests(unittest.TestCase):
    def setUp(self):
        self.provider = Provider(scripted)
        self.addCleanup(self.provider.close)
        self.app = Albedo(
            self.provider,
            protocol="responses",
            providers={
                f"fixture-{self.provider.route}": {
                    "extension": "openai",
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

    def get(self, path):
        with self.app.api(path) as response:
            return json.load(response)

    def post(self, path, body):
        with self.app.api(path, body) as response:
            return json.load(response)

    def catalog(self):
        return self.get(f"/sessions/{self.sid}/catalog")

    def commands(self):
        return self.catalog()["loaded"]["commands"]

    def reload(self):
        return self.post(f"/sessions/{self.sid}/reload", {"target": "session"})

    def compact(self, strategy=None):
        return self.post(
            f"/sessions/{self.sid}/compaction",
            {"strategy": strategy} if strategy else {},
        )

    def change(self, fields, session=None):
        route = f"/sessions/{session or self.sid}?view=configuration"
        with self.app.api(route) as response:
            json.load(response)
            etag = response.headers["ETag"]
        with self.app.api(
            route, fields, method="PATCH", headers={"If-Match": etag}
        ) as response:
            return json.load(response)

    def snapshot(self):
        return self.get(f"/sessions/{self.sid}?tail=0")

    def extensions(self):
        return self.snapshot()["selection"]["effective"]["extensions"]

    def section_text(self, section):
        snapshot = self.get(f"/sessions/{self.sid}/context")
        descriptor = next(row for row in snapshot["sections"] if row["id"] == section)
        chunks = []
        for page in range(descriptor["page_count"]):
            query = urllib.parse.urlencode(
                {
                    "view": "section",
                    "snapshot_id": snapshot["snapshot_id"],
                    "section_id": section,
                    "page": page,
                }
            )
            chunks.append(self.get(f"/sessions/{self.sid}/context?{query}")["text"])
        return "".join(chunks)

    def activate(self, name, *, arguments="", client_id=None):
        catalog = self.catalog()["discovery"]
        candidate = next(
            row
            for row in catalog["candidates"]
            if row["kind"] == "skill"
            and row["preference_key"] == name.removeprefix("/")
        )
        body = {
            "kind": "skill",
            "candidate_id": candidate["id"],
            "catalog_revision": catalog["revision"],
            "arguments": arguments,
        }
        if client_id is not None:
            body["client_id"] = client_id
        with self.app.api(
            f"/sessions/{self.sid}/inputs/{operation_id()}", body, method="PUT"
        ) as response:
            return json.load(response)

    def turn(self, prompt, session=None, *, expected=1):
        sid = session or self.sid
        before = len(self.provider.requests)
        self.app.prompt(sid, prompt).close()
        self.app.idle(sid)
        self.assertEqual(len(self.provider.requests) - before, expected)
        return [entry["request"] for entry in self.provider.requests[before:]]

    def restart(self):
        self.app.restart()

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
        self.reload()
        (pinned,) = self.turn("after system file reload")
        self.assertEqual(pinned["instructions"], prompt)
        self.assertIn("NEW_BASE_ONLY", json.dumps(pinned["input"]))
        self.assertIn("NEW_APPEND_ONLY", json.dumps(pinned["input"]))
        self.compact()
        (current,) = self.turn("after prompt compaction")
        self.assertTrue(current["instructions"].startswith("NEW_BASE_ONLY\n"))
        self.assertIn("NEW_APPEND_ONLY", current["instructions"])
        self.assertNotIn("CUSTOM_APPEND_ONLY", current["instructions"])

    # exclusive: writes global home instruction files
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
        before = self.app.stream_page(self.sid)
        (self.app.workspace / "AGENTS.md").write_text("X" * (1024 * 1024 + 1))
        (self.app.workspace / "CLAUDE.md").write_text("USABLE_CONVENTION")
        (request,) = self.turn("continue without oversized instructions")
        self.assertIn("USABLE_CONVENTION", request["instructions"])
        self.assertNotIn("X" * 128, request["instructions"])
        events = self.app.stream_page(self.sid, before)["events"]
        warnings = [
            event["data"]["text"]
            for event in events
            if event["type"] == "note" and "AGENTS.md" in event["data"]["text"]
        ]
        self.assertEqual(
            warnings, ["Warning: AGENTS.md exceeds 1 MiB and was not loaded"]
        )
        self.turn("next turn still works")

    # exclusive: writes global home instruction files
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
        outcome = self.reload()
        self.assertEqual(outcome["session"]["state"], "failed")
        error = json.dumps(outcome["session"]["failure"])
        self.assertIn(".agents/system.md must be UTF-8 text", error)

    # exclusive: writes daemon-wide capabilities.json
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
        outcome = self.reload()
        self.assertEqual(outcome["session"]["state"], "failed")
        error = json.dumps(outcome["session"]["failure"])
        self.assertIn("more than 128 instruction files were discovered", error)

    def test_workspace_system_files_are_optional(self):
        (request,) = self.turn("no custom system files")
        self.assertTrue(
            request["instructions"].startswith(
                "You are a coding agent operating inside albedo"
            )
        )

    def test_catalog_is_lazy_and_activation_submits_one_turn(self):
        initial = self.catalog()
        self.assertFalse(self.provider.requests)
        self.assertIsNone(self.get(f"/sessions/{self.sid}/context")["snapshot_id"])
        (request,) = self.turn("first turn")
        context = request["instructions"]
        self.assertIn("catalog-only fixture description", context)
        self.assertIn(str(self.skill.resolve()), context)
        self.assertNotIn("BODY_MUST_NOT_AUTOLOAD", json.dumps(request))
        skills = next(
            row
            for row in initial["discovery"]["candidates"]
            if row["kind"] == "extension" and row["preference_key"] == "skills"
        )
        self.assertEqual(skills["dependencies"], ["python", "commands"])
        self.assertEqual(skills["extension"]["tools"], [])
        catalog = self.commands()
        demo = next(row for row in catalog if row["slash_name"] == "/demo")
        self.assertEqual(demo["delivery"], "input")
        self.assertTrue({"human", "model"} <= set(demo["caller_permissions"]))
        before = len(self.provider.requests)
        receipt = self.activate(
            "/demo", arguments="one  two", client_id="fixture-client"
        )
        self.assertEqual(
            (receipt["admission"], receipt["client_id"]), ("accepted", "fixture-client")
        )
        self.app.idle(self.sid)
        self.assertEqual(len(self.provider.requests), before + 1)
        activation = json.dumps(self.provider.requests[-1]["request"]["input"])
        for marker in ("BODY_MUST_NOT_AUTOLOAD", "one  two", str(self.skill.resolve())):
            self.assertIn(marker, activation)
        self.assertEqual(self.commands(), catalog)
        self.skill.write_text(
            SKILL.replace("catalog-only fixture description", "changed on disk")
        )
        self.assertEqual(self.commands(), catalog)
        self.skill.write_text(SKILL)
        before = len(self.provider.requests)
        self.activate("/demo", arguments="slash argument")
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

    # exclusive: writes models.json and /model saves global defaults
    # exclusive: model catalog seeded on disk
    @exclusive
    def test_python_activation_and_user_only_model_switch(self):
        (self.app.home / "models.json").write_text("{}")
        requests = self.turn("activate demo via python", expected=2)
        self.assertIn("SKILL_PYTHON_ACTIVATION_OK", self.output(requests[-1]))
        session = self.app.session()
        requests = self.turn("model probe via python", session, expected=2)
        self.assertIn("MODEL_COMMAND_OK", self.output(requests[-1]))
        selected = self.change({"model": "switched-model"}, session)["session"]
        self.assertEqual(
            (selected["model"], selected["provider_profile"]),
            ("switched-model", self.app.profile),
        )
        selected = self.change({"model": "o3-mini"}, session)["session"]
        self.assertEqual((selected["model"], selected["effort"]), ("o3-mini", "medium"))
        with self.assertRaises(urllib.error.HTTPError):
            self.change({"effort": "bogus"}, session)
        selected = self.change({"effort": "high"}, session)["session"]
        self.assertEqual(selected["effort"], "high")
        self.assertEqual(
            self.change({"model": "o3-mini", "effort": "low"}, session)["session"][
                "effort"
            ],
            "low",
        )
        for fields in (
            {"model": "o3-mini", "effort": "max"},
            {"model": "switched-model", "effort": "low"},
        ):
            with self.assertRaises(urllib.error.HTTPError):
                self.change(fields, session)
        self.assertEqual(self.get(f"/sessions/{session}")["model"], "o3-mini")

    def test_work_page_queues_agent_note_without_starting_turn(self):
        route = "/extensions/work/items?" + urllib.parse.urlencode(
            {"workspace": str(self.app.workspace)}
        )
        page = self.get(route)["page"]
        self.assertEqual(page["title"], "work")
        before = len(self.provider.requests)
        added = self.post(
            route, {"title": "write the release notes", "session_id": self.sid}
        )
        self.assertEqual(added["notification"]["state"], "queued")
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
        self.assertTrue(
            any(
                resource["value"]["title"] == "write the release notes"
                for resource in self.get(route)["items"]
            )
        )

    def test_work_resources_are_scoped_to_each_workspace(self):
        workspaces = [self.app.root / "work-one", self.app.root / "work-two"]
        for workspace in workspaces:
            workspace.mkdir()
            self.app.session(workspace)
        routes = [
            "/extensions/work/items?"
            + urllib.parse.urlencode({"workspace": str(workspace)})
            for workspace in workspaces
        ]
        self.post(routes[0], {"title": "first workspace item"})
        self.assertIn("first workspace item", json.dumps(self.get(routes[0])))
        self.assertNotIn("first workspace item", json.dumps(self.get(routes[1])))
        self.post(routes[1], {"title": "second workspace item"})
        self.assertNotIn("second workspace item", json.dumps(self.get(routes[0])))
        self.assertIn("second workspace item", json.dumps(self.get(routes[1])))

    def test_manual_compaction_preserves_durable_history_and_reuses_summary(self):
        cursor = self.app.stream_page(self.sid)
        for prompt in ("first turn", "second turn", "third turn", "fourth turn"):
            self.turn(prompt)
        original = self.app.history(self.sid)["items"]
        before = len(self.provider.requests)
        outcome = self.compact()
        self.assertEqual(
            (outcome["effective_strategy"], outcome["state"]), ("rolling", "compacted")
        )
        self.assertFalse(outcome["selection_applied"])
        self.assertIsNone(outcome["failure"])
        self.assertEqual(outcome["observation"]["strategy"], "rolling")
        self.assertGreater(outcome["observation"]["evicted_entries"], 0)
        self.assertEqual(len(self.provider.requests), before + 2)
        current = self.app.history(self.sid)["items"]
        self.assertEqual(
            [
                entry
                for entry in current
                if entry["position"] <= original[-1]["position"]
            ],
            original,
        )
        (request,) = self.turn("after manual compaction")
        self.assertIn("older conversation summary", json.dumps(request["input"]))
        context = self.get(f"/sessions/{self.sid}/context")
        self.assertEqual(
            (context["state"], context["compaction"]["status"]), ("ready", "compacted")
        )
        events = self.app.stream_page(self.sid, cursor)["events"]
        compacted = next(
            event["data"] for event in events if event["type"] == "compacted"
        )
        self.assertEqual(compacted, outcome["observation"])
        self.assertGreater(compacted["evicted_entries"], 0)
        self.assertIn("older conversation summary", compacted["summary"])
        self.assertIn("older conversation summary", self.section_text("history"))

    def test_every_shipped_skill_loads(self):
        self.reload()
        shipped = sorted(
            path.name for path in (Path(__file__).parents[2] / "priv/skills").iterdir()
        )
        listed = {c["slash_name"] for c in self.commands()}
        self.assertEqual([name for name in shipped if f"/{name}" not in listed], [])

    def test_builtin_skill_is_listed_and_yields_to_a_workspace_skill_of_the_same_name(
        self,
    ):
        def description():
            return next(
                c["description"]
                for c in self.commands()
                if c["slash_name"] == "/customize-albedo"
            )

        self.reload()
        catalog_route = f"/sessions/{self.sid}/catalog"
        builtin = next(
            row
            for row in self.get(catalog_route)["discovery"]["candidates"]
            if row["preference_key"] == "customize-albedo"
        )
        self.assertTrue(builtin["valid"])
        self.assertTrue(builtin["eligible"])
        self.assertEqual(description(), builtin["description"])
        override = self.app.workspace / ".agents/skills/customize-albedo/SKILL.md"
        override.parent.mkdir(parents=True)
        override.write_text(
            "---\nname: customize-albedo\ndescription: workspace override\n---\nmine\n"
        )
        self.reload()
        self.assertEqual(description(), "workspace override")
        candidates = [
            row
            for row in self.get(catalog_route)["discovery"]["candidates"]
            if row["preference_key"] == "customize-albedo"
        ]
        selected = next(row for row in candidates if row["source"] == str(override))
        shipped = next(row for row in candidates if row["id"] == builtin["id"])
        self.assertTrue(selected["eligible"])
        self.assertTrue(shipped["valid"])
        self.assertFalse(shipped["eligible"])
        self.assertEqual(shipped["shadowed_by"], selected["id"])
        (request,) = self.turn("after override")
        self.assertNotIn("duplicate skill", json.dumps(request["input"]))

    # exclusive: restarts the daemon
    @exclusive
    def test_reload_pins_system_prompt_until_compaction(self):
        self.turn("first turn")
        catalog_route = f"/sessions/{self.sid}/catalog"
        original_catalog = self.get(catalog_route)["discovery"]
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
        self.assertNotIn("/late", {c["slash_name"] for c in self.commands()})
        fresh_catalog = self.get(catalog_route)["discovery"]
        self.assertNotEqual(fresh_catalog["revision"], original_catalog["revision"])
        late_row = next(
            row
            for row in fresh_catalog["candidates"]
            if row["preference_key"] == "late"
        )
        self.assertTrue(late_row["eligible"])
        self.assertEqual(
            self.get(catalog_route)["discovery"]["revision"], fresh_catalog["revision"]
        )
        requests = self.turn("hot probe before reload", expected=2)
        self.assertIn("BEFORE_RELOAD_OK", self.output(requests[-1]))
        cached = requests[-1]
        reloaded = self.reload()
        self.assertEqual(reloaded["session"]["state"], "applied")
        self.assertIn("/late", {c["slash_name"] for c in self.commands()})
        current_catalog = self.get(catalog_route)["discovery"]
        self.assertEqual(current_catalog["revision"], fresh_catalog["revision"])
        self.assertEqual(
            next(
                row["id"]
                for row in current_catalog["candidates"]
                if row["preference_key"] == "late"
            ),
            late_row["id"],
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
        self.reload()
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
        self.compact()
        self.app.idle(self.sid)
        snapshot = self.section_text("instructions")
        self.assertNotIn("added after the session opened", snapshot)
        self.assertIn("updated demo description", snapshot)
        self.assertIn("another live skill", snapshot)
        (request,) = self.turn("after compaction following reload")
        self.assertNotIn("added after the session opened", request["instructions"])
        self.assertIn("updated demo description", request["instructions"])
        self.assertIn("another live skill", request["instructions"])
        (request,) = self.turn("pin stays released")
        self.assertIn("another live skill", request["instructions"])

    # exclusive: restarts the daemon
    @exclusive
    def test_restart_keeps_sent_system_prompt_until_compaction(self):
        for index in range(3):
            self.turn(f"older turn {index}")
        self.compact()
        self.app.idle(self.sid)
        (sent,) = self.turn("turn after compaction")
        self.assertIn("[older conversation summary;", json.dumps(sent["input"]))
        self.skill.write_text(
            SKILL.replace(
                "catalog-only fixture description", "edited while the daemon was down"
            )
        )
        self.restart()
        (request,) = self.turn("first turn after restart")
        self.assertEqual(request["instructions"], sent["instructions"])
        updates = capability_notes(request)
        self.assertEqual(len(updates), 1)
        self.assertIn("edited while the daemon was down", updates[0])
        self.restart()
        (request,) = self.turn("unchanged restart")
        self.assertEqual(request["instructions"], sent["instructions"])
        self.assertEqual(capability_notes(request), updates)

    # exclusive: changes global compaction settings and restarts the daemon
    @exclusive
    def test_auto_compaction_releases_pin_on_first_turn_after_restart(self):
        for index in range(4):
            self.turn(f"older turn {index}: " + "history " * 8000)
        self.skill.write_text(
            SKILL.replace(
                "catalog-only fixture description", "reloaded skill description"
            )
        )
        self.reload()
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

    # exclusive: restarts the daemon
    @exclusive
    def test_live_toggles_guard_dependencies_busy_turns_and_persist(self):
        self.turn("first turn")
        installed = self.extensions()
        for name in ("not-installed", "python"):
            with self.assertRaises(urllib.error.HTTPError):
                self.change({"selection": {"extensions": {name: False}}})
        self.assertEqual(self.extensions(), installed)
        self.change({"selection": {"extensions": {"skills": False}}})
        self.reload()
        disabled = self.extensions()
        self.assertFalse(disabled["skills"])
        with self.assertRaises(urllib.error.HTTPError):
            self.activate("/demo", arguments="must not run")
        pid = self.app.connection["pid"]
        (request,) = self.turn("extension disabled")
        self.assertIn("Context removed: skills", json.dumps(request["input"]))
        self.assertEqual(
            json.loads((self.app.home / "daemon.json").read_text())["pid"], pid
        )
        entered, release = threading.Event(), threading.Event()
        self.addCleanup(release.set)

        def held(_request):
            entered.set()
            release.wait(30)
            return text("done")

        self.provider.script = held
        self.app.prompt(self.sid, "hold this turn").close()
        self.assertTrue(entered.wait(10))
        for fields in (
            {"selection": {"extensions": {"skills": True}}},
            {"model": "mid-run"},
        ):
            with self.assertRaises(urllib.error.HTTPError) as caught:
                self.change(fields)
            self.assertEqual(caught.exception.code, 409)
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self.compact()
        self.assertEqual(caught.exception.code, 409)
        self.assertEqual(self.extensions(), disabled)
        release.set()
        self.app.idle(self.sid)
        self.provider.script = scripted
        self.restart()
        self.assertFalse(self.extensions()["skills"])
        self.skill.write_text(
            SKILL.replace(
                "catalog-only fixture description", "refreshed catalog description"
            )
        )
        self.change({"selection": {"extensions": {"skills": True}}})
        self.reload()
        refreshed = next(
            command for command in self.commands() if command["slash_name"] == "/demo"
        )
        self.assertEqual(refreshed["description"], "refreshed catalog description")
        (request,) = self.turn("extension reloaded")
        self.assertNotIn("BODY_MUST_NOT_AUTOLOAD", request["instructions"])

    # exclusive: restarts the daemon
    @exclusive
    def test_compaction_strategies_preserve_lcm_folds_across_switch_and_restart(self):
        for prompt in ("first turn", "second turn", "third turn", "fourth turn"):
            self.turn(prompt)
        refused = self.compact("skills")
        self.assertEqual(refused["state"], "failed")
        self.assertFalse(refused["selection_applied"])
        self.assertIsNotNone(refused["failure"])
        self.assertFalse(self.extensions()["lcm"])
        result = self.compact("lcm")
        self.assertEqual(
            (result["effective_strategy"], result["state"]), ("lcm", "compacted")
        )
        self.assertTrue(result["selection_applied"])
        self.assertIsNone(result["failure"])
        self.assertEqual(result["observation"]["strategy"], "lcm")
        self.assertTrue(self.extensions()["lcm"])
        self.assertFalse(self.extensions()["rolling"])
        self.change({"selection": {"extensions": {"lcm": False}}})
        configured = self.get(f"/sessions/{self.sid}?view=configuration")
        self.assertFalse(configured["selection"]["extensions"]["lcm"])
        refused_reload = self.reload()
        self.assertEqual(refused_reload["session"]["state"], "failed")
        self.assertIsNotNone(refused_reload["session"]["failure"])
        (request,) = self.turn("lcm preflight")
        self.assertTrue(
            {"lcm_list", "lcm_grep", "lcm_describe", "lcm_expand"}
            <= {tool["name"] for tool in request["tools"]}
        )
        requests = self.turn("lcm tool probe", expected=2)
        self.assertIn("LCM summary node #", json.dumps(requests[0]["input"]))
        self.assertIn("source_count", self.output(requests[-1]))
        self.assertIn("first turn", self.output(requests[-1]))
        self.change({"selection": {"extensions": {"lcm": True}}})
        self.assertEqual(self.reload()["session"]["state"], "applied")
        configuration_url = f"/sessions/{self.sid}?view=configuration"
        before_conflict = self.get(configuration_url)
        with self.assertRaises(urllib.error.HTTPError) as conflict:
            self.change({"selection": {"extensions": {"lcm": True, "rolling": True}}})
        self.assertEqual(conflict.exception.code, 400)
        self.assertEqual(json.load(conflict.exception)["code"], "selection_conflict")
        self.assertEqual(self.get(configuration_url), before_conflict)
        self.change({"selection": {"extensions": {"rolling": True}}})
        self.assertEqual(self.reload()["session"]["state"], "applied")
        self.assertTrue(self.extensions()["rolling"])
        self.assertFalse(self.extensions()["lcm"])
        (request,) = self.turn("folded under rolling")
        self.assertIn("LCM summary node #", json.dumps(request["input"]))
        requests = self.turn("fold list probe", expected=2)
        self.assertGreater(json.loads(self.output(requests[-1]))["total"], 0)
        self.assertEqual(
            self.get(f"/sessions/{self.sid}/context")["compaction"]["strategy"],
            "rolling",
        )
        self.restart()
        self.assertTrue(self.extensions()["rolling"])
        self.assertFalse(self.extensions()["lcm"])
        (request,) = self.turn("folded after restart")
        self.assertIn("LCM summary node #", json.dumps(request["input"]))

    def test_rest_extension_edits_compare_the_displayed_resource_at_commit(self):
        """Concurrent clients cannot overwrite a newer edit or delete its row."""
        cases = [
            (
                "/extensions/work/items?"
                + urllib.parse.urlencode({"workspace": str(self.app.workspace)}),
                {"title": "original"},
                "title",
                "😀" * 1025,
            ),
            (
                "/extensions/paperclips/items",
                {"message": "original"},
                "reply",
                "😀" * 4097,
            ),
            (
                "/extensions/schedule/jobs",
                {
                    "session_id": self.sid,
                    "kind": "once",
                    "prompt": "original",
                    "delay_seconds": 86400,
                },
                "prompt",
                "😀" * 1025,
            ),
        ]
        before = len(self.provider.requests)
        for collection, creation, field, oversize in cases:
            with self.subTest(collection=collection):
                created = self.post(collection, creation)["resource"]
                route = created["url"]
                try:
                    with self.app.api(route) as response:
                        original = json.load(response)
                        observed = response.headers["ETag"]
                    self.assertEqual(original, created["value"])
                    for patch, status in (({field: "unguarded"}, 428),):
                        with self.assertRaises(urllib.error.HTTPError) as error:
                            self.app.api(route, patch, method="PATCH")
                        self.assertEqual(error.exception.code, status)
                    for patch in (
                        {"revision": "invented"},
                        {field: None},
                        {field: oversize},
                    ):
                        with self.assertRaises(urllib.error.HTTPError) as error:
                            self.app.api(
                                route,
                                patch,
                                method="PATCH",
                                headers={"If-Match": observed},
                            )
                        self.assertIn(error.exception.code, (400, 413))
                    self.assertEqual(self.get(route), original)

                    barrier = threading.Barrier(3)
                    outcomes = []

                    def edit(value):
                        barrier.wait()
                        try:
                            with self.app.api(
                                route,
                                {field: value},
                                method="PATCH",
                                headers={"If-Match": observed},
                            ) as response:
                                outcomes.append((response.status, json.load(response)))
                        except urllib.error.HTTPError as error:
                            outcomes.append((error.code, json.load(error)))

                    threads = [
                        threading.Thread(target=edit, args=(value,))
                        for value in ("first", "second")
                    ]
                    for thread in threads:
                        thread.start()
                    barrier.wait()
                    for thread in threads:
                        thread.join(timeout=10)
                        self.assertFalse(thread.is_alive())
                    self.assertEqual(
                        sorted(status for status, _ in outcomes), [200, 412]
                    )
                    winner = next(
                        body["resource"] for status, body in outcomes if status == 200
                    )
                    self.assertEqual(self.get(route), winner["value"])
                    with self.assertRaises(urllib.error.HTTPError) as error:
                        self.app.api(
                            route, method="DELETE", headers={"If-Match": observed}
                        )
                    self.assertEqual(error.exception.code, 412)
                    self.assertEqual(self.get(route), winner["value"])
                finally:
                    with self.app.api(route) as response:
                        json.load(response)
                        current = response.headers["ETag"]
                    with self.app.api(
                        route, method="DELETE", headers={"If-Match": current}
                    ) as response:
                        self.assertEqual(
                            json.load(response)["id"], created["value"]["id"]
                        )
        self.assertEqual(len(self.provider.requests), before)

    def test_links_validator_does_not_reappear_after_link_and_unlink(self):
        """An old singleton observation stays stale after membership returns."""
        other = self.app.root / "linked-rest-peer"
        other.mkdir()
        own = str(self.app.workspace)
        route = "/extensions/links/groups?" + urllib.parse.urlencode(
            {"workspace": own, "view": "configuration"}
        )
        peer = "/extensions/links/groups?" + urllib.parse.urlencode(
            {"workspace": str(other), "view": "configuration"}
        )
        with self.app.api(route) as response:
            before = json.load(response)
            old = response.headers["ETag"]
        with self.app.api(peer) as response:
            json.load(response)
            peer_etag = response.headers["ETag"]
        with self.app.api(
            route,
            {"other_workspace": str(other), "other_etag": peer_etag},
            headers={"If-Match": old},
        ) as response:
            merged = json.load(response)["resource"]
        self.assertEqual(set(merged["value"]["members"]), {own, str(other)})
        unlink = route + "&" + urllib.parse.urlencode({"member": str(other)})
        with self.app.api(
            unlink, method="DELETE", headers={"If-Match": merged["etag"]}
        ) as response:
            unlinked = json.load(response)["resource"]
        self.assertEqual(unlinked["value"]["members"], before["members"])
        self.assertNotEqual(unlinked["etag"], old)
        with self.app.api(peer) as response:
            json.load(response)
            peer_etag = response.headers["ETag"]
        with self.assertRaises(urllib.error.HTTPError) as error:
            self.app.api(
                route,
                {"other_workspace": str(other), "other_etag": peer_etag},
                headers={"If-Match": old},
            )
        self.assertEqual(error.exception.code, 412)
        self.assertEqual(self.get(route)["members"], before["members"])
