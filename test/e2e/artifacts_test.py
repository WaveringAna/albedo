"""Artifacts: the agent makes and revises a web page from a cell, both clients
learn of it from the cell's trace, its pages are served through the frame
routes with the bridge, the page's storage and failures reach the agent, and
the artifact outlives its session. See robot-docs/artifacts.md."""

import json
import unittest
import urllib.error

from harness import Albedo, Provider, latest_user, python, text

PAGE = (
    "<!doctype html><html><HEAD lang=en><title>timeline</title></HEAD>"
    "<body><p>hé</p><script src='app.js'></script></body></html>"
)

# Each prompt is the cell the scripted model runs for it; `{id}` is the
# artifact the test made first.
CELLS = {
    "make": "a = await artifacts.create('release timeline', files={'index.html': PAGE, 'app.js': 'console.log(1)', 'img/dot.bin': bytes(range(256)), 'notes/a note.txt': 'hi'})\nprint(json.dumps(a))",
    "revise script": "a = await artifacts.update(ID, files={'app.js': 'console.log(2)', 'img/dot.bin': None})\nprint(json.dumps(a))",
    "revise page": "a = await artifacts.update(ID, '<p>second page</p>', title='release timeline, revised')\nprint(json.dumps({**a, 'page': await artifacts.read(ID), 'first': (await artifacts.get(ID, 1)).files}))",
    "read back": "print(json.dumps({'state': await artifacts.state(ID), 'errors': await artifacts.errors(ID), 'mine': [a.id for a in await artifacts.list(session='current')]}))",
    "refused": """for make in (
    lambda: artifacts.create('built', files={'index.html': '<script src="/assets/app.js"></script>'}),
    lambda: artifacts.create('x' * 201, '<p>hi</p>'),
    lambda: artifacts.update(ID, files={'gone.js': None}),
):
    try:
        await make()
    except Exception as error:
        print(type(error).__name__, error)""",
}


