"""Management discovery must predict runtime selection without loading context."""

import json
import os
import unittest
import urllib.error

from harness import Albedo, Provider, exclusive, text


@exclusive
class CatalogTest(unittest.TestCase):
    def setUp(self):
        self.provider = Provider(lambda _request: text("ok"))
        self.addCleanup(self.provider.close)
        self.app = Albedo(self.provider, protocol="responses")
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)
        self.session = self.app.session()
        self.route = f"/sessions/{self.session}/catalog"

    def request(self, path, body=None):
        with self.app.api(path, body) as response:
            return json.load(response)

    def write_skill(self, base, name, description):
        path = base / name / "SKILL.md"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f"---\nname: {name}\ndescription: {description}\n---\nbody\n")
        return path

    def reload(self):
        self.request(
            f"/sessions/{self.session}/commands",
            {"name": "/reload", "args": {"target": "session"}},
        )

    def test_rejected_and_shadowed_candidates_do_not_hide_valid_runtime_winners(self):
        high = self.app.workspace / ".albedo/skills"
        low = self.app.workspace / ".agents/skills"
        malformed = self.write_skill(high, "fallback", "invalid")
        malformed.write_text("---\nname: [\ndescription: bad\n---\n")
        fallback = self.write_skill(low, "fallback", "LOWER_WINNER")
        mismatch = self.write_skill(high, "mismatch", "invalid")
        mismatch.write_text("---\nname: other\ndescription: bad\n---\n")
        oversized = self.write_skill(high, "oversized", "invalid")
        oversized.write_text("x" * (1048576 + 1))
        winner = self.write_skill(high, "duplicate", "HIGHER_WINNER")
        shadowed = self.write_skill(low, "duplicate", "SHADOWED_DESCRIPTION")
        target = self.write_skill(high / "container", "linked", "LINKED_WINNER")
        (high / "linked").symlink_to(target.parent, target_is_directory=True)

        catalog = self.request(self.route)
        by_source = {row["source"]: row for row in catalog["candidates"]}
        for path in (malformed, mismatch, oversized):
            row = by_source[str(path)]
            self.assertFalse(row["valid"])
            self.assertTrue(row["diagnostic"])
            self.assertFalse(row["eligible"])
        self.assertTrue(by_source[str(fallback)]["eligible"])
        self.assertTrue(by_source[str(winner)]["eligible"])
        self.assertTrue(by_source[str(shadowed)]["valid"])
        self.assertFalse(by_source[str(shadowed)]["eligible"])
        self.assertEqual(
            by_source[str(shadowed)]["shadowed_by"], by_source[str(winner)]["id"]
        )
        self.assertNotEqual(
            by_source[str(winner)]["id"], by_source[str(shadowed)]["id"]
        )
        linked = by_source[str(high / "linked/SKILL.md")]
        self.assertTrue(linked["valid"])
        self.assertEqual(linked["resolved_source"], str(target))
        self.reload()
        commands = self.request(f"/sessions/{self.session}/commands")
        descriptions = {row["name"]: row["description"] for row in commands}
        self.assertEqual(descriptions["/fallback"], "LOWER_WINNER")
        self.assertEqual(descriptions["/duplicate"], "HIGHER_WINNER")
        self.assertEqual(descriptions["/linked"], "LINKED_WINNER")
        self.assertTrue({"/mismatch", "/oversized"}.isdisjoint(descriptions))

        self.app.prompt(self.session, "inspect selected skills").close()
        self.app.idle(self.session)
        prompt = self.provider.requests[-1]["request"]["instructions"]
        for description in ("LOWER_WINNER", "HIGHER_WINNER", "LINKED_WINNER"):
            self.assertIn(description, prompt)
        self.assertNotIn("SHADOWED_DESCRIPTION", prompt)

        replacement_target = self.write_skill(
            high / "replacement", "linked", "RETARGETED_WINNER"
        )
        (high / "linked").unlink()
        (high / "linked").symlink_to(
            replacement_target.parent, target_is_directory=True
        )
        retargeted = self.request(self.route)
        self.assertNotEqual(retargeted["revision"], catalog["revision"])
        retargeted_row = next(
            row for row in retargeted["candidates"] if row["id"] == linked["id"]
        )
        self.assertEqual(retargeted_row["resolved_source"], str(replacement_target))
        self.assertEqual(retargeted_row["description"], "RETARGETED_WINNER")

        original_id = by_source[str(malformed)]["id"]
        self.write_skill(high, "fallback", "REPAIRED_WINNER")
        repaired = self.request(self.route)
        self.assertNotEqual(repaired["revision"], catalog["revision"])
        row = next(
            row for row in repaired["candidates"] if row["source"] == str(malformed)
        )
        self.assertEqual(row["id"], original_id)
        self.assertTrue(row["eligible"])
        self.reload()
        self.assertEqual(
            next(
                row["description"]
                for row in self.request(f"/sessions/{self.session}/commands")
                if row["name"] == "/fallback"
            ),
            "REPAIRED_WINNER",
        )

    def test_instruction_links_follow_daemon_policy_and_exclude_system_files(self):
        directory = self.app.workspace / ".agents"
        directory.mkdir()
        external = self.app.root / "external.md"
        external.write_text("LINKED_INSTRUCTION")
        (directory / "linked.md").symlink_to(external)
        (directory / "broken.md").symlink_to(self.app.root / "missing")
        (directory / "directory.md").symlink_to(
            self.app.workspace, target_is_directory=True
        )
        (directory / "SYSTEM.md").write_text("SYSTEM_REPLACEMENT")
        (directory / "APPEND_SYSTEM.md").write_text("SYSTEM_APPEND")
        (directory / "oversized.md").write_text("x" * (1048576 + 1))
        catalog = self.request(self.route)
        instructions = {
            row["title"]: row
            for row in catalog["candidates"]
            if row["kind"] == "instructions"
        }
        self.assertTrue(instructions[".agents/linked.md"]["eligible"])
        oversized = instructions[".agents/oversized.md"]
        self.assertFalse(oversized["valid"])
        self.assertTrue(oversized["diagnostic"])
        self.assertFalse(oversized["eligible"])
        for name in ("broken.md", "directory.md", "SYSTEM.md", "APPEND_SYSTEM.md"):
            self.assertNotIn(f".agents/{name}", instructions)
        self.app.prompt(self.session, "inspect linked instruction").close()
        self.app.idle(self.session)
        self.assertIn(
            "LINKED_INSTRUCTION", self.provider.requests[-1]["request"]["instructions"]
        )

    def test_workspace_move_changes_catalog_without_using_client_workspace(self):
        first = self.write_skill(
            self.app.workspace / ".albedo/skills", "first", "FIRST_WORKSPACE"
        )
        (self.app.workspace / "AGENTS.md").write_text("FIRST_INSTRUCTION")
        other = self.app.root / "other-workspace"
        other.mkdir()
        second = self.write_skill(
            other / ".albedo/skills", "second", "SECOND_WORKSPACE"
        )
        (other / "AGENTS.md").write_text("SECOND_INSTRUCTION")
        before = self.request(self.route)
        self.assertEqual(before["workspace"], str(self.app.workspace))
        self.assertIn(str(first), {row["source"] for row in before["candidates"]})
        self.assertNotIn(str(second), {row["source"] for row in before["candidates"]})
        self.request(f"/sessions/{self.session}/workspace", {"workspace": str(other)})
        after = self.request(self.route)
        self.assertEqual(after["workspace"], str(other))
        self.assertNotEqual(after["revision"], before["revision"])
        self.assertNotIn(str(first), {row["source"] for row in after["candidates"]})
        self.assertIn(str(second), {row["source"] for row in after["candidates"]})
        commands = {
            row["name"] for row in self.request(f"/sessions/{self.session}/commands")
        }
        self.assertIn("/second", commands)
        self.assertNotIn("/first", commands)
        preferences = self.request("/settings")["capabilities"]
        previous = next(
            row for row in before["candidates"] if row["source"] == str(first)
        )
        with self.assertRaises(urllib.error.HTTPError) as failure:
            self.request(
                self.route,
                {
                    "revision": before["revision"],
                    "id": previous["id"],
                    "scope": "session",
                    "enabled": False,
                },
            )
        self.assertEqual(failure.exception.code, 409)
        self.assertEqual(json.load(failure.exception)["code"], "stale_catalog")
        self.assertEqual(self.request("/settings")["capabilities"], preferences)
        self.assertEqual(
            {row["name"] for row in self.request(f"/sessions/{self.session}/commands")},
            commands,
        )

    def test_stale_updates_do_not_write_preferences_or_reload_disk_changes(self):
        skill = self.write_skill(
            self.app.workspace / ".albedo/skills", "stale", "PREPARED_DESCRIPTION"
        )
        self.reload()
        initial = self.request(self.route)
        row = next(
            row for row in initial["candidates"] if row["preference_key"] == "stale"
        )
        body = {
            "revision": initial["revision"],
            "id": row["id"],
            "scope": "session",
            "enabled": False,
        }
        settings_file = self.app.home / "capabilities.json"

        def assert_stale_without_side_effects():
            before = settings_file.read_bytes() if settings_file.exists() else None
            with self.assertRaises(urllib.error.HTTPError) as failure:
                self.request(self.route, body)
            self.assertEqual(failure.exception.code, 409)
            self.assertEqual(json.load(failure.exception)["code"], "stale_catalog")
            self.assertEqual(
                settings_file.read_bytes() if settings_file.exists() else None, before
            )
            commands = self.request(f"/sessions/{self.session}/commands")
            self.assertEqual(
                next(row["description"] for row in commands if row["name"] == "/stale"),
                "PREPARED_DESCRIPTION",
            )

        original_stat = skill.stat()
        original_contents = skill.read_bytes()
        replacement = original_contents.replace(b"body", b"edit")
        self.assertEqual(len(replacement), len(original_contents))
        skill.write_bytes(replacement)
        os.utime(skill, ns=(original_stat.st_atime_ns, original_stat.st_mtime_ns))
        self.assertEqual(skill.stat().st_mtime_ns, original_stat.st_mtime_ns)
        assert_stale_without_side_effects()
        current = self.request(self.route)
        self.assertNotEqual(current["revision"], initial["revision"])
        self.assertEqual(self.request(self.route)["revision"], current["revision"])
        body["revision"] = current["revision"]
        settings_file.write_text(
            json.dumps({"global": {"skills": {"unrelated": False}}})
        )
        assert_stale_without_side_effects()
        body["revision"] = self.request(self.route)["revision"]
        self.request(self.route, body)
        self.assertNotIn(
            "/stale",
            {row["name"] for row in self.request(f"/sessions/{self.session}/commands")},
        )
        acknowledged = next(
            row
            for row in self.request(self.route)["candidates"]
            if row["id"] == body["id"]
        )
        self.assertFalse(acknowledged["session_override"])
        self.assertFalse(acknowledged["eligible"])

        before_extension_change = self.request(self.route)
        body["revision"] = before_extension_change["revision"]
        self.request(
            f"/sessions/{self.session}/extensions", {"name": "skills", "enabled": False}
        )
        disabled = self.request(self.route)
        self.assertFalse(disabled["extensions"]["skills"])
        self.assertNotEqual(disabled["revision"], before_extension_change["revision"])
        before_skills = {
            row["id"]
            for row in before_extension_change["candidates"]
            if row["kind"] == "skills"
        }
        disabled_skills = [
            row for row in disabled["candidates"] if row["kind"] == "skills"
        ]
        self.assertEqual({row["id"] for row in disabled_skills}, before_skills)
        self.assertTrue(all(not row["eligible"] for row in disabled_skills))
        preferences = settings_file.read_bytes()
        commands = self.request(f"/sessions/{self.session}/commands")
        with self.assertRaises(urllib.error.HTTPError) as failure:
            self.request(self.route, body)
        self.assertEqual(failure.exception.code, 409)
        self.assertEqual(json.load(failure.exception)["code"], "stale_catalog")
        self.assertEqual(settings_file.read_bytes(), preferences)
        self.assertEqual(self.request(f"/sessions/{self.session}/commands"), commands)

    def test_instruction_content_change_rejects_stale_save_with_restored_mtime(self):
        instruction = self.app.workspace / "AGENTS.md"
        instruction.write_text("FIRST_INSTRUCTION")
        self.reload()
        initial = self.request(self.route)
        self.assertEqual(self.request(self.route)["revision"], initial["revision"])
        row = next(
            row for row in initial["candidates"] if row["source"] == str(instruction)
        )
        row_id = row["id"]
        preferences = self.request("/settings")["capabilities"]
        original_stat = instruction.stat()
        original_contents = instruction.read_bytes()
        replacement = original_contents.replace(b"FIRST", b"OTHER")
        self.assertEqual(len(replacement), len(original_contents))
        instruction.write_bytes(replacement)
        os.utime(instruction, ns=(original_stat.st_atime_ns, original_stat.st_mtime_ns))
        self.assertEqual(instruction.stat().st_mtime_ns, original_stat.st_mtime_ns)
        with self.assertRaises(urllib.error.HTTPError) as failure:
            self.request(
                self.route,
                {
                    "revision": initial["revision"],
                    "id": row["id"],
                    "scope": "session",
                    "enabled": False,
                },
            )
        self.assertEqual(failure.exception.code, 409)
        self.assertEqual(json.load(failure.exception)["code"], "stale_catalog")
        self.assertEqual(self.request("/settings")["capabilities"], preferences)
        refreshed = self.request(self.route)
        self.assertNotEqual(refreshed["revision"], initial["revision"])
        self.assertEqual(self.request(self.route)["revision"], refreshed["revision"])
        self.assertTrue(
            next(
                row["eligible"]
                for row in refreshed["candidates"]
                if row["id"] == row_id
            )
        )

    def test_session_in_daemon_home_has_unique_rows_and_distinct_instruction_choices(
        self,
    ):
        home = self.app.root / "user-home"
        skill = self.write_skill(home / ".albedo/skills", "home-skill", "HOME_SKILL")
        instruction = home / ".agents/shared.md"
        instruction.parent.mkdir(exist_ok=True)
        instruction.write_text("HOME_INSTRUCTION")
        session = self.app.session(home)
        route = f"/sessions/{session}/catalog"
        catalog = self.request(route)
        ids = [row["id"] for row in catalog["candidates"]]
        self.assertEqual(len(ids), len(set(ids)))
        skills = [row for row in catalog["candidates"] if row["source"] == str(skill)]
        self.assertEqual(sum(row["eligible"] for row in skills), 1)
        commands = self.request(f"/sessions/{session}/commands")
        self.assertEqual(sum(row["name"] == "/home-skill" for row in commands), 1)
        instructions = [
            row for row in catalog["candidates"] if row["source"] == str(instruction)
        ]
        self.assertEqual(
            {row["preference_key"] for row in instructions},
            {"project:.agents/shared.md", "global:~/.agents/shared.md"},
        )
        project = next(
            row for row in instructions if row["preference_key"].startswith("project:")
        )
        self.request(
            route,
            {
                "revision": catalog["revision"],
                "id": project["id"],
                "scope": "session",
                "enabled": False,
            },
        )
        updated = self.request(route)
        instructions = [
            row for row in updated["candidates"] if row["source"] == str(instruction)
        ]
        self.assertFalse(
            next(row["eligible"] for row in instructions if row["id"] == project["id"])
        )
        self.assertTrue(
            next(row["eligible"] for row in instructions if row["id"] != project["id"])
        )
        self.app.prompt(session, "inspect home instruction scopes").close()
        self.app.idle(session)
        self.assertEqual(
            self.provider.requests[-1]["request"]["instructions"].count(
                "HOME_INSTRUCTION"
            ),
            1,
        )
