"""Read-only context inspection against actual model requests and catalog data."""

import json
import unittest
import urllib.error
from urllib.parse import urlencode

from harness import Albedo, Provider, exclusive, Reply, text


SECRET = "credential-must-never-appear-in-inspector"
CATALOG = {
    "fixture-cloud": {
        "id": "fixture-cloud",
        "name": "Fixture Cloud",
        "env": ["FIXTURE_API_KEY"],
        "api": "http://127.0.0.1/v1",
        "models": {
            "fixture": {
                "id": "fixture",
                "limit": {"context": 200000, "output": 8000},
                "modalities": {"input": ["text"]},
            }
        },
    }
}


# exclusive: replaces the global models catalog and asserts catalog resolution
@exclusive
class ContextTest(unittest.TestCase):
    def setUp(self):
        def reply(request):
            if "without provider usage" in json.dumps(request):
                return Reply("text", "done", usage=None)
            return text("done", usage={"input_tokens": 20, "output_tokens": 1})

        self.provider = Provider(reply, catalog=CATALOG)
        self.addCleanup(self.provider.close)

        def prepare(app):
            (app.home / "models.json").unlink(missing_ok=True)
            app.write_extensions(
                {
                    "models": {
                        "url": self.provider.url + "/models.json",
                        "refreshHours": 24,
                    }
                }
            )

        self.app = Albedo(
            self.provider,
            protocol="responses",
            prepare=prepare,
            providers={
                "fixture": {
                    "baseUrl": self.provider.url + "/v1",
                    "apiKey": SECRET,
                    "model": "fixture",
                    "protocol": "responses",
                },
            },
        )
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)
        self.session = self.app.session()
        self.route = f"/sessions/{self.session}/context"

    def read(self, route):
        with self.app.api(route) as response:
            return json.load(response)

    def turn(self, message):
        self.app.prompt(self.session, message).close()
        self.app.idle(self.session)

    def test_pending_inspection_is_read_only_and_snapshot_matches_request(self):
        pending = self.read(self.route)
        self.assertEqual(pending["state"], "pending")
        self.assertIsNone(pending["snapshot_id"])
        self.assertEqual(set(pending["reason"]), {"code", "detail"})
        self.assertEqual(pending["reason"]["code"], "context_pending")
        self.assertIsInstance(pending["reason"]["detail"], str)
        self.assertTrue(pending["reason"]["detail"].strip())
        self.assertLessEqual(len(pending["reason"]["detail"]), 4096)
        self.assertEqual(self.provider.requests, [])
        self.turn("inspect exact composition")
        self.assertEqual(len(self.provider.requests), 1)
        sent = self.provider.requests[0]["request"]
        snapshot = self.read(self.route)
        self.assertEqual(snapshot["state"], "ready")
        self.assertIsNone(snapshot["reason"])
        self.assertEqual(
            (snapshot["provider"], snapshot["model"]), ("fixture", "fixture")
        )
        self.assertEqual(snapshot["context_window_tokens"], 200000)
        compaction = snapshot["compaction"]
        self.assertEqual(compaction["provider_input_tokens"], 20)
        self.assertIsNone(compaction["provider_cached_input_tokens"])
        self.assertEqual(
            compaction["estimate_method"],
            "local byte-based estimate; not provider token usage",
        )
        self.assertEqual(compaction["status"], "not_needed")
        self.assertEqual(compaction["input_limit_tokens"], 200000)
        self.assertEqual(compaction["trigger_free_percent"], 20)
        self.assertIn("fixture-cloud", compaction["source"])
        self.assertIn("models.dev catalog", compaction["source"])
        self.assertIn("<extension-context", sent["instructions"])
        self.assertNotIn("<extension-context", json.dumps(sent["input"]))
        self.assertTrue(
            all(
                section["preview"]["text"]
                and len(section["preview"]["text"].encode()) <= 1024
                for section in snapshot["sections"]
            )
        )
        self.assertNotIn(SECRET, json.dumps(snapshot))

        pages = {}
        for section in snapshot["sections"]:
            parts = [
                self.read(
                    self.route
                    + "?"
                    + urlencode(
                        {
                            "view": "section",
                            "snapshot_id": snapshot["snapshot_id"],
                            "section_id": section["id"],
                            "page": page,
                        }
                    )
                )
                for page in range(section["page_count"])
            ]
            self.assertTrue(all(len(part["text"].encode()) <= 32768 for part in parts))
            self.assertTrue(
                all(part["snapshot_id"] == snapshot["snapshot_id"] for part in parts)
            )
            pages[section["id"]] = "".join(part["text"] for part in parts)
        self.assertEqual(pages["instructions"], sent["instructions"])
        self.assertEqual(json.loads(pages["tools"]), sent["tools"])
        self.assertIn("inspect exact composition", pages["history"])
        self.assertNotIn(SECRET, json.dumps(pages))
        self.assertEqual(len(self.provider.requests), 1)

    def test_combining_marks_cannot_make_context_pages_unbounded(self):
        message = "a" + "\u0301" * 20000
        self.turn(message)
        session = self.read(f"/sessions/{self.session}?tail=0")
        listed = next(
            item
            for item in self.read("/sessions")["items"]
            if item["id"] == self.session
        )
        for representation in (session, listed):
            for field in ("name", "automatic_name"):
                self.assertTrue(representation[field].startswith("a"))
                self.assertLessEqual(len(representation[field]), 4096)
        resource = session["configuration_resource"]
        configuration = self.read(resource["url"])
        self.assertEqual(configuration, resource["value"])
        self.assertIsNone(configuration["name"])
        self.assertEqual(listed["name"], session["name"])
        self.assertEqual(listed["automatic_name"], session["automatic_name"])
        snapshot = self.read(self.route)
        history = next(
            section for section in snapshot["sections"] if section["id"] == "history"
        )
        parts = []
        for page in range(history["page_count"]):
            part = self.read(
                self.route
                + "?"
                + urlencode(
                    {
                        "view": "section",
                        "snapshot_id": snapshot["snapshot_id"],
                        "section_id": "history",
                        "page": page,
                    }
                )
            )
            self.assertLessEqual(len(part["text"]), 8000)
            self.assertLessEqual(len(part["text"].encode()), 32000)
            parts.append(part["text"])
        self.assertGreater(len(parts), 1)
        self.assertIn(message, "".join(parts))

    def test_usage_absence_model_selection_and_unknown_catalog_model(self):
        self.turn("without provider usage")
        compaction = self.read(self.route)["compaction"]
        self.assertIsNone(compaction["provider_input_tokens"])
        self.assertIsNotNone(compaction["estimated_input_tokens"])
        resource = self.read(f"/sessions/{self.session}")["configuration_resource"]
        with self.app.api(
            resource["url"],
            {"model": "changed-model"},
            method="PATCH",
            headers={"If-Match": resource["etag"]},
        ) as response:
            changed = json.load(response)
        self.assertEqual(changed["session"]["model"], "changed-model")
        pending = self.read(self.route)
        self.assertEqual(pending["state"], "pending")
        self.assertIsNone(pending["snapshot_id"])
        self.assertEqual(len(self.provider.requests), 1)
        self.turn("a model outside the catalog")
        unknown = self.read(self.route)
        self.assertIsNone(unknown["context_window_tokens"])
        self.assertEqual(unknown["compaction"]["status"], "unknown")


