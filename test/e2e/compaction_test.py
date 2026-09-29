"""Image tool outputs reach the model, and compaction reclaims the ones it evicts."""

import hashlib
import json
import sqlite3
import unittest

from harness import Albedo, Provider, error, exclusive, python, text


PNG = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAAD"
SHOWN = "iVBORw0KGgoAAAANSUhEUgAAABEAAAAD"
UPLOADED = "iVBORw0KGgoAAAANSUhEUgAAABIAAAAD"
MARKER = "image elided and is no longer available"


class ImageToolOutputTest(unittest.TestCase):
    def test_python_image_is_attached_and_invalid_image_is_reported(self):
        def reply(request):
            inputs = request["input"]
            if inputs[-1].get("type") == "function_call_output":
                return text("done")
            user = next(
                item["content"]
                for item in reversed(inputs)
                if item.get("role") == "user"
            )
            if user == "show a valid image":
                return python(
                    "import base64\nshow_image(base64.b64decode('" + PNG + "'))"
                )
            return python("show_image(b'\\x89PNG\\r\\n\\x1a\\nnot a header')")

        def tool_output(provider):
            inputs = provider.requests[-1]["request"]["input"]
            return next(
                item for item in inputs if item.get("type") == "function_call_output"
            )

        provider = Provider(reply)
        try:
            with Albedo(provider, protocol="responses") as app:
                session = app.session()
                app.prompt(session, "show a valid image").close()
                app.idle(session)
                output = tool_output(provider)
                self.assertIn("attached image/png", json.dumps(output))
                request = provider.requests[-1]["request"]
                self.assertIn(PNG, json.dumps(request))

                second = app.session()
                app.prompt(second, "show an invalid image").close()
                app.idle(second)
                output = tool_output(provider)
                self.assertIn("image_errors", json.dumps(output))
                self.assertNotIn(PNG, json.dumps(output))
        finally:
            provider.close()

    def test_compaction_elides_evicted_tool_images_only(self):
        def reply(request):
            inputs = request["input"]
            user = next(
                (
                    str(item.get("content", ""))
                    for item in reversed(inputs)
                    if item.get("role") == "user"
                ),
                "",
            )
            if "<newly-evicted-history>" in user:
                return text("older conversation summary")
            if inputs[-1].get("type") != "function_call_output" and user == "show":
                return python(
                    "show_image(__import__('base64').b64decode('" + SHOWN + "'))"
                )
            return text("done")

        provider = Provider(reply)
        try:
            with Albedo(provider, protocol="responses") as app:
                shown = hashlib.sha256(SHOWN.encode()).hexdigest()
                uploaded = hashlib.sha256(UPLOADED.encode()).hexdigest()
                database = f"file:{app.home / 'albedo.sqlite'}?mode=ro"

                def converse(sid, prompts):
                    for prompt in prompts:
                        app.prompt(sid, prompt).close()
                        app.idle(sid)
                    with app.api(
                        f"/sessions/{sid}/commands", {"name": "/compact"}
                    ) as response:
                        self.assertTrue(json.load(response)["result"]["started"])
                    app.idle(sid)

                def rows(sid, table, needle):
                    with sqlite3.connect(database, uri=True) as db:
                        return db.execute(
                            f"SELECT count(*) FROM {table} WHERE session=? "
                            "AND instr(payload, CAST(? AS BLOB))>0",
                            (sid, needle),
                        ).fetchone()[0]

                old = app.session()
                app.api(
                    f"/sessions/{old}/events",
                    {
                        "content": "keep this upload",
                        "image": {
                            "mimeType": "image/png",
                            "data": UPLOADED,
                            "width": 18,
                            "height": 3,
                            "bytes": 24,
                        },
                    },
                ).close()
                app.idle(old)
                converse(old, ["show", "second", "third", "fourth"])
                self.assertEqual(rows(old, "transcript", shown), 0)
                self.assertEqual(rows(old, "cells", shown), 0)
                self.assertEqual(rows(old, "transcript", MARKER), 1)
                self.assertEqual(rows(old, "cells", MARKER), 1)
                self.assertEqual(rows(old, "transcript", uploaded), 1)
                with sqlite3.connect(database, uri=True) as db:
                    stored = {row[0] for row in db.execute("SELECT hash FROM images")}
                self.assertNotIn(shown, stored)
                self.assertIn(uploaded, stored)
                app.prompt(old, "after compaction").close()
                app.idle(old)
                self.assertIn(
                    "older conversation summary",
                    json.dumps(provider.requests[-1]["request"]["input"]),
                )

                recent = app.session()
                converse(recent, ["first", "second", "third", "show"])
                self.assertEqual(rows(recent, "transcript", shown), 1)
                self.assertEqual(rows(recent, "cells", shown), 1)
                self.assertEqual(rows(recent, "cells", SHOWN), 0)
        finally:
            provider.close()

    @exclusive
    def test_automatic_compaction_elides_evicted_tool_images(self):
        fail_summary = True
        attempts = []
        cleaned_before_request = []

        def reply(request):
            inputs = request["input"]
            user = next(
                (
                    str(item.get("content", ""))
                    for item in reversed(inputs)
                    if item.get("role") == "user"
                ),
                "",
            )
            if "<newly-evicted-history>" in user:
                attempts.append(fail_summary)
                if fail_summary:
                    return error(400, "summary refused")
                return text("older conversation summary")
            if "[older conversation summary;" in json.dumps(inputs):
                cleaned_before_request.append(
                    (rows("transcript", MARKER), rows("cells", MARKER))
                )
                return error(400, "provider refused after committed compaction")
            if inputs[-1].get("type") != "function_call_output" and user == "show":
                return python(
                    "show_image(__import__('base64').b64decode('" + SHOWN + "'))"
                )
            return text("done")

        provider = Provider(reply)
        try:
            with Albedo(provider, protocol="responses") as app:
                settings_path = app.home / "extensions.json"
                original = settings_path.read_text()

                def restore():
                    settings_path.write_text(original)
                    app.restart()

                self.addCleanup(restore)
                settings = json.loads(original)
                settings["rolling"] = {"contextWindowTokens": 50000}
                settings_path.write_text(json.dumps(settings))
                app.restart()
                session = app.session()
                shown = hashlib.sha256(SHOWN.encode()).hexdigest()
                database = f"file:{app.home / 'albedo.sqlite'}?mode=ro"

                def rows(table, needle):
                    with sqlite3.connect(database, uri=True) as db:
                        return db.execute(
                            f"SELECT count(*) FROM {table} WHERE session=? "
                            "AND instr(payload, CAST(? AS BLOB))>0",
                            (session, needle),
                        ).fetchone()[0]

                app.prompt(session, "show").close()
                app.idle(session)
                self.assertEqual(rows("transcript", shown), 1)
                self.assertEqual(rows("cells", shown), 1)
                pad = "history " * 8000
                for prompt in (pad, pad, pad):
                    app.prompt(session, prompt).close()
                    app.idle(session)
                self.assertTrue(
                    attempts, "the automatic trigger must attempt compaction"
                )
                self.assertEqual(rows("transcript", shown), 1)
                self.assertEqual(rows("cells", shown), 1)
                fail_summary = False
                app.prompt(session, "retry compaction").close()
                app.idle(session)
                self.assertTrue(
                    cleaned_before_request, "expected a post-compaction request"
                )
                self.assertTrue(all(pair == (1, 1) for pair in cleaned_before_request))
                self.assertEqual(rows("transcript", shown), 0)
                self.assertEqual(rows("cells", shown), 0)
                self.assertEqual(rows("transcript", MARKER), 1)
                self.assertEqual(rows("cells", MARKER), 1)
                summaries = len(attempts)
                app.prompt(session, "after compaction").close()
                app.idle(session)
                self.assertEqual(
                    len(attempts), summaries, "reuse the committed summary"
                )
                self.assertIn(
                    "older conversation summary",
                    json.dumps(provider.requests[-1]["request"]["input"]),
                )
        finally:
            provider.close()
