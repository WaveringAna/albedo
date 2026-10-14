"""Signed webhook ingress deduplicates deliveries and wakes a durable session."""

import hashlib
import hmac
import json
import random
import socket
import sqlite3
import subprocess
import time
import unittest
import urllib.error
import urllib.request

from daemon_test import delayed_request, kill_listener_supervisor, refused_request
from harness import Albedo, Provider, exclusive, python, text


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
                    f"assert hooks[0].intakeUrl == {self.intake_url!r}, hooks\n"
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
        with self.app.api(
            "/extensions/webhooks/hooks",
            {"name": self.hook_name, "session_id": self.session},
        ) as response:
            created = json.load(response)
        self.hook, self.secret = created["resource"]["value"], created["secret"]
        self.hook_route = f"/extensions/webhooks/hooks/{self.hook['id']}"
        self.addCleanup(self.delete_hook)
        self.payload = b'{"status":"down"}'
        self.delivery_path = self.hook_route + "/deliveries"
        self.url = self.app.base + self.delivery_path
        self.intake_url = (
            f"http://127.0.0.1:{self.app.connection['webhook_port']}"
            + self.delivery_path
        )

    def delete_hook(self):
        with self.app.api(self.hook_route + "?view=configuration") as response:
            json.load(response)
            revision = response.headers["ETag"]
        self.app.api(
            self.hook_route + "?view=configuration",
            method="DELETE",
            headers={"If-Match": revision},
        ).close()

    def allow_agent(self):
        route = f"/extensions/webhooks/permissions/{self.session}"
        with self.app.api(route) as response:
            json.load(response)
            revision = response.headers["ETag"]
        self.app.api(
            route,
            {"agent_manage": True},
            method="PATCH",
            headers={"If-Match": revision},
        ).close()

    def delivery_count(self):
        with sqlite3.connect(self.app.home / "albedo.sqlite", timeout=10) as database:
            return database.execute(
                "SELECT count(*) FROM webhook_deliveries WHERE hook = ?",
                (self.hook["id"],),
            ).fetchone()[0]

    def send(
        self, body=None, *, signature=None, event_id="alert-1", origin=None, token=None
    ):
        body = self.payload if body is None else body
        signature = (
            signature
            or "sha256="
            + hmac.new(self.secret.encode(), body, hashlib.sha256).hexdigest()
        )
        headers = {"X-Albedo-Signature": signature, "X-Albedo-Event-Id": event_id}
        if token:
            headers["Authorization"] = "Bearer " + token
        if origin:
            headers["Origin"] = origin
        request = urllib.request.Request(self.url, data=body, headers=headers)
        return urllib.request.urlopen(request, timeout=25)

    def test_hook_configuration_is_conditional_and_never_discloses_the_secret(self):
        resource = self.hook_route + "?view=configuration"
        with self.app.api(resource) as response:
            original = json.load(response)
            revision = response.headers["ETag"]
        self.assertNotIn(self.secret, json.dumps(original))
        patch = {
            "name": self.hook_name + "-edited",
            "enabled": False,
            "signature_header": "x-observed-signature",
            "signature_prefix": "hmac=",
        }
        with self.app.api(
            resource, patch, method="PATCH", headers={"If-Match": revision}
        ) as response:
            changed = json.load(response)
        self.assertNotIn(self.secret, json.dumps(changed))
        current = changed["resource"]["value"]
        for key, value in patch.items():
            self.assertEqual(current[key], value)
        with self.assertRaises(urllib.error.HTTPError) as rejected:
            self.app.api(
                resource,
                {"name": "stale-must-not-win", "enabled": True},
                method="PATCH",
                headers={"If-Match": revision},
            )
        self.assertEqual(rejected.exception.code, 412)
        with self.app.api(resource) as response:
            self.assertEqual(json.load(response), current)
        with self.app.api(self.hook_route) as response:
            self.assertNotIn(self.secret, response.read().decode("utf-8"))
        with self.assertRaises(urllib.error.HTTPError) as rejected:
            self.app.api(
                "/extensions/webhooks/hooks",
                {"name": current["name"], "session_id": self.session},
            )
        self.assertEqual(rejected.exception.code, 409)
        self.assertFalse(self.provider.requests)

    def test_intake_listens_on_its_own_port_for_deliveries_only(self):
        intake = f"http://127.0.0.1:{self.app.connection['webhook_port']}"
        signature = (
            "sha256="
            + hmac.new(self.secret.encode(), self.payload, hashlib.sha256).hexdigest()
        )
        request = urllib.request.Request(
            intake + self.delivery_path,
            data=self.payload,
            headers={"X-Albedo-Signature": signature, "X-Albedo-Event-Id": "intake-1"},
        )
        with urllib.request.urlopen(request, timeout=25) as response:
            self.assertEqual(response.status, 202)
        self.assertEqual(self.delivery_count(), 1)
        with self.assertRaises(urllib.error.HTTPError) as refused:
            urllib.request.urlopen(intake + self.hook_route, timeout=25)
        self.assertEqual(refused.exception.code, 404)

    def test_signature_origin_and_idempotency_are_enforced(self):
        with self.assertRaises(urllib.error.HTTPError) as rejected:
            self.send(signature="sha256=wrong", token=self.app.connection["token"])
        self.assertEqual(rejected.exception.code, 403)
        with self.assertRaises(urllib.error.HTTPError) as rejected:
            self.send(origin="https://attacker.example")
        self.assertEqual(rejected.exception.code, 403)
        self.assertFalse(self.provider.requests)
        self.assertEqual(self.delivery_count(), 0)
        with self.send() as response:
            self.assertEqual(response.status, 202)
            delivery = json.load(response)["delivery_id"]
        with self.send() as response:
            self.assertEqual(json.load(response)["delivery_id"], delivery)
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
        with self.app.api(
            f"/extensions/webhooks/hooks?session_id={self.session}"
        ) as response:
            hooks = json.load(response)["items"]
        self.assertIn(
            self.hook["id"],
            [item["configuration_resource"]["value"]["id"] for item in hooks],
        )

    def test_ingress_framing_refusals_do_not_admit_a_delivery(self):
        path = self.delivery_path
        signature = (
            "sha256="
            + hmac.new(self.secret.encode(), self.payload, hashlib.sha256).hexdigest()
        )
        for framing, expected_status, code in (
            ({"Transfer-Encoding": "identity"}, 400, "unsupported_transfer_encoding"),
            ({"Content-Length": "invalid"}, 400, "invalid_request"),
            ({"Content-Length": "65537"}, 413, "request_body_too_large"),
        ):
            with self.subTest(framing=framing):
                status, headers, body = refused_request(
                    self.app,
                    path,
                    {**framing, "X-Albedo-Signature": signature},
                    method="POST",
                )
                self.assertEqual(status, expected_status)
                self.assertEqual(json.loads(body)["code"], code)
                self.assertEqual(json.loads(body)["status"], expected_status)
                status, _, _ = refused_request(
                    self.app,
                    path,
                    {**framing, "Origin": "https://attacker.example"},
                    method="POST",
                )
                self.assertEqual(status, 403)
        self.assertFalse(self.provider.requests)
        self.assertEqual(self.delivery_count(), 0)
        with self.send() as response:
            self.assertEqual(response.status, 202)

    def test_signed_delayed_body_and_unknown_bodies_keep_connection_usable(self):
        signature = (
            "sha256="
            + hmac.new(self.secret.encode(), self.payload, hashlib.sha256).hexdigest()
        )
        self.assertEqual(
            delayed_request(
                self.app,
                "POST",
                self.delivery_path,
                self.payload,
                {
                    "X-Albedo-Signature": signature,
                    "X-Albedo-Event-Id": "split-delivery",
                },
            ),
            (202, 200),
        )
        for method, path in (
            ("GET", self.delivery_path + "/missing"),
            ("POST", self.delivery_path + "/missing"),
        ):
            with self.subTest(method=method, path=path):
                status, headers, _ = refused_request(
                    self.app, path, {"Content-Length": "2"}, method=method
                )
                self.assertEqual(status, 401)
                self.assertEqual(headers["www-authenticate"], "Bearer")
                self.assertEqual(
                    delayed_request(
                        self.app,
                        method,
                        path,
                        b"{}",
                        {"Authorization": "Bearer " + self.app.connection["token"]},
                    ),
                    (404, 200),
                )

    def test_agent_binding_reads_hook_and_delivery(self):
        with self.send() as response:
            self.delivery = json.load(response)["delivery_id"]
        deadline = time.monotonic() + 40
        while time.monotonic() < deadline and not self.provider.requests:
            time.sleep(0.25)
        self.assertTrue(self.provider.requests)
        self.app.idle(self.session, timeout=40)
        self.allow_agent()
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


