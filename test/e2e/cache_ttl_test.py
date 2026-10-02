"""The reloadable prompt-cache TTL table: layers, merge precedence, live reload.

The table is daemon-wide state read from files, so this is where its behaviour
is visible: the shipped default served with every entry, lookups resolving
through match order, a local override replacing an entry by id and winning
with a new more-specific one — without a restart — and a malformed file
keeping the last good table. A turn's usage carries the steps its cached
count fades through by that table, which the chat footer counts down from and
which must survive a restart. It writes extensions.json and cache-ttl.json, so
tests that change those layers are exclusive, on a home of their own.
Read-only default lookups and authentication share the daemon without overrides.

The remote layer's fetch is background (like the models catalog's), so the
fixture provider serves the remote table on a loopback URL and the test waits
for it to land; `/reload` fetches it synchronously. No live network is reached.
"""

from typing import Any
import json
import os
import time
import unittest
import urllib.error
import urllib.request

from harness import ROOT, Albedo, Provider, exclusive, text

SHIPPED = json.loads((ROOT / "priv" / "cache-ttl.json").read_text())

# `/reload` fetches the models catalog before the TTL table, so it needs a
# fixture url too — the default would reach the live models.dev.
MODELS_CATALOG = {
    "fixture": {
        "id": "fixture",
        "name": "Fixture",
        "models": {
            "fixture-model": {"id": "fixture-model", "limit": {"context": 8000}}
        },
    }
}

REMOTE_TABLE: dict[str, Any] = {
    "version": 1,
    "entries": [
        # Replaces the shipped deepseek entry by id, in place.
        {
            "id": "deepseek",
            "match": {"host": "api.deepseek.com"},
            "policy": "fixed",
            "clock": "response",
            "evidence": "measured",
            "source": "fixture",
            "note": "remote override",
        },
        # A new id, which goes before every default entry.
        {
            "id": "fixture-gateway",
            "match": {"host": "gateway.fixture"},
            "policy": "evict",
            "survival": {"typical": 600},
            "evidence": "measured",
            "source": "fixture",
            "note": "new remote entry",
        },
    ],
}

LOCAL_OVERRIDE: dict[str, Any] = {
    "version": 1,
    "entries": [
        # Replaces the remote or default deepseek entry by id, in place.
        {
            "id": "deepseek",
            "match": {"host": "api.deepseek.com"},
            "policy": "fixed",
            "clock": "request",
            "evidence": "measured",
            "source": "local",
            "note": "local override",
        },
        # A new id, more specific than anything shipped, which must win.
        {
            "id": "laptop-gateway",
            "match": {"host": "gateway.laptop"},
            "policy": "refresh",
            "tiers": [{"seconds": 600, "write": 1.5}],
            "evidence": "measured",
            "source": "local",
            "note": "new local entry",
        },
    ],
}


def write_atomic(path, payload):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(payload))
    temporary.replace(path)


