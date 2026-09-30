"""A provider's declared image edge holds for every image it is sent.

A profile's `imageEdge` stands in for Claude's 2000px limit, which only the
real Anthropic upstream declares.
"""

import base64
import hashlib
import json
import re
import sqlite3
import struct
import unittest
import urllib.error
import zlib

from harness import Albedo, Provider, python, text


def png(width, height):
    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body))

    rows = b"".join(b"\x00" + b"\x80\x40\x20" * width for _ in range(height))
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(rows))
        + chunk(b"IEND", b"")
    )


WIDE = png(1200, 10)
WIDE_DATA = base64.b64encode(WIDE).decode()
NOTE = "An earlier image was scaled from 1200x10 to 1000x"


def widths(request):
    """The pixel width of every PNG the request carries."""
    found = re.findall(r"data:image/png;base64,([A-Za-z0-9+/=]+)", json.dumps(request))
    return [struct.unpack(">I", base64.b64decode(data)[16:20])[0] for data in found]


class ImageLimitsTest(unittest.TestCase):
    def test_a_declared_edge_refuses_new_images_and_fits_history(self):
        def reply(request):
            inputs = request["input"]
            if inputs[-1].get("type") == "function_call_output":
                return text("done")
            prompts = [
                item.get("content")
                for item in inputs
                if item.get("role") == "user"
                and "<system-note" not in json.dumps(item.get("content"))
            ]
            if prompts[-1] == "show":
                return python(
                    "import base64\nshow_image(base64.b64decode('" + WIDE_DATA + "'))"
                )
            return text("ok")

        provider = Provider(reply)
        loose, strict = f"loose-{provider.route}", f"strict-{provider.route}"
        profile = {
            "baseUrl": provider.url,
            "apiKey": "fixture-key",
            "model": "fixture-model",
            "protocol": "responses",
        }
        try:
            with Albedo(
                provider,
                protocol="responses",
                providers={loose: profile, strict: dict(profile, imageEdge=1000)},
            ) as app:
                session = app.session()
                attach = {
                    "content": "look",
                    "image": {
                        "mimeType": "image/png",
                        "data": WIDE_DATA,
                        "width": 1200,
                        "height": 10,
                        "bytes": len(WIDE),
                    },
                }

                def switch(name):
                    app.api(
                        f"/sessions/{session}/commands",
                        {
                            "name": "/model",
                            "args": {"provider": name, "model": "fixture-model"},
                        },
                    ).close()

                def send(content):
                    start = len(provider.requests)
                    app.prompt(session, content).close()
                    app.idle(session)
                    return [r["request"] for r in provider.requests[start:]]

                app.api(f"/sessions/{session}/events", attach).close()
                app.idle(session)
                self.assertEqual(widths(provider.requests[-1]["request"]), [1200])

                switch(strict)
                sent = len(provider.requests)
                with self.assertRaises(urllib.error.HTTPError) as refused:
                    app.api(f"/sessions/{session}/events", attach).close()
                self.assertEqual(refused.exception.code, 409)
                self.assertIn("1000px edge limit", str(refused.exception))
                self.assertEqual(len(provider.requests), sent)

                strict_requests = send("show") + send("again")
                self.assertEqual(len(strict_requests), 3)
                for request in strict_requests:
                    self.assertEqual(widths(request), [1000])
                    self.assertEqual(json.dumps(request).count(NOTE), 1)
                output = next(
                    item
                    for item in strict_requests[1]["input"]
                    if item.get("type") == "function_call_output"
                )
                self.assertIn(
                    "1200x10 image is over this model's 1000px edge limit",
                    json.dumps(output),
                )
                notes = [
                    event["text"]
                    for event in app.events(session)
                    if event.get("source") == "image scaled"
                ]
                self.assertEqual(len(notes), 1, notes)
                self.assertIn(NOTE, notes[0])

                source = hashlib.sha256(WIDE_DATA.encode()).hexdigest()
                database = f"file:{app.home / 'albedo.sqlite'}?mode=ro"

                def rows(session, needle):
                    with sqlite3.connect(database, uri=True) as db:
                        return [
                            seq
                            for (seq,) in db.execute(
                                "SELECT seq FROM transcript WHERE session=? "
                                "AND instr(payload, CAST(? AS BLOB))>0 ORDER BY seq",
                                (session, needle),
                            )
                        ]

                # The original row keeps its image; the fit is a row of its own.
                self.assertEqual(len(rows(session, source)), 2)
                self.assertEqual(len(rows(session, "image_fit")), 1)

                # A fit is permanent: a looser provider keeps the copy.
                switch(loose)
                [back] = send("back")
                self.assertEqual(widths(back), [1000])
                self.assertEqual(json.dumps(back).count(NOTE), 1)

                # A fork from before the fit starts from the original.
                with sqlite3.connect(database, uri=True) as db:
                    # The assistant's answer to the first attachment.
                    (answer,) = db.execute(
                        "SELECT seq FROM transcript WHERE session=? "
                        "ORDER BY seq LIMIT 1 OFFSET 1",
                        (session,),
                    ).fetchone()
                with app.api(
                    f"/sessions/{session}/fork", {"checkpoint": answer}
                ) as response:
                    branch = json.load(response)["id"]
                start = len(provider.requests)
                app.prompt(branch, "branch").close()
                app.idle(branch)
                [forked] = [r["request"] for r in provider.requests[start:]]
                self.assertEqual(widths(forked), [1200])
                self.assertNotIn(NOTE, json.dumps(forked))
        finally:
            provider.close()


if __name__ == "__main__":
    unittest.main()
