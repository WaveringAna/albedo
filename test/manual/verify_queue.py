"""Independent contract checks for the attached benchmark's generated queue."""

import importlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(sys.argv.pop(1)).resolve()))
Queue = importlib.import_module("durable_queue").Queue


class Contract(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.path = str(Path(self.directory.name) / "queue.sqlite")
        self.q = Queue(self.path)

    def tearDown(self):
        self.q.close()
        self.directory.cleanup()

    def test_priority_availability_and_idempotency(self):
        low = self.q.enqueue({"nested": [1, None, True]}, key="once", priority=0)
        self.assertEqual(self.q.enqueue("replacement", key="once", priority=500), low)
        high = self.q.enqueue("high", priority=3)
        later = self.q.enqueue("later", priority=9, available_at=10)
        first = self.q.claim("worker", now=0)
        self.assertEqual(first["id"], high)
        self.assertTrue(self.q.ack(high, first["token"], now=1))
        second = self.q.claim("worker", now=1)
        self.assertEqual(second["id"], low)
        self.assertEqual(second["payload"], {"nested": [1, None, True]})
        self.assertTrue(self.q.ack(low, second["token"], now=2))
        self.assertIsNone(self.q.claim("worker", now=9))
        self.assertEqual(self.q.claim("worker", now=10)["id"], later)
        self.assertEqual(self.q.enqueue(123, key="once"), low)

    def test_tokens_expire_and_exhaustion_is_terminal(self):
        job = self.q.enqueue(None, max_attempts=2)
        first = self.q.claim("one", now=10, lease_seconds=2)
        self.assertFalse(self.q.ack(job, first["token"], now=12))
        second = self.q.claim("two", now=12, lease_seconds=2)
        self.assertEqual(second["id"], job)
        self.assertNotEqual(first["token"], second["token"])
        self.assertEqual(second["attempts"], 2)
        self.assertFalse(self.q.fail(job, first["token"], now=12))
        self.assertFalse(self.q.heartbeat(job, first["token"], now=12))
        self.assertIsNone(self.q.claim("three", now=14))
        self.assertEqual(self.q.get(job)["state"], "dead")
        self.assertEqual(
            self.q.stats(), {"ready": 0, "leased": 0, "done": 0, "dead": 1}
        )

    def test_retry_delay_heartbeat_and_reopen(self):
        job = self.q.enqueue([1, "payload"])
        lease = self.q.claim("worker", now=0, lease_seconds=10)
        self.assertTrue(self.q.heartbeat(job, lease["token"], now=9, lease_seconds=20))
        self.assertIsNone(self.q.claim("other", now=15))
        self.assertTrue(self.q.fail(job, lease["token"], now=16, delay=10))
        self.assertIsNone(self.q.claim("other", now=25))
        self.q.close()
        self.q = Queue(self.path)
        retry = self.q.claim("worker", now=26)
        self.assertEqual(retry["id"], job)
        self.assertEqual(retry["attempts"], 2)
        self.assertTrue(self.q.ack(job, retry["token"], now=27))
        self.assertFalse(self.q.ack(job, retry["token"], now=27))
        self.assertEqual(self.q.stats()["done"], 1)

    def test_expiry_reaps_all_exhausted_jobs(self):
        ids = [self.q.enqueue(index, max_attempts=1) for index in range(5)]
        for _ in ids:
            self.q.claim("worker", now=0, lease_seconds=1)
        self.assertIsNone(self.q.claim("another", now=1))
        self.assertEqual(self.q.stats()["dead"], 5)

    def test_insertion_order_breaks_ties(self):
        ids = [self.q.enqueue(value) for value in [0, False, "", [], {}]]
        for expected in ids:
            lease = self.q.claim("worker", now=0)
            self.assertEqual(lease["id"], expected)
            self.assertTrue(self.q.ack(expected, lease["token"], now=0))

    def test_validation_does_not_insert_bad_jobs(self):
        for args in [
            {"max_attempts": 0},
            {"available_at": float("nan")},
            {"available_at": float("inf")},
        ]:
            with self.assertRaises((ValueError, TypeError)):
                self.q.enqueue("invalid", **args)
        for args in [
            {"owner": "", "now": 0},
            {"owner": "a", "now": 0, "lease_seconds": 0},
        ]:
            with self.assertRaises((ValueError, TypeError)):
                self.q.claim(**args)
        self.assertEqual(sum(self.q.stats().values()), 0)

    def test_claim_survives_abrupt_process_exit(self):
        job = self.q.enqueue("survives", max_attempts=2)
        source = "import json,os,sys;from durable_queue import Queue;q=Queue(sys.argv[1]);print(json.dumps(q.claim('dead-worker',now=0,lease_seconds=1)),flush=True);os._exit(0)"
        result = subprocess.run(
            [sys.executable, "-c", source, self.path],
            cwd=sys.path[0],
            capture_output=True,
            text=True,
            check=True,
            timeout=20,
        )
        token = json.loads(result.stdout)["token"]
        lease = self.q.claim("new-worker", now=1)
        self.assertEqual(lease["id"], job)
        self.assertFalse(self.q.ack(job, token, now=1))
        self.assertTrue(self.q.ack(job, lease["token"], now=1))


if __name__ == "__main__":
    unittest.main(verbosity=2)
