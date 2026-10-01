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


@exclusive
class ModelCatalogSelectionTests(unittest.TestCase):
    """Disputed gateway facts must not borrow one provider's larger limits."""

    def setUp(self):
        self.provider = Provider(lambda _request: text("ok"))
        self.addCleanup(self.provider.close)
        catalog = {
            "openai": {
                "api": "https://api.openai.example/v1",
                "models": {
                    "shared-model": {
                        "id": "shared-model",
                        "limit": {"context": 400000, "output": 8000},
                        "modalities": {"input": ["text", "image", "pdf"]},
                        "reasoning_options": [
                            {"type": "effort", "values": ["low", "medium", "high"]}
                        ],
                    }
                },
            },
            "mirror": {
                "api": "https://mirror.example/v1",
                "models": {
                    "shared-model": {
                        "id": "shared-model",
                        "limit": {"context": 200000, "output": 16000},
                        "modalities": {"input": ["image", "text"]},
                        "reasoning_options": [
                            {"type": "effort", "values": ["medium", "high"]}
                        ],
                    },
                    "vendor/qualified-model": {
                        "id": "vendor/qualified-model",
                        "limit": {"context": 32000},
                    },
                },
            },
            "unknown": {
                "models": {
                    "shared-model": {
                        "id": "shared-model",
                        "limit": {"context": None, "output": 0},
                    }
                }
            },
        }

        def prepare(app):
            (app.home / "models.json").write_text(json.dumps(catalog))
            (app.home / "models.json.index").unlink(missing_ok=True)
            app.write_extensions({"models": {"refreshHours": 0}})

        self.app = Albedo(self.provider, prepare=prepare)
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)

    def listed(self, provider, endpoint=""):
        query = urllib.parse.urlencode({"endpoint": endpoint, "details": "1"})
        with self.app.api(f"/models/{provider}?{query}") as response:
            return json.load(response)

    def test_gateway_uses_smallest_limits_and_shared_reported_capabilities(self):
        gateway = "https://gateway.example/v1"
        [shared] = self.listed("openai", gateway)
        self.assertEqual(shared["context"], 200000)
        self.assertEqual(shared["output"], 8000)
        self.assertEqual(shared["input"], ["image", "text"])
        self.assertEqual(shared["efforts"], ["medium", "high"])
        self.assertEqual(self.listed("openai"), [shared])
        # The reduced index must give the same answer after a daemon restart.
        self.assertTrue((self.app.home / "models.json.index").exists())
        self.app.restart()
        self.assertEqual(self.listed("openai", gateway), [shared])

    def test_endpoint_selects_provider_facts_and_model_list(self):
        listed = self.listed("openai", "https://MIRROR.example/other-path")
        self.assertEqual(
            [item["id"] for item in listed],
            ["shared-model", "vendor/qualified-model"],
        )
        shared, qualified = listed
        self.assertEqual(shared["context"], 200000)
        self.assertEqual(shared["output"], 16000)
        self.assertEqual(shared["input"], ["image", "text"])
        self.assertEqual(qualified["context"], 32000)
        # ChatGPT has no matching API host in models.dev; it uses OpenAI identity.
        [subscription] = self.listed("openai", "https://chatgpt.com/backend-api")
        self.assertEqual(subscription["context"], 400000)
        self.assertEqual(subscription["output"], 8000)
        self.assertEqual(subscription["input"], ["text", "image", "pdf"])
        self.assertEqual(subscription["efforts"], ["low", "medium", "high"])

    def test_known_reasoning_models_keep_empty_catalog_efforts(self):
        catalog = {
            "openai": {
                "models": {
                    "o3-disjoint": {
                        "id": "o3-disjoint",
                        "reasoning_options": [{"type": "effort", "values": ["low"]}],
                    },
                    "o3-empty": {"id": "o3-empty"},
                }
            },
            "mirror": {
                "models": {
                    "o3-disjoint": {
                        "id": "o3-disjoint",
                        "reasoning_options": [{"type": "effort", "values": ["high"]}],
                    }
                }
            },
        }
        (self.app.home / "models.json").write_text(json.dumps(catalog))
        self.app.restart()
        listed = self.listed("openai", "https://gateway.example/v1")
        self.assertEqual([item["id"] for item in listed], ["o3-disjoint", "o3-empty"])
        self.assertEqual([item["efforts"] for item in listed], [[], []])
        self.app.restart()
        self.assertEqual(self.listed("openai"), listed)

    def test_efforts_are_inferred_only_for_a_model_absent_from_a_valid_catalog(self):
        with self.app.api(
            "/sessions",
            {"workspace": str(self.app.workspace), "model": "o3-unlisted"},
        ) as response:
            session = json.load(response)["id"]
        with self.app.api(
            f"/sessions/{session}/commands", {"name": "/effort"}
        ) as response:
            self.assertEqual(
                json.load(response)["result"]["available"], ["low", "medium", "high"]
            )
        # A corrupt catalog cannot establish that the model is absent.
        (self.app.home / "models.json").write_text("{")
        self.app.restart()
        with self.app.api(
            "/sessions",
            {"workspace": str(self.app.workspace), "model": "o3-unlisted"},
        ) as response:
            self.assertIsNone(json.load(response)["effort"])
