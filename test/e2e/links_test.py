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
            json.loads(event["result"])
            for event in self.app.events(session)
            if event.get("type") == "tool" and event.get("name") == "python"
        ]
        self.assertEqual(results[-1]["status"], "ok", results[-1])
        return results[-1]

    def link(self, session, **args):
        with self.app.api(
            f"/sessions/{session}/commands", {"name": "/link", "args": args}
        ) as response:
            return json.load(response)["result"]

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

        here = self.app.session(server)
        added = self.link(here, action="add", details=str(laptop))
        self.assertIn("linked with " + str(laptop), added["message"])
        rows = self.link(here)["page"]["rows"]
        self.assertEqual(
            [(row["id"], row["badge"]) for row in rows],
            [(str(server), "here"), (str(laptop), "")],
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
        rows = self.link(here)["page"]["rows"]
        self.assertEqual(rows[1]["badge"], "gone")
        kept = self.cell(later, "print(memory.grep('cache key'))")
        self.assertIn("the cache key", kept["output"])

        # Removing it stops the reads and deletes nothing.
        self.link(here, action="remove", details=str(laptop))
        self.assertEqual(self.link(here)["page"]["rows"], [])
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
        self.cell(beside, "1")
        unopened = self.app.session(server)

        added = self.link(here, action="add", details=str(laptop))
        self.assertIn("told 3 open sessions", added["message"])

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
        # One that never opened composes its snapshot when it does.
        told, instructions = next_request(unopened)
        self.assertNotIn("linked this workspace", told)
        self.assertIn("the cache key is the prefix hash", instructions)

        self.link(here, action="remove", details=str(laptop))
        told, _ = next_request(on_laptop)
        self.assertIn("unlinked this workspace from " + str(server), told)
        told, _ = next_request(beside)
        self.assertIn("The user unlinked " + str(laptop), told)

    def test_a_link_is_refused_for_this_workspace_and_missing_folders(self):
        workspace = self.app.root / "alone"
        workspace.mkdir()
        session = self.app.session(workspace)
        for details, reason in (
            (str(workspace), "that is this workspace"),
            (str(self.app.root / "nowhere"), "must be an existing absolute directory"),
        ):
            with self.assertRaises(urllib.error.HTTPError) as refused:
                self.link(session, action="add", details=details)
            self.assertIn(reason, refused.exception.read().decode())
        self.assertEqual(self.link(session)["page"]["rows"], [])


if __name__ == "__main__":
    unittest.main()