class ArtifactsTest(unittest.TestCase):
    def setUp(self):
        self.artifact = ""

        def script(request):
            last = request["messages"][-1]
            prompt = latest_user(request)
            if last.get("role") == "user" and prompt in CELLS:
                prelude = f"import json\nPAGE = {PAGE!r}\nID = {self.artifact!r}\n"
                return python(prelude + CELLS[prompt])
            return text("done")

        self.provider = Provider(script)
        self.addCleanup(self.provider.close)
        self.app = Albedo(self.provider)
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)

    def run_cell(self, session, prompt):
        """The cell's printed output and the trace it left."""
        self.app.prompt(session, prompt).close()
        self.app.idle(session)
        tool = [
            entry
            for entry in self.app.history(session)["items"]
            if entry["kind"] == "tool_result"
        ][-1]
        result = next(
            json.loads(part["value"])
            for part in tool["content"]
            if part["kind"] == "json" and part["field"] == "result"
        )
        self.assertEqual(result["status"], "ok", result)
        trace = next(
            (part["trace"] for part in tool["content"] if part["kind"] == "trace"),
            {"activities": []},
        )
        return result["output"].strip(), trace

    def get(self, path, headers=None):
        with self.app.api(path, headers=headers) as response:
            return response.status, dict(response.getheaders()), response.read()

    def refused(self, path, method=None, body=None):
        try:
            self.app.api(path, body, method=method).close()
        except urllib.error.HTTPError as error:
            return error.code
        self.fail(f"{path} was served")

    def post_text(self, path, body):
        connection = self.app.daemon._connection()
        connection.request(
            "POST",
            path,
            body.encode(),
            {
                "Authorization": "Bearer " + connection.token,
                "Content-Type": "text/plain;charset=UTF-8",
            },
        )
        response = connection.getresponse()
        response.read()
        return response.status

    def test_an_artifact_is_made_revised_served_and_kept(self):
        session = self.app.session()
        output, trace = self.run_cell(session, "make")
        made = json.loads(output)
        self.artifact = made["id"]
        self.assertRegex(self.artifact, r"^[a-z0-9]{12}$")
        self.assertEqual(made["version"], 1)
        self.assertEqual(made["title"], "release timeline")
        self.assertEqual(
            [a for a in trace["activities"] if a["kind"] == "artifact"],
            [
                {
                    "kind": "artifact",
                    "target": "release timeline",
                    "artifact": {"id": self.artifact, "version": 1},
                }
            ],
        )

        status, _, body = self.get(f"/extensions/artifacts/items?session={session}")
        listed = json.loads(body)["items"]
        self.assertEqual([item["id"] for item in listed], [self.artifact])
        item = listed[0]
        self.assertRegex(item["key"], r"^[0-9a-f]{32}$")
        self.assertFalse(item["session_deleted"])
        self.assertEqual(item["entry"], "index.html")
        frame = f"/extensions/artifacts/frame/{self.artifact}.{item['key']}"

        # The entry page gets the bridge right after its head opens, in the
        # page's own bytes; other files are served as they are, for good.
        status, headers, page = self.get(frame + "/1/")
        self.assertEqual(status, 200)
        self.assertTrue(headers["content-type"].startswith("text/html"))
        self.assertTrue(
            page.startswith(
                b"<!doctype html><html><HEAD lang=en><script>window.__albedo="
            )
        )
        self.assertIn("hé".encode(), page)
        self.assertIn(b"window.albedo", page)
        status, headers, script = self.get(frame + "/1/app.js")
        self.assertEqual(script, b"console.log(1)")
        self.assertTrue(headers["content-type"].startswith("text/javascript"))
        self.assertIn("immutable", headers["cache-control"])
        self.assertEqual(self.get(frame + "/1/img/dot.bin")[2], bytes(range(256)))
        self.assertEqual(self.get(frame + "/1/notes/a%20note.txt")[2], b"hi")
        for path in [
            f"/extensions/artifacts/frame/{self.artifact}.{'0' * 32}/1/",
            frame + "/2/",
            frame + "/1/missing.js",
            frame + "/1/.albedo/state",
        ]:
            with self.subTest(path=path):
                self.assertEqual(self.refused(path), 404, path)

        # files= changes only what it names; the first version stays as it was.
        output, trace = self.run_cell(session, "revise script")
        self.assertEqual(json.loads(output)["version"], 2)
        self.assertEqual(self.get(frame + "/2/app.js")[2], b"console.log(2)")
        self.assertEqual(self.refused(frame + "/2/img/dot.bin"), 404)
        self.assertEqual(self.get(frame + "/1/app.js")[2], b"console.log(1)")

        output, trace = self.run_cell(session, "revise page")
        revised = json.loads(output)
        self.assertEqual(revised["version"], 3)
        self.assertEqual(revised["title"], "release timeline, revised")
        self.assertEqual(revised["page"], "<p>second page</p>")
        self.assertEqual(
            revised["first"],
            {
                "app.js": 14,
                "img/dot.bin": 256,
                "index.html": len(PAGE.encode()),
                "notes/a note.txt": 2,
            },
        )
        self.assertEqual(
            [a["artifact"] for a in trace["activities"] if a["kind"] == "artifact"],
            [{"id": self.artifact, "version": 3}],
        )
        # A page without a head still gets the bridge first.
        self.assertTrue(self.get(frame + "/3/index.html")[2].startswith(b"<script>"))

        # What the page saves and what breaks in it reach the agent.
        self.assertEqual(
            self.post_text(frame + "/3/.albedo/state", json.dumps({"seats": "8"})), 204
        )
        self.assertEqual(
            self.post_text(
                frame + "/3/.albedo/errors",
                json.dumps({"message": "x is not defined", "line": 4}),
            ),
            204,
        )
        self.assertEqual(self.post_text(frame + "/3/.albedo/state", "[1]"), 400)
        self.assertIn(b'\\"seats\\":\\"8\\"', self.get(frame + "/3/")[2])
        output, _ = self.run_cell(session, "read back")
        back = json.loads(output)
        self.assertEqual(back["state"], {"seats": "8"})
        self.assertEqual(
            [(e["message"], e["line"], e["version"]) for e in back["errors"]],
            [("x is not defined", 4, 3)],
        )
        self.assertEqual(back["mine"], [self.artifact])

        # Refusals say what to do, and leave the artifact as it was.
        output, _ = self.run_cell(session, "refused")
        built, titled, removed = output.splitlines()
        self.assertIn("relative paths", built)
        self.assertIn("at most 200 characters", titled)
        self.assertIn("gone.js is not a file", removed)

        status, _, body = self.get(f"/extensions/artifacts/items/{self.artifact}")
        detail = json.loads(body)
        self.assertEqual([v["version"] for v in detail["history"]], [3, 2, 1])
        self.assertEqual(detail["versions"], 3)

        # Deleting the session leaves the artifact, marked as from a deleted
        # session; deleting the artifact removes it and its pages.
        resource = f"/sessions/{session}?view=configuration"
        with self.app.api(resource) as response:
            validator = response.getheader("ETag")
            response.read()
        self.app.api(resource, method="DELETE", headers={"If-Match": validator}).close()
        item = json.loads(self.get("/extensions/artifacts/items")[2])["items"]
        mine = [entry for entry in item if entry["id"] == self.artifact][0]
        self.assertTrue(mine["session_deleted"])
        self.assertIsNone(mine["session_name"])
        self.assertEqual(self.get(frame + "/1/app.js")[2], b"console.log(1)")
        with self.app.api(
            f"/extensions/artifacts/items/{self.artifact}", method="DELETE"
        ) as response:
            self.assertEqual(response.status, 204)
        self.assertEqual(
            self.refused(f"/extensions/artifacts/items/{self.artifact}"), 404
        )
        self.assertEqual(self.refused(frame + "/1/app.js"), 404)


if __name__ == "__main__":
    unittest.main()