# exclusive: boots a daemon whose intake port a foreign socket already holds
@exclusive
class WebhookIntakeWalkUpTests(unittest.TestCase):
    def setUp(self):
        self.held = held_run_below_a_free_port()
        for sock in self.held:
            self.addCleanup(sock.close)
        self.taken = self.held[0].getsockname()[1]
        self.app = Albedo(
            prepare=lambda app: app.env.update(ALBEDO_WEBHOOK_PORT=str(self.taken))
        )
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)
        self.app.daemon.install_shared_features()

    def test_intake_walks_up_past_a_taken_port(self):
        intake_port = self.app.connection["webhook_port"]
        self.assertEqual(intake_port, self.taken + len(self.held))
        with self.app.api(
            "/extensions/webhooks/hooks",
            {"name": "walk-up", "session_id": self.app.session()},
        ) as response:
            created = json.load(response)
        hook, secret = created["resource"]["value"], created["secret"]
        path = f"/extensions/webhooks/hooks/{hook['id']}/deliveries"
        body = b'{"status":"down"}'
        signature = (
            "sha256=" + hmac.new(secret.encode(), body, hashlib.sha256).hexdigest()
        )

        def deliver(port):
            request = urllib.request.Request(
                f"http://127.0.0.1:{port}{path}",
                data=body,
                headers={"X-Albedo-Signature": signature},
            )
            return urllib.request.urlopen(request, timeout=25)

        with self.app.api(
            f"/extensions/webhooks/hooks?session_id={hook['session_id']}"
        ) as response:
            listed = json.load(response)["items"]
        self.assertEqual(
            [item["delivery_url"] for item in listed],
            [f"http://127.0.0.1:{intake_port}{path}"],
        )
        with deliver(intake_port) as response:
            self.assertEqual(response.status, 202)
        for sock in self.held:
            sock.close()
        with self.assertRaises(urllib.error.URLError) as refused:
            deliver(self.taken)
        self.assertIsInstance(refused.exception.reason, ConnectionRefusedError)


