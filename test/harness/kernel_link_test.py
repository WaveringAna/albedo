"""The kernel half of the session layer, exercised frame by frame.

Sequence, acknowledgement, and replay rules decide whether a reconnect loses
or repeats a message, and E2E cannot choose where a connection drops. These
tests drive albedo_link directly: the outbox's coalescing and bounds, replayed
daemon frames, token checks, newest-attach-wins, and resending what the daemon
never acknowledged.
"""

from pathlib import Path
import os
import shutil
import socket
import sys
import tempfile
import threading
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "priv" / "python"))
import albedo_link  # noqa: E402


class OutboxTest(unittest.TestCase):
    def test_ack_drops_everything_up_to_it(self):
        outbox = albedo_link.Outbox()
        for n in range(4):
            outbox.add({"type": "call", "id": str(n)})
        outbox.ack(2)
        self.assertEqual([seq for seq, _ in outbox.pending()], [3, 4])

    def test_mirrors_and_traces_keep_only_their_newest_copy(self):
        outbox = albedo_link.Outbox()
        outbox.add({"type": "mirror", "handle": "a", "tail": "1"})
        outbox.add({"type": "mirror", "handle": "b", "tail": "1"})
        outbox.add({"type": "done", "id": "c1"})
        outbox.add({"type": "mirror", "handle": "a", "tail": "2"})
        frames = [data for _, data in outbox.pending()]
        self.assertEqual(len(frames), 3)
        self.assertIn(b'"tail":"2"', frames[-1])
        self.assertNotIn(b'"handle":"a","tail":"1"', b"".join(frames))

    def test_the_bound_sheds_coalescing_frames_before_deliveries(self):
        outbox = albedo_link.Outbox(frames=3)
        outbox.add({"type": "done", "id": "c1"})
        outbox.add({"type": "mirror", "handle": "a"})
        outbox.add({"type": "call", "id": "x"})
        outbox.add({"type": "job", "id": "j"})
        kinds = [data for _, data in outbox.pending()]
        self.assertEqual(len(kinds), 3)
        self.assertFalse(any(b"mirror" in data for data in kinds))
        self.assertEqual(outbox.dropped, 0)
        outbox.add({"type": "done", "id": "c2"})
        self.assertEqual(outbox.dropped, 1)
        self.assertNotIn(b'"c1"', b"".join(data for _, data in outbox.pending()))

    def test_a_replayed_daemon_frame_is_not_applied_twice(self):
        inbound = albedo_link.Inbound()
        self.assertEqual(
            [inbound.accept(seq) for seq in (1, 2, 2, 1, 3)],
            [True, True, False, False, True],
        )

    def test_job_book_follows_started_and_proven_gone_jobs(self):
        book = albedo_link.JobBook()
        book.observe({"type": "job_start", "id": "a", "pgid": 4242})
        book.observe({"type": "job_start", "id": "b", "pgid": 4243})
        book.observe({"type": "job", "id": "a", "cleanup": {"gone": False}})
        book.observe({"type": "job", "id": "b", "cleanup": {"gone": True}})
        book.observe({"type": "jobs", "live": 2})
        self.assertEqual(sorted(book.started), ["a"])
        self.assertEqual(book.live(), 3)


class SocketLinkTest(unittest.TestCase):
    def setUp(self):
        self.run_dir = tempfile.mkdtemp(prefix="link-")
        self.received = []
        self.link = albedo_link.SocketLink(
            self.run_dir,
            "secret",
            lambda: {"pid": os.getpid()},
            bundle="bundle",
            grace=60,
        )
        threading.Thread(target=self.serve, daemon=True).start()

    def serve(self):
        try:
            self.link.serve(self.received.append)
        except OSError:
            pass  # the listener closed in tearDown

    def tearDown(self):
        self.link.listener.close()
        shutil.rmtree(self.run_dir, ignore_errors=True)

    def attach(self, token="secret", ack=0):
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        connection.settimeout(5)
        connection.connect(os.path.join(self.run_dir, albedo_link.SOCKET))
        self.addCleanup(connection.close)
        attach = {"attach": {"token": token, "ack": ack, "grace": 30}}
        albedo_link.write_frame(connection.send, albedo_link.encode(attach))
        return connection, albedo_link.read_frame(connection.recv)

    def frames(self, connection, count):
        return [albedo_link.read_frame(connection.recv) for _ in range(count)]

    def test_a_wrong_token_is_refused(self):
        _, answer = self.attach(token="guess")
        self.assertEqual(answer, {"refused": "wrong token"})
        self.assertFalse(self.link.attached())

    def test_reattach_resends_only_what_was_not_acknowledged(self):
        first, hello = self.attach()
        self.assertEqual((hello["hello"]["epoch"], hello["hello"]["ack"]), (1, 0))
        self.assertEqual(self.link.grace, 30)
        for n in range(3):
            self.link.send({"type": "call", "id": str(n)})
        self.assertEqual([f["seq"] for f in self.frames(first, 3)], [1, 2, 3])
        albedo_link.write_frame(
            first.send,
            albedo_link.encode(
                {"seq": 1, "ack": 1, "frame": {"type": "release", "handle": "h"}}
            ),
        )
        self.assertEqual(albedo_link.read_frame(first.recv), {"ack": 1})
        second, hello = self.attach(ack=2)
        # Newest attach wins: the first connection is cut off.
        self.assertEqual(first.recv(1), b"")
        self.assertEqual((hello["hello"]["epoch"], hello["hello"]["ack"]), (2, 1))
        (resent,) = self.frames(second, 1)
        self.assertEqual((resent["seq"], resent["frame"]["id"]), (3, "2"))
        # The daemon replays seq 1 after its restart: it is not delivered again.
        replay = {"seq": 1, "ack": 3, "frame": {"type": "release", "handle": "h"}}
        albedo_link.write_frame(second.send, albedo_link.encode(replay))
        self.assertEqual(albedo_link.read_frame(second.recv), {"ack": 1})
        self.assertEqual(len(self.received), 1)
        self.assertEqual(self.link.outbox.pending(), [])

    def test_frames_sent_while_detached_wait_for_the_next_attach(self):
        self.link.send({"type": "done", "id": "c1"})
        self.assertGreater(self.link.idle_for(), 0)
        connection, _ = self.attach()
        (done,) = self.frames(connection, 1)
        self.assertEqual(done["frame"], {"type": "done", "id": "c1"})
        self.assertEqual(self.link.idle_for(), 0)


if __name__ == "__main__":
    unittest.main()
