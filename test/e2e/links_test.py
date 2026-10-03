"""Linked workspaces: one project in several places.

A workspace linked with another reads that one's memory and work items as
well as its own, while everything it writes is filed under itself. A member
whose folder is gone keeps what it had until the user removes it, and
unlinking deletes nothing.
"""

import json
import re
import shutil
import unittest
import urllib.error
import urllib.parse

from harness import Albedo, Provider, python, text


class LinkTests(unittest.TestCase):
    def setUp(self):
        self.cells = []

        def script(request):
            if request["input"][-1].get("role") == "user" and self.cells:
                return python(self.cells.pop(0))
            return text("ok")

        self.provider = Provider(script)
        self.addCleanup(self.provider.close)
        self.app = Albedo(self.provider, protocol="responses")
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)

    def cell(self, session, code):
        self.cells.append(code)
        self.app.prompt(session, "run it").close()
        self.app.idle(session)
        results = [
            json.loads(part["value"])
            for entry in self.app.history(session)["items"]
            if entry["kind"] == "tool_result" and entry["tool"]["name"] == "python"
            for part in entry["content"]
            if part["kind"] == "json" and part["field"] == "result"
        ]
        self.assertEqual(results[-1]["status"], "ok", results[-1])
        return results[-1]

    def group(self, workspace):
        query = urllib.parse.urlencode({"workspace": str(workspace)})
        with self.app.api(f"/extensions/links/groups?{query}") as response:
            return json.load(response)

    def merge(self, workspace, other):
        group = self.group(workspace)["configuration_resource"]
        other_group = self.group(other)["configuration_resource"]
        with self.app.api(
            group["url"],
            {"other_workspace": str(other), "other_etag": other_group["etag"]},
            headers={"If-Match": group["etag"]},
        ) as response:
            return json.load(response)

    def unlink(self, workspace, member):
        group = self.group(workspace)["configuration_resource"]
        with self.app.api(
            group["url"] + "&" + urllib.parse.urlencode({"member": str(member)}),
            method="DELETE",
            headers={"If-Match": group["etag"]},
        ) as response:
            return json.load(response)

    def memory_file(self, workspace):
        slug = re.sub(r"[^A-Za-z0-9]", "-", str(workspace))
        return self.app.home / "memories" / slug / "memory.md"

    def test_linked_workspaces_read_each_other_and_write_their_own(self):
        laptop, server = self.app.root / "laptop", self.app.root / "server"
        laptop.mkdir()
        server.mkdir()
        first = self.app.session(laptop)
        self.cell(
            first,
            "memory.append('the cache key is the prefix hash')\n"
            "await work.create('ship the picker')",
        )

        self.app.session(server)
        added = self.merge(server, laptop)
        self.assertEqual(
            set(added["resource"]["value"]["members"]), {str(server), str(laptop)}
        )
        group = self.group(server)
        self.assertEqual(
            set(group["configuration_resource"]["value"]["members"]),
            {str(server), str(laptop)},
        )

        # A session opened after the link starts with the linked memory and
        # is told it is linked.
        later = self.app.session(server)
        read = self.cell(
            later,
            "memory.append('chernobog runs the gate')\n"
            "await work.create('profile the gate')\n"
            "print(memory.grep('cache key'))\n"
            "print(sorted((i.title, i.workspace) for i in await work.list()))",
        )
        self.assertIn(
            "[" + str(laptop) + "] memory.md:1: the cache key", read["output"]
        )
        self.assertIn(f"('ship the picker', '{laptop}')", read["output"])
        self.assertIn(f"('profile the gate', '{server}')", read["output"])
        instructions = self.provider.requests[-1]["request"]["instructions"]
        self.assertIn("the cache key is the prefix hash", instructions)
        self.assertIn("This workspace is linked with " + str(laptop), instructions)
        # Writes stayed where they were made.
        self.assertEqual(
            self.memory_file(server).read_text(), "chernobog runs the gate\n"
        )
        self.assertEqual(
            self.memory_file(laptop).read_text(), "the cache key is the prefix hash\n"
        )

        # The laptop checkout goes away: it is shown as gone and still read.
        shutil.rmtree(laptop)
        presence = {item["workspace"]: item for item in self.group(server)["presence"]}
        self.assertEqual(presence[str(laptop)]["exists"], False)
        kept = self.cell(later, "print(memory.grep('cache key'))")
        self.assertIn("the cache key", kept["output"])

        # Removing it stops the reads and deletes nothing.
        self.unlink(server, laptop)
        self.assertEqual(
            self.group(server)["configuration_resource"]["value"]["members"],
            [str(server)],
        )
        alone = self.cell(
            later,
            "print(memory.grep('cache key'))\n"
            "print([i.title for i in await work.list()])",
        )
        self.assertNotIn("the cache key", alone["output"])
        self.assertNotIn("ship the picker", alone["output"])
        self.assertTrue(self.memory_file(laptop).exists())

    def test_open_sessions_in_the_group_are_told_with_the_memory_they_now_read(self):
        laptop, server = self.app.root / "desk", self.app.root / "rack"
        laptop.mkdir()
        server.mkdir()
        on_laptop = self.app.session(laptop)
        self.cell(on_laptop, "memory.append('the cache key is the prefix hash')")
        here, beside = self.app.session(server), self.app.session(server)
        self.cell(here, "1")
        self.cell(beside, "1")

        added = self.merge(server, laptop)
        self.assertEqual(added["notification_count"], 3)
        self.assertEqual(
            {item["session_id"] for item in added["notifications"]},
            {on_laptop, here, beside},
        )
        self.assertTrue(
            all(
                item["notification"]["state"] == "queued"
                for item in added["notifications"]
            )
        )

        def next_request(session):
            self.app.prompt(session, "hi").close()
            self.app.idle(session)
            request = self.provider.requests[-1]["request"]
            return json.dumps(request["input"]), request["instructions"]

        # Sessions in this workspace opened before the link: the laptop's
        # memory arrives in the note, not in a rebuilt prompt.
        for session in (here, beside):
            told, instructions = next_request(session)
            self.assertIn("linked this workspace with " + str(laptop), told)
            self.assertIn("the cache key is the prefix hash", told)
            self.assertNotIn("the cache key", instructions)
        told, _ = next_request(on_laptop)
        self.assertIn("linked this workspace with " + str(server), told)
        # A session created after the link starts with the linked memory.
        unopened = self.app.session(server)
        told, instructions = next_request(unopened)
        self.assertNotIn("linked this workspace", told)
        self.assertIn("the cache key is the prefix hash", instructions)

        self.unlink(server, laptop)
        told, _ = next_request(on_laptop)
        self.assertIn("unlinked this workspace from " + str(server), told)
        told, _ = next_request(beside)
        self.assertIn("The user unlinked " + str(laptop), told)

    def test_a_link_is_refused_for_this_workspace_and_missing_folders(self):
        workspace = self.app.root / "alone"
        workspace.mkdir()
        self.app.session(workspace)
        for details, status, code in (
            (str(workspace), 409, "already_linked"),
            (str(self.app.root / "nowhere"), 400, "invalid_request"),
        ):
            with self.assertRaises(urllib.error.HTTPError) as refused:
                self.merge(workspace, details)
            self.assertEqual(refused.exception.code, status)
            self.assertEqual(json.load(refused.exception)["code"], code)
        self.assertEqual(
            self.group(workspace)["configuration_resource"]["value"]["members"],
            [str(workspace)],
        )


if __name__ == "__main__":
    unittest.main()
