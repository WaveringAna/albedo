"""Signed webhook ingress deduplicates deliveries and wakes a durable session."""

import hashlib
import hmac
import json
import time
import unittest
import urllib.error
import urllib.request

from harness import Albedo, Provider, python, text


class WebhookTests(unittest.TestCase):
    def setUp(self):
        def script(request):
            latest = request["input"][-1]
            if latest.get("role") == "user" and "probe webhook binding" in str(
                latest.get("content", "")
            ):
                code = (
                    "hooks = await webhooks.list()\n"
                    f"assert any(h.name == {self.hook_name!r} for h in hooks)\n"
                    f"payload = await webhooks.delivery('{self.delivery}')\n"
                    "assert 'down' in payload.body\n"
                    "print('WEBHOOK_BINDING_OK')"
                )
                return python(code)
            return text("acknowledged")

        self.provider = Provider(script)
        self.addCleanup(self.provider.close)
        self.app = Albedo(self.provider, protocol="responses")
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)
        self.session = self.app.session()
        self.hook_name = f"outage-{self.provider.route}"
        self.command_route = f"/sessions/{self.session}/commands"
        created = self.command("create", self.hook_name)
        self.hook, self.secret = created["hook"], created["secret"]
        self.addCleanup(self.command, "delete", self.hook["id"])
        self.payload = b'{"status":"down"}'
        self.url = self.app.base + self.hook["url"]

    def command(self, action, details=None):
        args = {"action": action}
        if details is not None:
            args["details"] = details
        with self.app.api(
            self.command_route, {"name": "/webhooks", "args": args}
        ) as response:
            return json.load(response)["result"]

    def send(self, body=None, *, signature=None, event_id="alert-1", origin=None):
        body = self.payload if body is None else body
        signature = (
            signature
            or "sha256="
            + hmac.new(self.secret.encode(), body, hashlib.sha256).hexdigest()
        )
        headers = {"X-Albedo-Signature": signature, "X-Albedo-Event-Id": event_id}
        if origin:
            headers["Origin"] = origin
        request = urllib.request.Request(self.url, data=body, headers=headers)
        return urllib.request.urlopen(request, timeout=25)

    def test_signature_origin_and_idempotency_are_enforced(self):
        with self.assertRaises(urllib.error.HTTPError) as rejected:
            self.send(signature="sha256=wrong")
        self.assertEqual(rejected.exception.code, 401)
        with self.assertRaises(urllib.error.HTTPError) as rejected:
            self.send(origin="https://attacker.example")
        self.assertEqual(rejected.exception.code, 403)
        with self.send() as response:
            self.assertEqual(response.status, 202)
            delivery = json.load(response)["deliveryId"]
        with self.send() as response:
            self.assertEqual(json.load(response)["deliveryId"], delivery)
        with self.assertRaises(urllib.error.HTTPError) as rejected:
            self.send(body=b"different")
        self.assertEqual(rejected.exception.code, 409)
        deadline = time.monotonic() + 40
        while time.monotonic() < deadline and not self.provider.requests:
            time.sleep(0.25)
        self.assertEqual(
            len(self.provider.requests), 1, "retry should wake the session once"
        )
        self.assertIn(
            f"[webhook {self.hook_name} #", json.dumps(self.provider.requests[0])
        )
        self.assertIn(
            self.hook["id"],
            [item["hook"]["id"] for item in self.command("list")["hooks"]],
        )

    def test_agent_binding_reads_hook_and_delivery(self):
        with self.send() as response:
            self.delivery = json.load(response)["deliveryId"]
        deadline = time.monotonic() + 40
        while time.monotonic() < deadline and not self.provider.requests:
            time.sleep(0.25)
        self.assertTrue(self.provider.requests)
        self.app.idle(self.session, timeout=40)
        self.command("agent_on")
        self.app.prompt(self.session, "probe webhook binding").close()
        self.app.idle(self.session)
        requests = [entry["request"] for entry in self.provider.requests]
        self.assertEqual(len(requests), 3)
        outputs = [
            item.get("output", "")
            for item in requests[-1]["input"]
            if item.get("type") == "function_call_output"
        ]
        self.assertTrue(
            any("WEBHOOK_BINDING_OK" in str(output) for output in outputs), outputs
        )


if __name__ == "__main__":
    unittest.main()
