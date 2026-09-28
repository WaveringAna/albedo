"""Project memories survive sessions and can be recalled without scanning the workspace."""

import json
import re
import unittest

from harness import Albedo, Provider, python, text


class MemoryTests(unittest.TestCase):
    def test_project_memory_and_journal_are_searchable_and_loaded_into_new_sessions(
        self,
    ):
        def script(request):
            last = request["input"][-1]
            if last.get("role") == "user" and "save notes" in str(last.get("content")):
                return python(
                    "memory.save('Prefer narrow adapters for VioletStore.\\n')\n"
                    "memory.append('VioletStore supports durable receipts')\n"
                    "memory.journal('Fixed VioletStore receipt replay')\n"
                    "print(memory.read())\n"
                    "print(memory.grep('receipt'))\n"
                    "print(memory.search('receipts'))\n"
                    "print(memory.search('replay'))"
                )
            return text("done")

        provider = Provider(script)
        self.addCleanup(provider.close)
        with Albedo(provider, protocol="responses") as app:
            workspace = app.root / "MiXeD-workspace"
            workspace.mkdir()
            first = app.session(workspace)
            app.prompt(first, "save notes").close()
            app.idle(first)
            output = next(
                json.loads(event["result"])["output"]
                for event in app.events(first)
                if event.get("type") == "tool" and event.get("name") == "python"
            )
            self.assertIn("memory.md:3:", output)
            self.assertRegex(output, r"journal/\d{4}-\d{2}-\d{2}\.md:1:")
            self.assertIn("VioletStore supports durable receipts", output)
            slug = re.sub(r"[^A-Za-z0-9]", "-", str(workspace))
            root = app.home / "memories" / slug
            self.assertIn(slug, [entry.name for entry in root.parent.iterdir()])
            self.assertEqual(
                (root / "memory.md").read_text(),
                "Prefer narrow adapters for VioletStore.\n\n"
                "VioletStore supports durable receipts\n",
            )
            second = app.session(workspace)
            app.prompt(second, "what do we know?").close()
            app.idle(second)
            instructions = provider.requests[-1]["request"]["instructions"]
            self.assertIn("Prefer narrow adapters for VioletStore", instructions)
            self.assertIn("memory.search", instructions)
            other = app.root / "other-workspace"
            other.mkdir()
            isolated = app.session(workspace=other)
            app.prompt(isolated, "what do we know?").close()
            app.idle(isolated)
            instructions = provider.requests[-1]["request"]["instructions"]
            self.assertNotIn("Prefer narrow adapters for VioletStore", instructions)