class ContextReplayTest(unittest.TestCase):
    def test_inspection_preserves_replay_and_replaces_prior_request_for_both_protocols(
        self,
    ):
        for protocol in ("responses", "chat_completions"):
            with self.subTest(protocol=protocol):
                opaque = "opaque-replay-must-only-reach-provider"
                if protocol == "responses":
                    replay = {
                        "type": "reasoning",
                        "id": "fixed-reasoning",
                        "summary": [],
                        "encrypted_content": opaque,
                    }
                    message = {
                        "type": "message",
                        "role": "assistant",
                        "content": [{"type": "output_text", "text": "first answer"}],
                    }
                    initial = Reply(
                        "raw",
                        events=[
                            {
                                "type": "response.completed",
                                "response": {
                                    "id": "fixed-response",
                                    "status": "completed",
                                    "output": [replay, message],
                                    "usage": {
                                        "input_tokens": 31,
                                        "output_tokens": 2,
                                        "input_tokens_details": {"cached_tokens": 9},
                                    },
                                },
                            }
                        ],
                    )
                else:
                    replay = {
                        "role": "assistant",
                        "content": "first answer",
                        "reasoning_content": opaque,
                    }
                    initial = Reply(
                        "raw",
                        events=[
                            {
                                "id": "fixed-chat",
                                "choices": [
                                    {"index": 0, "delta": replay, "finish_reason": None}
                                ],
                            },
                            {
                                "id": "fixed-chat",
                                "choices": [
                                    {"index": 0, "delta": {}, "finish_reason": "stop"}
                                ],
                                "usage": {
                                    "prompt_tokens": 31,
                                    "completion_tokens": 2,
                                    "prompt_tokens_details": {"cached_tokens": 9},
                                },
                            },
                        ],
                    )

                def reply(request):
                    inputs = request.get("input", request.get("messages", []))
                    users = [item for item in inputs if item.get("role") == "user"]
                    return (
                        initial
                        if len(users) == 1
                        else Reply("text", "later answer", usage=None)
                    )

                provider = Provider(reply)
                try:
                    with Albedo(provider, protocol=protocol) as app:
                        session = app.session()
                        route = f"/sessions/{session}/context"

                        def inspect():
                            with app.api(route) as response:
                                summary = json.load(response)
                            contents = {}
                            for section in summary.get("sections", []):
                                parts = []
                                for index in range(section["page_count"]):
                                    with app.api(
                                        route
                                        + "?"
                                        + urlencode(
                                            {
                                                "view": "section",
                                                "snapshot_id": summary["snapshot_id"],
                                                "section_id": section["id"],
                                                "page": index,
                                            }
                                        )
                                    ) as response:
                                        parts.append(json.load(response)["text"])
                                contents[section["id"]] = "".join(parts)
                            return summary, contents

                        app.prompt(session, "first request").close()
                        app.idle(session)
                        first, pages = inspect()
                        self.assertNotIn("first answer", pages["history"])
                        self.assertNotIn(opaque, json.dumps((first, pages)))
                        self.assertEqual(len(provider.requests), 1)
                        app.prompt(session, "replacement request").close()
                        app.idle(session)
                        second, pages = inspect()
                        with self.assertRaises(urllib.error.HTTPError) as obsolete:
                            app.api(
                                route
                                + "?"
                                + urlencode(
                                    {
                                        "view": "section",
                                        "snapshot_id": first["snapshot_id"],
                                        "section_id": first["sections"][0]["id"],
                                        "page": 0,
                                    }
                                )
                            )
                        self.assertEqual(obsolete.exception.code, 410)
                        self.assertEqual(
                            json.load(obsolete.exception)["code"], "context_changed"
                        )
                        self.assertIn("replacement request", pages["history"])
                        self.assertNotIn("later answer", pages["history"])
                        self.assertNotIn(opaque, json.dumps((second, pages)))
                        sent = provider.requests[-1]["request"]
                        inputs = sent.get("input", sent.get("messages", []))
                        self.assertIn(replay, inputs)
                        self.assertEqual(len(provider.requests), 2)
                        inspect()
                        self.assertEqual(len(provider.requests), 2)
                finally:
                    provider.close()
