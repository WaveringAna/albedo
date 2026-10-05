"""The model's web_search must use the user's preferred provider and fall
back down the order only when one fails, and the /web-search page must
reorder providers and turn them off for every later search.

Exa is the one provider a test can stand in for: its endpoint is a setting,
so a local fake answers it. The subscription providers have no sign-in on the
test daemon, so each fails at once without reaching the network.

The order and the Exa key are global settings, so each scenario has its own
daemon."""

import ast
import json
import threading
import unittest
import urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from harness import Albedo, Provider, exclusive, python, text

COLLECTION = "/extensions/web-search/providers"

RESULTS = [
    {
        "url": "https://gleam.run/news/one",
        "title": "Gleam one",
        "highlights": ["first highlight", "second"],
        "publishedDate": "2026-08-01",
    },
    {"url": "https://gleam.run/news/one", "title": "duplicate"},
    {"url": "https://example.com/two", "title": None, "highlights": None},
]

SEARCH = (
    "r = await web_search('latest gleam release', limit=2)\n"
    "print(repr([r.answer, [(s.title, s.url, s.snippet, s.published)"
    " for s in r.sources]]))\n"
    "print(r)"
)

FAILING = (
    "try:\n"
    "    await web_search('latest gleam release')\n"
    "except Exception as error:\n"
    "    print('raised:', error)"
)


class FakeExa:
    """Answers /search with RESULTS and records what each request sent."""

    def __init__(self):
        self.requests = []
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                owner.requests.append((self.path, self.headers["x-api-key"], body))
                payload = json.dumps({"results": RESULTS}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def log_message(self, format, *args):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()


def scripting(cells):
    """Answers each user turn with the next scripted python cell."""

    def reply(request):
        if request["messages"][-1].get("role") == "user" and cells:
            return python(cells.pop(0))
        return text("done")

    return Provider(reply)


def last_output(app, session):
    results = [
        json.loads(part["value"])
        for entry in app.history(session)["items"]
        if entry["kind"] == "tool_result" and entry["tool"]["name"] == "python"
        for part in entry["content"]
        if part["kind"] == "json" and part["field"] == "result"
    ]
    return results[-1]["output"]


@exclusive
class WebSearchTests(unittest.TestCase):
    def setUp(self):
        self.exa = FakeExa()
        self.addCleanup(self.exa.close)

    def start(self, cells):
        provider = scripting(cells)
        self.addCleanup(provider.close)

        def prepare(app):
            app.write_extensions({"exa": {"endpoint": self.exa.url}})
            app.store_secrets("exa", {"apiKey": "exa-key"})

        app = Albedo(provider, prepare=prepare)
        app.__enter__()
        self.addCleanup(app.__exit__, None, None, None)
        return app

    def ask(self, app, prompt):
        session = app.session()
        app.prompt(session, prompt).close()
        app.idle(session)
        return last_output(app, session)

    def providers(self, app):
        with app.api(COLLECTION) as response:
            page = json.load(response)
        return [item["value"] for item in page["items"]], page["page"]

    def change(self, app, name, change):
        with app.api(f"{COLLECTION}/{name}", {"change": change}) as response:
            return json.load(response)["resource"]["value"]

    def test_search_passes_over_signed_out_providers_to_exa(self):
        app = self.start([SEARCH])
        output = self.ask(app, "search the web")
        answer, sources = ast.literal_eval(output.splitlines()[0])
        self.assertEqual(answer, "")
        # One source per url, cut to the limit, highlights as the snippet.
        self.assertEqual(
            sources,
            [
                (
                    "Gleam one",
                    "https://gleam.run/news/one",
                    "first highlight … second",
                    "2026-08-01",
                ),
                ("https://example.com/two", "https://example.com/two", "", None),
            ],
        )
        self.assertIn("[1] Gleam one (2026-08-01)", output)
        ((path, key, body),) = self.exa.requests
        self.assertEqual((path, key), ("/search", "exa-key"))
        self.assertEqual(
            (body["query"], body["numResults"]), ("latest gleam release", 2)
        )

    def test_page_reorders_and_turns_off_providers(self):
        app = self.start([FAILING])
        listed, page = self.providers(app)
        names = [entry["name"] for entry in listed]
        self.assertEqual(sorted(names), ["antigravity", "claude", "codex", "exa"])
        self.assertEqual([entry["position"] for entry in listed], [1, 2, 3, 4])
        self.assertTrue(all(entry["enabled"] for entry in listed))
        self.assertEqual(
            [row["id"] for row in page["rows"]], names, "the page lists the same order"
        )

        index = names.index("exa")
        moved = self.change(app, "exa", "up")
        self.assertEqual(moved["position"], index)
        expected = names[: index - 1] + ["exa", names[index - 1]] + names[index + 1 :]
        self.assertEqual([entry["name"] for entry in self.providers(app)[0]], expected)
        settings = json.loads((app.home / "extensions.json").read_text())
        self.assertEqual(settings["web-search"]["order"], expected)

        # A move past the top changes nothing.
        top = expected[0]
        self.assertEqual(self.change(app, top, "up")["position"], 1)

        self.assertFalse(self.change(app, "exa", "toggle")["enabled"])
        output = self.ask(app, "search the web")
        self.assertIn("raised: every web search provider failed", output)
        for name in ("codex", "claude", "antigravity"):
            self.assertIn(name + ":", output)
        self.assertNotIn("exa:", output)
        self.assertEqual(self.exa.requests, [], "a provider turned off is never tried")

        for name, body, status in (
            ("nobody", {"change": "up"}, 404),
            ("exa", {"change": "sideways"}, 400),
        ):
            with self.subTest(name=name, body=body):
                with self.assertRaises(urllib.error.HTTPError) as refused:
                    app.api(f"{COLLECTION}/{name}", body).close()
                refused.exception.close()
                self.assertEqual(refused.exception.code, status)


if __name__ == "__main__":
    unittest.main()
