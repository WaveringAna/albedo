"""An ordinary HTTP client can recover identified chat without CLI or private APIs."""

import http.client
import json
import threading
import unittest
import urllib.parse

from harness import Albedo, Provider, operation_id, text


class HTTPConsumerTest(unittest.TestCase):
    def read_json(self, response):
        self.assertEqual(
            (response.getheader("Content-Type") or "").split(";", 1)[0],
            "application/json",
        )
        payload = response.read(1048577)
        self.assertLessEqual(len(payload), 1048576)
        return json.loads(payload)

    def test_identified_chat_reconnects_and_reconciles_durable_history(self):
        requested = threading.Event()
        release = threading.Event()

        def reply(_):
            requested.set()
            if not release.wait(20):
                raise AssertionError("consumer did not release provider")
            return text("ordinary HTTP answer")

        provider = Provider(reply)
        self.addCleanup(provider.close)
        self.addCleanup(release.set)
        with Albedo(provider) as app:
            address = urllib.parse.urlsplit(app.base)
            headers = {
                "Authorization": "Bearer " + app.connection["token"],
                "Content-Type": "application/json",
            }
            connection = http.client.HTTPConnection(
                address.hostname, address.port, timeout=20
            )
            self.addCleanup(connection.close)
            session_id = operation_id()
            intent = {
                "kind": "new",
                "workspace": str(app.workspace),
                "provider_profile": app.profile,
            }
            resource = f"/sessions/{session_id}"
            connection.request(
                "PUT", resource, json.dumps(intent), {**headers, "If-None-Match": "*"}
            )
            response = connection.getresponse()
            if response.status != 201:
                self.fail(
                    f"session creation returned {response.status}: {response.read()!r}"
                )
            self.assertEqual(response.getheader("Location"), resource)
            created = self.read_json(response)
            self.assertEqual(created["id"], session_id)
            self.assertEqual(
                created["creation"]["submitted"]["workspace"], intent["workspace"]
            )

            connection.request("GET", resource, headers=headers)
            snapshot = self.read_json(connection.getresponse())
            cursor = snapshot["cursor"]
            input_id = operation_id()
            input_resource = f"{resource}/inputs/{input_id}"
            message = {"kind": "message", "text": "ordinary HTTP question"}
            connection.request("PUT", input_resource, json.dumps(message), headers)
            accepted_response = connection.getresponse()
            self.assertEqual(accepted_response.status, 202)
            accepted = self.read_json(accepted_response)
            self.assertEqual(accepted["id"], input_id)
            self.assertEqual(accepted["admission"], "accepted")
            self.assertTrue(requested.wait(10), "input did not reach provider")

            # Resolve a lost acknowledgement through the resource itself.
            connection.request("GET", input_resource, headers=headers)
            self.assertEqual(self.read_json(connection.getresponse())["id"], input_id)
            connection.request("PUT", input_resource, json.dumps(message), headers)
            duplicate_response = connection.getresponse()
            self.assertEqual(duplicate_response.status, 202)
            self.assertEqual(self.read_json(duplicate_response)["id"], input_id)

            query = urllib.parse.urlencode(
                {
                    "after_generation": cursor["generation"],
                    "after_seq": cursor["sequence"],
                }
            )
            stream = http.client.HTTPConnection(
                address.hostname, address.port, timeout=20
            )
            self.addCleanup(stream.close)
            stream.request(
                "GET",
                resource + "?" + query,
                headers={**headers, "Accept": "text/event-stream"},
            )
            response = stream.getresponse()
            self.assertEqual(response.status, 200)
            self.assertEqual(
                (response.getheader("Content-Type") or "").split(";", 1)[0],
                "text/event-stream",
            )
            release.set()
            consumed = cursor["sequence"]
            finished = False
            for line in response:
                if not line.startswith(b"data: "):
                    continue
                self.assertLessEqual(len(line[6:].rstrip(b"\r\n")), 1048576)
                batch = json.loads(line[6:])
                self.assertEqual(batch["generation"], cursor["generation"])
                sequences = [event["sequence"] for event in batch["events"]]
                self.assertEqual(
                    sequences, list(range(consumed + 1, consumed + 1 + len(sequences)))
                )
                self.assertEqual(
                    batch["cursor"], sequences[-1] if sequences else consumed
                )
                consumed = batch["cursor"]
                if any(event["type"] == "turn_completed" for event in batch["events"]):
                    finished = True
                    break
            self.assertTrue(finished, "watch closed without turn outcome")
            response.close()
            stream.close()

            # Reconnect with the saved pair, never an SSE transport ID.
            reconnect = http.client.HTTPConnection(
                address.hostname, address.port, timeout=20
            )
            self.addCleanup(reconnect.close)
            query = urllib.parse.urlencode(
                {"after_generation": cursor["generation"], "after_seq": consumed}
            )
            reconnect.request(
                "GET",
                resource + "?" + query,
                headers={**headers, "Accept": "text/event-stream"},
            )
            resumed = reconnect.getresponse()
            for line in resumed:
                if line.startswith(b"data: "):
                    self.assertLessEqual(len(line[6:].rstrip(b"\r\n")), 1048576)
                    batch = json.loads(line[6:])
                    self.assertEqual(batch["generation"], cursor["generation"])
                    self.assertFalse(
                        any(event["type"] == "reset" for event in batch["events"])
                    )
                    self.assertTrue(
                        all(event["sequence"] > consumed for event in batch["events"])
                    )
                    break
            else:
                self.fail("reconnect closed without a batch")
            resumed.close()
            reconnect.close()

            connection.request("GET", resource + "/history", headers=headers)
            history = self.read_json(connection.getresponse())
            users = [entry for entry in history["items"] if entry["kind"] == "user"]
            self.assertEqual([entry["input_id"] for entry in users], [input_id])
            self.assertEqual(
                [
                    part["text"]
                    for entry in users
                    for part in entry["content"]
                    if part["kind"] == "text"
                ],
                [message["text"]],
            )
            self.assertIn(
                "ordinary HTTP answer",
                [
                    part["text"]
                    for entry in history["items"]
                    for part in entry["content"]
                    if part["kind"] == "text"
                ],
            )
            connection.request("GET", input_resource, headers=headers)
            outcome = self.read_json(connection.getresponse())
            self.assertEqual(outcome["delivery"], "committed")
            self.assertEqual(outcome["turn"]["state"], "completed")
            self.assertEqual(len(provider.requests), 1)
