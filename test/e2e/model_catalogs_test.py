"""`/reload models` refetches each provider's own model list, not only models.dev.

Alibaba caches its /models answer for a day, so a model it starts offering
stays out of the picker until that cache ages out; the reload must refetch it
at once through the configured profile's endpoint and key. A catalog that
cannot be fetched (Codex and Antigravity are never signed in here) keeps its
previous list: the reload still succeeds and names it rather than reporting it
refreshed. Every list is served on loopback, so no live network is reached. It
writes the shared home's Alibaba cache and models settings, so the class is
exclusive and removes the cache again.
"""
import json
import unittest
import urllib.parse

from harness import Albedo, Provider, exclusive, text

MODELS_CATALOG = {"fixture": {
    "id": "fixture", "name": "Fixture",
    "models": {"fixture-model": {"id": "fixture-model",
                                 "limit": {"context": 8000}}},
}}

ALIBABA_MODELS = {"data": [{"id": "qwen-fresh"}, {"id": "qwen-tts-fresh"}]}


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
            # Fresh on disk, so nothing but an explicit reload refetches it.
            (app.home / "alibaba-models.json").write_text(json.dumps(["qwen-stale"]))
            (app.home / "extensions.json").write_text(json.dumps({
                "models": {"url": self.catalog.url + "/models.json",
                           "refreshHours": 0},
                "cacheTtl": {"url": None},
            }))

        self.app = Albedo(self.provider, prepare=prepare, providers={
            "fixture": {"baseUrl": self.provider.url, "apiKey": "fixture-key",
                        "model": "fixture-model", "protocol": "chat_completions"},
            "fixture-alibaba": {"extension": "alibaba", "baseUrl": self.alibaba.url,
                                "apiKey": "fixture-alibaba-key", "model": "qwen-fresh",
                                "protocol": "chat_completions"},
        })
        self.app.__enter__()
        self.addCleanup((self.app.home / "alibaba-models.json").unlink, missing_ok=True)
        self.addCleanup(self.app.__exit__, None, None, None)

    def listed(self):
        endpoint = urllib.parse.quote(self.alibaba.url, safe="")
        with self.app.api(f"/models/alibaba?endpoint={endpoint}") as response:
            return json.load(response)

    def test_reload_models_refetches_provider_lists_and_names_failures(self):
        self.assertEqual(self.listed(), ["qwen-stale"])
        session = self.app.session()
        with self.app.api(f"/sessions/{session}/commands",
                          {"name": "/reload", "args": {"target": "models"}}) as response:
            outcome = json.load(response)["result"]
        catalogs = outcome["catalogs"]
        self.assertIn("alibaba", catalogs["reloaded"])
        self.assertIn("models", catalogs["reloaded"])
        self.assertEqual({"codex", "antigravity"}, set(catalogs["failed"]))
        self.assertIn("codex (", outcome["message"])
        self.assertNotIn("alibaba", catalogs["failed"])
        # The non-chat entitlement stays filtered, as on any other fetch.
        self.assertEqual(self.listed(), ["qwen-fresh"])


if __name__ == "__main__":
    unittest.main()
