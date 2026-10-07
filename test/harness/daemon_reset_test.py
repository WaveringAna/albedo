"""Catches a daemon connection reset surfacing as ``ResponseNotReady``.

``_Response.close`` read headers that ``begin()`` never set, which replaced the
reset, so the ``OSError`` retry in the listener-restart test failed. That reset
only lands inside a restart window, so E2E reaches it rarely; this drives the
real connection against a socket that resets every request.
"""

import socket
import struct
import sys
import threading
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "test" / "e2e"))
import harness  # noqa: E402


class ResetTest(unittest.TestCase):
    def reset_server(self):
        """Returns the port of a listener that resets each connection."""
        server = socket.socket()
        server.bind(("127.0.0.1", 0))
        server.listen()
        self.addCleanup(server.close)

        def reset_each_request():
            while True:
                try:
                    peer, _ = server.accept()
                except OSError:
                    return
                peer.recv(4096)
                peer.setsockopt(
                    socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0)
                )
                peer.close()

        threading.Thread(target=reset_each_request, daemon=True).start()
        return server.getsockname()[1]

    def test_a_reset_before_the_status_line_is_raised_as_the_reset(self):
        connection = harness._Connection(self.reset_server(), "token")
        self.addCleanup(connection.close)
        connection.request("GET", "/server")
        with self.assertRaises(ConnectionError):
            connection.getresponse()


if __name__ == "__main__":
    unittest.main()
