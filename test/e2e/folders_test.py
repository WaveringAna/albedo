"""Workspace directory and preview resources preserve real filesystem and VCS facts.

What the picker shows comes from real directories, git and jj run by the
daemon with its own environment, so the checks are end to end: a plain tree,
a git repository (branch, changes, detached HEAD), a colocated jj repository
(jj wins, bookmarks, and browsing never writes a jj operation), linguist
shares, and path validation. The jj cases skip when jj is not installed.
"""

from datetime import datetime
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import urllib.error
import urllib.parse

from harness import Albedo, exclusive

GIT_ENV = {
    "GIT_AUTHOR_NAME": "fixture",
    "GIT_AUTHOR_EMAIL": "fixture@example.com",
    "GIT_COMMITTER_NAME": "fixture",
    "GIT_COMMITTER_EMAIL": "fixture@example.com",
    "JJ_USER": "fixture",
    "JJ_EMAIL": "fixture@example.com",
}


def sh(cwd, *args):
    return subprocess.run(
        args,
        cwd=cwd,
        env=dict(os.environ, **GIT_ENV),
        check=True,
        capture_output=True,
        text=True,
    ).stdout


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


class FoldersTest(unittest.TestCase):
    def setUp(self):
        self.app = Albedo().__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)
        directory = (
            Path("/var/tmp")
            if self._testMethodName
            == "test_plain_tree_lists_directories_and_previews_two_levels"
            else self.app.root
        )
        self.root = Path(tempfile.mkdtemp(prefix="albedo-folders-", dir=directory))
        self.addCleanup(shutil.rmtree, self.root, True)

    def get(self, location, *, preview=False):
        query = {"location": str(location)}
        if preview:
            query["include"] = "preview"
        with self.app.api("/workspaces?" + urllib.parse.urlencode(query)) as response:
            return json.load(response)

    def failure(self, location, *, preview=False):
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self.get(location, preview=preview)
        return caught.exception.code, json.load(caught.exception)

    @exclusive
    def test_plain_tree_lists_directories_and_previews_two_levels(self):
        for name in ("beta", "Alpha", ".hidden", "gamma/one", "gamma/two"):
            (self.root / name).mkdir(parents=True)
        for name in "abcdef":
            (self.root / "gamma" / f"{name}.py").write_text("x = 1\n")
        (self.root / "notes.txt").write_text("not a directory\n")
        (self.root / "zeta").symlink_to(self.root / "beta")

        listed = self.get(f"{self.root}/./gamma/../")
        self.assertEqual(listed["directory"], str(self.root))
        self.assertIsNone(listed["next"])
        self.assertEqual(
            [(e["name"], e["hidden"], e["vcs"]) for e in listed["items"]],
            [
                (".hidden", True, None),
                ("Alpha", False, None),
                ("beta", False, None),
                ("gamma", False, None),
                ("zeta", False, None),
            ],
        )
        modified = datetime.fromisoformat(
            listed["items"][1]["modified_at"].replace("Z", "+00:00")
        )
        self.assertAlmostEqual(
            modified.timestamp(), (self.root / "Alpha").stat().st_mtime, delta=1
        )

        preview = self.get(self.root, preview=True)["preview"]
        self.assertIsNone(preview["repository"])
        self.assertEqual(preview["languages"], [])
        self.assertEqual(preview["more"], 0)
        self.assertEqual(
            [(e["name"], e["kind"]) for e in preview["tree"]],
            [
                ("Alpha", "directory"),
                ("beta", "directory"),
                ("gamma", "directory"),
                ("zeta", "symlink"),
                ("notes.txt", "file"),
            ],
        )
        gamma = preview["tree"][2]
        self.assertEqual(
            [c["name"] for c in gamma["children"]], ["one", "two", "a.py", "b.py"]
        )
        self.assertEqual(gamma["more"], 4)
        self.assertNotIn("children", gamma["children"][0])
        self.assertEqual(gamma["children"][2]["language"], "Python")
        self.assertEqual(preview["tree"][4]["language"], "Text")

    def test_git_repository_reports_branch_changes_and_detached_head(self):
        repo = self.root / "project"
        write(repo / "src" / "main.go", "package main\n" * 30)
        write(repo / "src" / "util.go", "package main\n" * 30)
        write(repo / "script.py", "print(1)\n" * 10)
        write(repo / "data.json", "{}\n" * 500)
        write(repo / ".gitignore", "build/\n")
        sh(repo, "git", "init", "-q", "-b", "trunk")
        sh(repo, "git", "add", ".")
        sh(repo, "git", "commit", "-q", "-m", "one")
        write(repo / "src" / "main.go", "package main // edited\n")
        write(repo / "src" / "new.go", "package main\n")
        write(repo / "build" / "out.o", "ignored\n")
        commit = sh(repo, "git", "rev-parse", "--short", "HEAD").strip()

        self.assertEqual(self.get(self.root)["items"][0]["vcs"], "git")
        found = self.get(repo / "src", preview=True)["preview"]["repository"]
        self.assertEqual(
            {
                key: found[key]
                for key in ("kind", "root", "branch", "revision", "changed")
            },
            {
                "kind": "git",
                "root": str(repo),
                "branch": "trunk",
                "revision": commit,
                "changed": 2,
            },
        )

        preview = self.get(repo, preview=True)["preview"]
        self.assertEqual(preview["repository"], found)
        # JSON is data, so only Go and Python count, largest first.
        self.assertEqual(
            [language["name"] for language in preview["languages"]], ["Go", "Python"]
        )
        self.assertAlmostEqual(
            sum(language["share"] for language in preview["languages"]), 1.0
        )
        tree = {e["name"]: e for e in preview["tree"]}
        # Inside a repository only tracked or changed paths show: the
        # ignored build/ stays out, the untracked src/new.go is there.
        self.assertEqual(list(tree), ["src", "data.json", "script.py"])
        self.assertEqual(tree["src"]["changed"], 2)
        self.assertEqual(
            {c["name"]: c["changed"] for c in tree["src"]["children"]},
            {"main.go": 1, "new.go": 1, "util.go": 0},
        )
        self.assertEqual(tree["script.py"]["changed"], 0)

        sh(repo, "git", "checkout", "-q", "--detach")
        self.assertIsNone(
            self.get(repo, preview=True)["preview"]["repository"]["branch"]
        )

    def test_unborn_git_repository_has_no_commit(self):
        repo = self.root / "fresh"
        repo.mkdir()
        sh(repo, "git", "init", "-q", "-b", "main")
        (repo / "draft.md").write_text("# draft\n")
        found = self.get(repo, preview=True)["preview"]["repository"]
        self.assertEqual(
            {
                key: found[key]
                for key in (
                    "kind",
                    "root",
                    "branch",
                    "revision",
                    "changed",
                    "touched_at",
                )
            },
            {
                "kind": "git",
                "root": str(repo),
                "branch": "main",
                "revision": None,
                "changed": 1,
                "touched_at": None,
            },
        )

    @unittest.skipUnless(shutil.which("jj"), "jj is not installed")
    def test_colocated_jj_repository_wins_without_writing_an_operation(self):
        repo = self.root / "colocated"
        repo.mkdir()
        sh(repo, "jj", "git", "init", "--colocate")
        write(repo / "lib" / "core.gleam", "pub fn main() { Nil }\n")
        sh(repo, "jj", "commit", "-m", "one")
        sh(repo, "jj", "bookmark", "create", "main", "-r", "@-")
        write(repo / "lib" / "more.gleam", "pub fn more() { Nil }\n")
        sh(repo, "jj", "commit", "-m", "two")
        write(repo / "lib" / "core.gleam", "pub fn main() { 1 }\n")
        sh(repo, "jj", "status")
        change = sh(
            repo, "jj", "log", "-r", "@", "--no-graph", "-T", "change_id.shortest(4)"
        ).strip()
        # Not yet snapshotted, so jj does not know it and the tree leaves it
        # out; a browse that snapshotted would record an operation.
        write(repo / "lib" / "later.gleam", "pub fn later() { Nil }\n")
        operations = self.operations(repo)

        self.assertEqual(self.get(self.root)["items"][0]["vcs"], "jj")
        found = self.get(repo / "lib", preview=True)["preview"]["repository"]
        self.assertEqual(found["kind"], "jj")
        self.assertEqual(found["root"], str(repo))
        self.assertEqual(found["change_id"], change)
        self.assertEqual(found["bookmark"], {"name": "main", "ahead": 2})
        self.assertEqual(found["changed"], 1)
        self.assertIsInstance(found["touched_at"], str)
        datetime.fromisoformat(found["touched_at"].replace("Z", "+00:00"))

        preview = self.get(repo, preview=True)["preview"]
        self.assertEqual(preview["repository"], found)
        self.assertEqual(
            [
                (language["name"], language["share"])
                for language in preview["languages"]
            ],
            [("Gleam", 1.0)],
        )
        lib = preview["tree"][0]
        self.assertEqual((lib["name"], lib["changed"]), ("lib", 1))
        self.assertEqual(
            {c["name"]: c["changed"] for c in lib["children"]},
            {"core.gleam": 1, "more.gleam": 0},
        )

        self.assertEqual(self.operations(repo), operations)

        # A bookmark that moved on without @ still names @'s line of work,
        # rather than an older backup behind @.
        def log(rev):
            return sh(
                repo, "jj", "log", "-r", rev, "--no-graph", "-T", "change_id"
            ).strip()

        two, one = log("@-"), log("@--")
        sh(repo, "jj", "bookmark", "create", "backup/old", "-r", one)
        sh(repo, "jj", "new", two, "-m", "side")
        sh(repo, "jj", "bookmark", "set", "main", "-r", "@")
        sh(repo, "jj", "edit", change)
        self.assertEqual(
            self.get(repo, preview=True)["preview"]["repository"]["bookmark"],
            {"name": "main", "ahead": 1},
        )

    @staticmethod
    def operations(repo):
        return sh(
            repo,
            "jj",
            "op",
            "log",
            "--no-graph",
            "--ignore-working-copy",
            "-T",
            'id ++ "\\n"',
        )

    def test_paths_expand_home_and_refuse_the_rest(self):
        home = self.app.root / "user-home"
        listed = self.get("~")
        self.assertEqual((listed["directory"], listed["home"]), (str(home), str(home)))
        self.assertEqual(self.get("~/")["directory"], str(home))

        (self.root / "file.txt").write_text("x\n")
        for preview in (False, True):
            self.assertEqual(self.failure("relative/dir", preview=preview)[0], 400)
            self.assertEqual(self.failure("~someone", preview=preview)[0], 400)
            self.assertEqual(self.failure("", preview=preview)[0], 400)
            code, body = self.failure(self.root / "missing", preview=preview)
            self.assertEqual(code, 404)
            self.assertEqual(body["status"], 404)
            self.assertEqual(
                self.failure(self.root / "file.txt", preview=preview)[0], 404
            )