# exclusive: configures daemon-wide TTL/catalog layers and writes cache files
@exclusive
class CacheTtlTests(unittest.TestCase):
    def setUp(self):
        self.provider = Provider(lambda _request: text("ok"), catalog=REMOTE_TABLE)
        self.addCleanup(self.provider.close)
        self.catalog = Provider(lambda _request: text("ok"), catalog=MODELS_CATALOG)
        self.addCleanup(self.catalog.close)

        def prepare(app):
            app.write_extensions(
                {
                    "models": {"url": self.catalog.url + "/models.json"},
                    "cacheTtl": {
                        "url": self.provider.url + "/cache-ttl.json",
                        "refreshHours": 24,
                    },
                }
            )

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
            },
        )
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)

    def table(self):
        with self.app.api("/cache-ttl") as response:
            return json.load(response)

    def resolved(self, query):
        with self.app.api("/cache-ttl" + query) as response:
            return json.load(response)

    def layers(self, table):
        return {layer["name"]: layer for layer in table["layers"]}

    def entries(self, table):
        return {entry["id"]: entry for entry in table["entries"]}

    def test_local_override_replaces_and_adds_without_restart(self):
        write_atomic(self.app.home / "cache-ttl.json", LOCAL_OVERRIDE)
        table = self.table()
        local = self.layers(table)["local"]
        self.assertTrue(local["loaded"])
        self.assertEqual(local["path"], str(self.app.home / "cache-ttl.json"))
        entries = self.entries(table)
        # Replaced by id: same entry, now from the local layer.
        self.assertEqual(entries["deepseek"]["layer"], "local")
        self.assertEqual(entries["deepseek"]["note"], "local override")
        self.assertEqual(entries["deepseek"]["clock"], "request")
        # New ids go before all earlier-layer entries and win the lookup.
        self.assertEqual(table["entries"][0]["id"], "laptop-gateway")
        self.assertEqual(self.resolved("?host=gateway.laptop")["id"], "laptop-gateway")
        # The replaced default keeps answering, with the override's values.
        self.assertEqual(
            self.resolved("?host=api.deepseek.com")["note"], "local override"
        )
        # Untouched defaults still resolve.
        self.assertEqual(
            self.resolved("?extension=claude")["id"], "claude-subscription"
        )

    def test_three_layers_keep_replacements_in_place_and_new_ids_first(self):
        write_atomic(self.app.home / "cache-ttl-remote.json", REMOTE_TABLE)
        gateway = {
            **REMOTE_TABLE["entries"][1],
            "match": {"host": "gateway.*"},
            "note": "local gateway replacement",
        }
        local = {"entries": [*LOCAL_OVERRIDE["entries"], gateway]}
        write_atomic(self.app.home / "cache-ttl.json", local)
        table = self.table()
        self.assertEqual(
            [entry["id"] for entry in table["entries"]],
            ["laptop-gateway", "fixture-gateway"]
            + [entry["id"] for entry in SHIPPED["entries"]],
        )
        self.assertTrue(self.layers(table)["remote"]["loaded"])
        self.assertEqual(self.entries(table)["fixture-gateway"]["layer"], "local")
        self.assertEqual(self.entries(table)["deepseek"]["note"], "local override")
        # A fresh local rule wins before the replaced, more general gateway rule.
        self.assertEqual(self.resolved("?host=gateway.laptop")["id"], "laptop-gateway")
        self.assertEqual(
            self.resolved("?host=gateway.fixture")["note"],
            "local gateway replacement",
        )
        self.assertEqual(self.resolved("?host=api.deepseek.com")["clock"], "request")

    def test_duplicate_ids_reject_the_layer_and_retain_last_good_entries(self):
        duplicate = {"entries": [LOCAL_OVERRIDE["entries"][0]] * 2}
        write_atomic(self.app.home / "cache-ttl.json", duplicate)
        table = self.table()
        self.assertFalse(self.layers(table)["local"]["loaded"])
        self.assertIn("duplicate id: deepseek", self.layers(table)["local"]["error"])
        self.assertFalse(any(entry["layer"] == "local" for entry in table["entries"]))
        write_atomic(self.app.home / "cache-ttl.json", LOCAL_OVERRIDE)
        self.assertTrue(self.layers(self.table())["local"]["loaded"])
        write_atomic(self.app.home / "cache-ttl.json", duplicate)
        for _ in range(3):
            table = self.table()
            self.assertFalse(self.layers(table)["local"]["loaded"])
            self.assertIn(
                "duplicate id: deepseek", self.layers(table)["local"]["error"]
            )
            self.assertEqual(self.entries(table)["deepseek"]["note"], "local override")
        write_atomic(self.app.home / "cache-ttl.json", LOCAL_OVERRIDE)
        self.assertTrue(self.layers(self.table())["local"]["loaded"])

    def test_duplicate_remote_ids_are_rejected_before_replacement(self):
        session = self.app.session()
        with self.app.api(
            f"/sessions/{session}/commands", {"name": "/reload", "args": {}}
        ):
            pass
        path = self.app.home / "cache-ttl-remote.json"
        before = path.read_bytes()
        self.provider.catalog = {"entries": [REMOTE_TABLE["entries"][0]] * 2}
        with self.assertRaises(urllib.error.HTTPError) as rejected:
            self.app.api(
                f"/sessions/{session}/commands", {"name": "/reload", "args": {}}
            )
        self.assertIn("duplicate id", rejected.exception.read().decode())
        self.assertEqual(path.read_bytes(), before)
        self.assertEqual(
            self.entries(self.table())["deepseek"]["note"], "remote override"
        )

    def test_same_revision_remote_replacement_invalidates_parsed_layer(self):
        session = self.app.session()
        path = self.app.home / "cache-ttl-remote.json"
        write_atomic(path, REMOTE_TABLE)
        # A future mtime prevents background refresh. Restoring it after reload
        # keeps the cached revision unchanged without depending on scheduling.
        replacement = json.loads(json.dumps(REMOTE_TABLE))
        replacement["entries"][0]["note"] = "remote revised!"
        self.assertEqual(len(json.dumps(replacement)), len(json.dumps(REMOTE_TABLE)))
        self.provider.catalog = replacement

        timestamp = int(time.time()) + 60
        os.utime(path, (timestamp, timestamp))
        self.assertEqual(
            self.entries(self.table())["deepseek"]["note"], "remote override"
        )
        with self.app.api(
            f"/sessions/{session}/commands", {"name": "/reload", "args": {}}
        ):
            pass
        os.utime(path, (timestamp, timestamp))
        self.assertEqual(
            self.entries(self.table())["deepseek"]["note"], "remote revised!"
        )

    def test_invalid_override_shadows_previous_entry_before_decoding(self):
        write_atomic(
            self.app.home / "cache-ttl.json",
            {"entries": [{**LOCAL_OVERRIDE["entries"][0], "policy": "invalid"}]},
        )
        table = self.table()
        self.assertTrue(self.layers(table)["local"]["loaded"])
        self.assertNotIn("deepseek", self.entries(table))
        self.assertIsNone(self.resolved("?host=api.deepseek.com"))
        self.assertEqual(
            self.resolved("?extension=claude")["id"], "claude-subscription"
        )

    def test_malformed_local_file_keeps_the_last_good_table(self):
        write_atomic(self.app.home / "cache-ttl.json", LOCAL_OVERRIDE)
        self.assertTrue(self.layers(self.table())["local"]["loaded"])
        (self.app.home / "cache-ttl.json").write_text("{ this is not json")
        table = self.table()
        local = self.layers(table)["local"]
        self.assertFalse(local["loaded"])
        self.assertIn("not valid JSON", local["error"])
        entries = self.entries(table)
        self.assertEqual(entries["deepseek"]["layer"], "local")
        self.assertEqual(entries["deepseek"]["note"], "local override")
        self.assertEqual(self.resolved("?host=gateway.laptop")["id"], "laptop-gateway")
        # Fixing the file is picked up live, without a restart.
        write_atomic(self.app.home / "cache-ttl.json", LOCAL_OVERRIDE)
        self.assertTrue(self.layers(self.table())["local"]["loaded"])

    def test_remote_url_is_fetched_and_merged(self):
        deadline = time.monotonic() + 20
        table = self.table()
        while (
            not self.layers(table)["remote"]["loaded"] and time.monotonic() < deadline
        ):
            time.sleep(0.1)
            table = self.table()
        remote = self.layers(table)["remote"]
        self.assertTrue(remote["loaded"])
        self.assertEqual(remote["path"], str(self.app.home / "cache-ttl-remote.json"))
        entries = self.entries(table)
        # Replaced by id, in the default entry's place, ahead of general rules.
        ids = [entry["id"] for entry in table["entries"]]
        self.assertEqual(entries["deepseek"]["layer"], "remote")
        self.assertEqual(entries["deepseek"]["note"], "remote override")
        self.assertEqual(entries["deepseek"]["policy"], "fixed")
        self.assertLess(ids.index("claude-subscription"), ids.index("deepseek"))
        # The remote layer's new id sits in front of the default entries.
        self.assertEqual(ids[0], "fixture-gateway")
        self.assertEqual(
            self.resolved("?host=gateway.fixture")["id"], "fixture-gateway"
        )

    def test_session_reload_refetches_the_remote_copy(self):
        session = self.app.session()
        self.assertFalse((self.app.home / "cache-ttl-remote.json").exists())
        with self.app.api(
            f"/sessions/{session}/commands", {"name": "/reload", "args": {}}
        ) as response:
            outcome = json.load(response)["result"]
        self.assertEqual(outcome["reloaded"], "models+session")
        table = self.table()
        self.assertTrue(self.layers(table)["remote"]["loaded"])
        self.assertEqual(self.entries(table)["deepseek"]["note"], "remote override")

    def test_a_turns_usage_says_when_its_cache_fades_across_a_restart(self):
        # A provider that only evicts: the count is unknown past typical
        # survival and gone past the bound, counted from the response's end.
        write_atomic(
            self.app.home / "cache-ttl.json",
            {
                "version": 1,
                "entries": [
                    {
                        "id": "fixture-evict",
                        "match": {"host": "127.0.0.1"},
                        "policy": "evict",
                        "survival": {"typical": 600, "max": 3600},
                        "evidence": "measured",
                    }
                ],
            },
        )
        session = self.app.session()
        self.app.prompt(session, "hello").close()
        self.app.idle(session)
        with self.app.api(f"/sessions/{session}/requests") as response:
            finished = json.load(response)["rows"][0]["finishedMs"]
        fading = [{"at": finished + 600_000}, {"at": finished + 3_600_000, "cached": 0}]

        def latest_fade():
            usages = [
                event for event in self.app.events(session) if event["type"] == "usage"
            ]
            return usages[-1].get("cacheFade")

        self.assertEqual(latest_fade(), fading)
        # The steps are stored with the usage, so a client attaching to a
        # restarted daemon still counts down from the same call.
        self.app.restart()
        self.assertEqual(latest_fade(), fading)