# exclusive: boots daemons whose intake cannot bind, and crashes the intake
@exclusive
class WebhookIntakeFailureTests(unittest.TestCase):
    def test_a_port_refused_for_another_reason_ends_boot_without_walking_up(self):
        # Port 1023 needs privileges and 1024 does not: a walk past any failure
        # would come up on 1024.
        for port, usable in ((1023, False), (1024, True)):
            probe = socket.socket()
            try:
                probe.bind(("127.0.0.1", port))
                bound = True
            except OSError:
                bound = False
            finally:
                probe.close()
            if bound != usable:
                self.skipTest(f"port {port} is {'free' if bound else 'taken'} here")
        boot = {}

        def refused_start(daemon):
            daemon.env["ALBEDO_WEBHOOK_PORT"] = "1023"
            process = daemon.start_launcher()
            try:
                boot["exit"] = process.wait(timeout=20)
            except subprocess.TimeoutExpired:
                process.kill()
                boot["exit"] = None
            daemon.env["ALBEDO_WEBHOOK_PORT"] = "0"

        def prepare(app):
            app.daemon.boot_action = refused_start

        with Albedo(prepare=prepare) as app:
            self.assertNotIn(boot["exit"], (None, 0), "the daemon came up")
            log = (app.home / "daemon.log").read_text(errors="replace")
            self.assertIn("webhook intake on 127.0.0.1:1023: permission denied", log)

    def test_an_intake_that_cannot_rebind_stops_while_the_daemon_runs(self):
        with Albedo(
            prepare=lambda app: app.daemon.env.update(ALBEDO_INSPECT="1")
        ) as app:
            app.daemon.install_shared_features()
            session = app.session()
            with app.api(
                "/extensions/webhooks/hooks", {"name": "held", "session_id": session}
            ) as response:
                json.load(response)
            killed = kill_listener_supervisor(
                app, app.connection["webhook_port"], hold=True
            )
            self.assertTrue(killed.startswith("<"), killed)
            deadline = time.monotonic() + 30
            while "webhook_port" in json.loads((app.home / "daemon.json").read_text()):
                self.assertLess(time.monotonic(), deadline, "the intake kept retrying")
                time.sleep(0.25)
            with app.api(
                f"/extensions/webhooks/hooks?session_id={session}"
            ) as response:
                listed = json.load(response)["items"]
            self.assertEqual([item["delivery_url"] for item in listed], [None])
            log = (app.home / "daemon.log").read_text(errors="replace")
            self.assertIn("webhook intake stopped", log)


def held_run_below_a_free_port(length=3):
    """Listening sockets on `length` consecutive ports below the OS's
    ephemeral range, where daemons on port 0 never land, with the next port
    up free: a daemon told to start at the first must walk up past them all."""
    for _ in range(50):
        first = random.randrange(20_000, 30_000)
        held = []
        try:
            for port in range(first, first + length):
                sock = socket.socket()
                held.append(sock)
                sock.bind(("127.0.0.1", port))
                sock.listen()
            probe = socket.socket()
            try:
                probe.bind(("127.0.0.1", first + length))
            finally:
                probe.close()
            return held
        except OSError:
            for sock in held:
                sock.close()
    raise AssertionError("no free run of ports")
