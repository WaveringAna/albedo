"""Unread stream fixtures and bounded subscriber inspection for E2E tests."""

import socket

from harness import ROOT
from inspect_support import Inspection


class StreamProbe:
    def __init__(self, app):
        self.inspection = Inspection(
            app, ROOT / "test/e2e/albedo_stream_pressure_probe.erl"
        )

    def call(self, function, arguments="[]"):
        return self.inspection.call_json(function, arguments)


def unread_stream(app, path):
    connection = socket.socket()
    connection.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1024)
    connection.settimeout(15)
    connection.connect(("127.0.0.1", app.connection["port"]))
    connection.sendall(
        (
            f"GET {path} HTTP/1.1\r\nHost: localhost:{app.connection['port']}\r\n"
            f"Authorization: Bearer {app.connection['token']}\r\n"
            "Accept: text/event-stream\r\n\r\n"
        ).encode()
    )
    # Read only the readiness batch, then leave all later socket data unread.
    initial = b""
    while b"data: " not in initial or b"\n\n" not in initial.split(b"data: ", 1)[1]:
        part = connection.recv(1)
        if not part:
            raise AssertionError("stream closed before readiness")
        initial += part
    return connection