class DefaultCacheTtlTests(unittest.TestCase):
    table = CacheTtlTests.table
    resolved = CacheTtlTests.resolved
    layers = CacheTtlTests.layers
    entries = CacheTtlTests.entries

    def setUp(self):
        self.app = Albedo()
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)

    def test_default_table_is_served_and_lookups_resolve(self):
        table = self.table()
        self.assertTrue(self.layers(table)["default"]["loaded"])
        self.assertIn("priv/cache-ttl.json", self.layers(table)["default"]["path"])
        self.assertFalse(self.layers(table)["local"]["loaded"])
        # Every shipped entry, each tagged with the layer it came from.
        self.assertEqual(
            set(self.entries(table)), {e["id"] for e in SHIPPED["entries"]}
        )
        for entry in table["entries"]:
            self.assertEqual(entry["layer"], "default")
        # First match in table order: the subscription entry shadows nothing,
        # but a specific model glob beats the general host entry after it.
        claude = self.resolved("?extension=claude")
        self.assertEqual(claude["id"], "claude-subscription")
        self.assertEqual(claude["policy"], "refresh")
        self.assertEqual(claude["clock"], "request")
        self.assertEqual([t["seconds"] for t in claude["tiers"]], [300, 3600])
        self.assertEqual(claude["read"], 0.1)
        deepseek = self.resolved("?host=api.deepseek.com")
        self.assertEqual(deepseek["id"], "deepseek")
        self.assertEqual(deepseek["policy"], "evict")
        self.assertEqual(deepseek["survival"]["typical"], 14400)
        # Matching is case-insensitive.
        self.assertEqual(self.resolved("?host=API.DEEPSEEK.COM")["id"], "deepseek")
        # A model glob within a list of patterns, ahead of the plain host rule.
        self.assertEqual(
            self.resolved("?host=api.openai.com&model=gpt-5.6-turbo")["id"],
            "openai-5.6",
        )
        self.assertEqual(
            self.resolved("?host=api.openai.com&model=gpt-4o")["id"], "openai"
        )
        self.assertIsNone(self.resolved("?extension=never-heard-of-it"))

    def test_route_requires_authentication(self):
        request = urllib.request.Request(self.app.base + "/cache-ttl")
        with self.assertRaises(urllib.error.HTTPError) as refused:
            urllib.request.urlopen(request, timeout=20)
        self.assertEqual(refused.exception.code, 403)
