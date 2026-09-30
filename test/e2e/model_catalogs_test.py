"""Provider model lists: each provider's own list reaches the picker and reloads.

Alibaba caches its /models answer for a day, so a model it starts offering
stays out of the picker until that cache ages out; `/reload models` must
refetch it at once through the configured profile's endpoint and key. A
catalog that cannot be fetched (Codex, Antigravity, and Claude are never
signed in here) keeps its previous list: the reload still succeeds and names
it rather than reporting it refreshed. Claude's picker shows whatever the
Anthropic Models API listed, newest first, with the API's own limits and
efforts, so a model released after albedo shipped is offered without an
update. Every list is served on loopback or seeded on disk, so no live network
is reached. The class writes the shared home's list caches and models
settings, so it is exclusive and removes the caches again.
"""

import json
import unittest
import urllib.parse

from harness import Albedo, Provider, exclusive, text

MODELS_CATALOG = {
    "fixture": {
        "id": "fixture",
        "name": "Fixture",
        "models": {
            "fixture-model": {"id": "fixture-model", "limit": {"context": 8000}}
        },
    },
    # Claims efforts the Anthropic API says the model does not take.
    "anthropic": {
        "id": "anthropic",
        "name": "Anthropic",
        "models": {
            "claude-fixture-small": {
                "id": "claude-fixture-small",
                "limit": {"context": 200000, "output": 8000},
                "reasoning_options": [
                    {"type": "effort", "values": ["low", "medium", "high"]}
                ],
            }
        },
    },
}

ALIBABA_MODELS = {"data": [{"id": "qwen-fresh"}, {"id": "qwen-tts-fresh"}]}

# As the Anthropic Models API answered, newest first; neither id is one
# albedo or models.dev knows.
CLAUDE_MODELS = [
    {
        "id": "claude-fixture-6",
        "context": 500000,
        "output": 32000,
        "images": True,
        "efforts": ["low", "high"],
    },
    {
        "id": "claude-fixture-small",
        "context": 200000,
        "output": 8000,
        "images": False,
        "efforts": [],
    },
]


@exclusive
class ModelCatalogReloadTests(unittest.TestCase):
    def setUp(self):
        self.provider = Provider(lambda _request: text("ok"))
        self.addCleanup(self.provider.close)
        self.catalog = Provider(lambda _request: text("ok"), catalog=MODELS_CATALOG)
        self.addCleanup(self.catalog.close)
        self.alibaba = Provider(lambda _request: text("ok"), catalog=ALIBABA_MODELS)
        self.addCleanup(self.alibaba.close)

        def prepare(app):
            # Fresh on disk, so nothing but an explicit reload refetches them.
            (app.home / "alibaba-models.json").write_text(json.dumps(["qwen-stale"]))
            (app.home / "claude-models.json").write_text(json.dumps(CLAUDE_MODELS))
            (app.home / "models.json").unlink(missing_ok=True)
            app.write_extensions({"models": {"url": self.catalog.url + "/models.json"}})

        self.app = Albedo(
            self.provider,
            prepare=prepare,
            providers={
                "fixture": {
                    "baseUrl": self.provider.url,
                    "apiKey": "fixture-key",
                    "model": "fixture-model",
                    "protocol": "chat_completions",
                },
                "fixture-alibaba": {
                    "extension": "alibaba",
                    "baseUrl": self.alibaba.url,
                    "apiKey": "fixture-alibaba-key",
                    "model": "qwen-fresh",
                    "protocol": "chat_completions",
                },
            },
        )
        self.app.__enter__()
        for name in ("alibaba-models.json", "claude-models.json"):
            self.addCleanup((self.app.home / name).unlink, missing_ok=True)
        self.addCleanup(self.app.__exit__, None, None, None)

    def listed(self, provider, query=""):
        with self.app.api(f"/models/{provider}{query}") as response:
            return json.load(response)

    def reload(self, target):
        session = self.app.session()
        with self.app.api(
            f"/sessions/{session}/commands",
            {"name": "/reload", "args": {"target": target}},
        ) as response:
            return json.load(response)["result"]

    def alibaba_listed(self):
        endpoint = urllib.parse.quote(self.alibaba.url, safe="")
        return self.listed("alibaba", f"?endpoint={endpoint}")

    def test_reload_models_refetches_provider_lists_and_names_failures(self):
        self.assertEqual(self.alibaba_listed(), ["qwen-stale"])
        outcome = self.reload("models")
        catalogs = outcome["catalogs"]
        self.assertIn("alibaba", catalogs["reloaded"])
        self.assertIn("models", catalogs["reloaded"])
        self.assertEqual({"codex", "antigravity", "claude"}, set(catalogs["failed"]))
        self.assertIn("claude (", outcome["message"])
        # The non-chat entitlement stays filtered, as on any other fetch.
        self.assertEqual(self.alibaba_listed(), ["qwen-fresh"])
        # A failed reload keeps the list it had.
        self.assertEqual(
            self.listed("claude"), ["claude-fixture-6", "claude-fixture-small"]
        )

    def test_claude_picker_offers_the_api_list_with_its_facts(self):
        self.reload("models")
        newest, small = self.listed("claude", "?details=1")
        self.assertEqual(
            [newest["id"], small["id"]], ["claude-fixture-6", "claude-fixture-small"]
        )
        self.assertEqual(
            (newest["context"], newest["output"], newest["efforts"]),
            (500000, 32000, ["low", "high"]),
        )
        # No effort listed means the model takes none, not a guessed default.
        self.assertEqual(small["efforts"], [])
