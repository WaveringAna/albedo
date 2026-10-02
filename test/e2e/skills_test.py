"""Installed skills follow package symlinks and keep resource bases across reloads."""

import json
import os
import shutil
import unittest

from harness import Albedo, Provider, python, text


class SkillSymlinkTests(unittest.TestCase):
    def setUp(self):
        self.code = ""
        self.provider = Provider(self.reply)
        self.addCleanup(self.provider.close)
        self.app = Albedo(self.provider, protocol="responses")
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)
        self.external = self.app.root / f"packages-{self.app.workspace.name}"
        self.external.mkdir()
        self.addCleanup(shutil.rmtree, self.external)
        self.installed = self.app.workspace / ".agents/skills"
        self.installed.mkdir(parents=True)
        self.session = self.app.session()
        self.route = f"/sessions/{self.session}/catalog"

    def reply(self, request):
        if request["input"][-1].get("type") == "function_call_output":
            return text("done")
        return python(self.code) if self.code else text("ok")

    def request(self, path, body=None):
        with self.app.api(path, body) as response:
            return json.load(response)

    def skill(self, directory, name, body="INSTRUCTIONS"):
        directory.mkdir(parents=True, exist_ok=True)
        source = directory / "SKILL.md"
        source.write_text(f"---\nname: {name}\ndescription: {name}\n---\n{body}\n")
        return source

    def reload(self):
        self.request(
            f"/sessions/{self.session}/commands",
            {"name": "/reload", "args": {"target": "session"}},
        )

    def probe(self, code):
        self.code = code + "\nprint('SKILL_PROBE_OK')"
        before = len(self.provider.requests)
        self.app.prompt(self.session, "probe installed skills").close()
        self.app.idle(self.session)
        requests = [item["request"] for item in self.provider.requests[before:]]
        output = next(
            item["output"]
            for item in reversed(requests[-1]["input"])
            if item.get("type") == "function_call_output"
        )
        self.assertIn("SKILL_PROBE_OK", output, output)
        return requests[0]

    def test_external_directory_links_discover_activate_and_read_resources(self):
        for name, relative in [("absolute", False), ("relative", True)]:
            source = self.skill(
                self.external / f"hash-{name}-package", name, f"BODY_{name}"
            )
            link = self.installed / name
            target = (
                os.path.relpath(source.parent, link.parent)
                if relative
                else source.parent
            )
            link.symlink_to(target, target_is_directory=True)
            (source.parent / "reference.txt").write_text(f"REFERENCE_{name}")
        catalog = self.request(self.route)
        for name in ("absolute", "relative"):
            row = next(row for row in catalog["candidates"] if row["title"] == name)
            self.assertEqual(row["source"], str(self.installed / name / "SKILL.md"))
            self.assertEqual(
                row["resolved_source"],
                str((self.installed / name / "SKILL.md").resolve()),
            )
        self.reload()
        request = self.probe(
            "for name in ['absolute', 'relative']:\n"
            "    activation = await commands.invoke('/' + name)\n"
            "    assert 'BODY_' + name in activation['instructions'], activation\n"
            f"    assert activation['source'] == {str(self.installed)!r} + '/' + name + '/SKILL.md', activation\n"
            "    resources = await skills.resources(name)\n"
            "    assert 'reference.txt' in resources.resources, resources\n"
            "    page = await skills.read(name, resource='reference.txt')\n"
            "    assert page.content == 'REFERENCE_' + name, page"
        )
        for name in ("absolute", "relative"):
            self.assertIn(
                str(self.installed / name / "SKILL.md"), request["instructions"]
            )

    def test_linked_instructions_keep_installed_siblings_and_follow_resource_links(
        self,
    ):
        source = self.skill(self.external / "hash-instructions", "file-linked")
        renamed = source.with_name("package-instructions.md")
        source.rename(renamed)
        source = renamed
        directory = self.installed / "file-linked"
        directory.mkdir()
        (directory / "SKILL.md").symlink_to(source)
        (directory / "local.txt").write_text("INSTALLED_SIBLING")
        (source.parent / "local.txt").write_text("WRONG_TARGET_SIBLING")
        resources = self.external / "hash-resources"
        resources.mkdir()
        (resources / "reference.txt").write_text("LINKED_RESOURCE")
        (resources / "cycle").symlink_to(resources, target_is_directory=True)
        (directory / "references").symlink_to(resources, target_is_directory=True)
        (directory / "other-references").symlink_to(resources, target_is_directory=True)
        (directory / "asset.txt").symlink_to(
            os.path.relpath(resources / "reference.txt", directory)
        )
        self.reload()
        self.probe(
            "activation = await commands.invoke('/file-linked')\n"
            f"assert activation['source'] == {str(directory / 'SKILL.md')!r}, activation\n"
            "resources = await skills.resources('file-linked')\n"
            "assert set(resources.resources) == {'SKILL.md', 'local.txt', 'asset.txt', 'references/reference.txt', 'other-references/reference.txt'}, resources\n"
            "assert (await skills.read('file-linked', resource='local.txt')).content == 'INSTALLED_SIBLING'\n"
            "assert (await skills.read('file-linked', resource='references/reference.txt')).content == 'LINKED_RESOURCE'\n"
            "assert (await skills.read('file-linked', resource='asset.txt')).content == 'LINKED_RESOURCE'\n"
            "for path in ['../SKILL.md', '/etc/passwd']:\n"
            "    try:\n"
            "        await skills.read('file-linked', resource=path)\n"
            "        assert False, path\n"
            "    except SkillsError:\n"
            "        pass"
        )

        replacement = self.external / "replacement-resource.txt"
        replacement.write_text("UPDATED_RESOURCE")
        (directory / "asset.txt").unlink()
        (directory / "asset.txt").symlink_to(replacement)
        self.probe(
            "assert (await skills.read('file-linked', resource='asset.txt')).content == 'UPDATED_RESOURCE'"
        )

    def test_changed_selections_require_reload(self):
        for change in ("directory", "instructions", "replacement"):
            with self.subTest(change=change):
                name = f"pinned-{change}"
                first = self.skill(self.external / f"first-{change}", name)
                installed = self.installed / name
                if change == "instructions":
                    installed.mkdir()
                    link = installed / "SKILL.md"
                    link.symlink_to(first)
                else:
                    link = installed
                    link.symlink_to(first.parent, target_is_directory=True)
                (installed / "resource.txt").write_text("FIRST_RESOURCE")
                self.reload()
                initial = self.request(self.route)

                if change == "replacement":
                    replacement = first.with_name("replacement.md")
                    replacement.write_bytes(first.read_bytes())
                    replacement.replace(first)
                    expected_resource = "FIRST_RESOURCE"
                    current = first
                else:
                    current = self.skill(self.external / f"second-{change}", name)
                    link.unlink()
                    if change == "directory":
                        link.symlink_to(current.parent, target_is_directory=True)
                        (current.parent / "resource.txt").write_text("SECOND_RESOURCE")
                        expected_resource = "SECOND_RESOURCE"
                    else:
                        link.symlink_to(current)
                        expected_resource = "FIRST_RESOURCE"
                self.assertNotEqual(
                    initial["revision"], self.request(self.route)["revision"]
                )
                self.probe(
                    f"for operation in [lambda: commands.invoke('/' + {name!r}), lambda: skills.resources({name!r}), lambda: skills.read({name!r})]:\n"
                    "    try:\n"
                    "        await operation()\n"
                    "        assert False, 'changed selection must require reload'\n"
                    "    except (CommandsError, SkillsError) as error:\n"
                    "        assert 'reload' in str(error).lower(), error"
                )
                self.reload()
                self.probe(
                    f"assert 'INSTRUCTIONS' in (await commands.invoke('/' + {name!r}))['instructions']\n"
                    f"assert (await skills.read({name!r}, resource='resource.txt')).content == {expected_resource!r}"
                )
                current.write_text(
                    current.read_text().replace("INSTRUCTIONS", "NEW_BODY")
                )
                self.probe(
                    f"assert 'NEW_BODY' in (await commands.invoke('/' + {name!r}))['instructions']"
                )
