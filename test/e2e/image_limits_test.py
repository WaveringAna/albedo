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

from harness import Albedo, Provider, exclusive, operation_id, python, text


def png(width, height, metadata=b""):
    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body))

    rows = b"".join(b"\x00" + b"\x80\x40\x20" * width for _ in range(height))
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + (chunk(b"npAD", metadata) if metadata else b"")
        + chunk(b"IDAT", zlib.compress(rows))
        + chunk(b"IEND", b"")
    )


# An ssh first on the kernel's PATH that runs the command right here, so
# remote.connect boots, stages and talks to a real remote kernel.
LOOPBACK_SSH = """#!/bin/sh
while [ $# -gt 0 ]; do
  case "$1" in
    -o) shift 2 ;;
    -*) shift ;;
    *) break ;;
  esac
done
shift
exec sh -c "$*"
"""

WIDE = png(1200, 10)
WIDE_DATA = base64.b64encode(WIDE).decode()
NOTE = "An earlier image was scaled from 1200x10 to 1000x"


def widths(request):
    """The pixel width of every PNG the request carries."""
    found = re.findall(r"data:image/png;base64,([A-Za-z0-9+/=]+)", json.dumps(request))
    return [struct.unpack(">I", base64.b64decode(data)[16:20])[0] for data in found]


def cell_result(output):
    """The python tool's result: plain text, or the text part beside images."""
    body = output["output"]
    if isinstance(body, str):
        return json.loads(body)
    [text] = [part["text"] for part in body if part.get("type") == "input_text"]
    return json.loads(text)


class ImageLimitsTest(unittest.TestCase):
    @exclusive
    def test_large_valid_image_remains_available_after_durable_reload(self):
        # A valid ancillary chunk makes encoded length exceed 5 MiB while the
        # decoded PNG remains below the advertised file-size boundary.
        image = png(2, 3, b"x" * (4 * 1024 * 1024))
        data = base64.b64encode(image).decode()
        self.assertLess(len(image), 5 * 1024 * 1024)
        self.assertGreater(len(data), 5 * 1024 * 1024)
        provider = Provider(lambda _: text("image accepted"))
        self.addCleanup(provider.close)
        with Albedo(provider, protocol="responses") as app:
            session = app.session()
            app.api(
                f"/sessions/{session}/inputs/{operation_id()}",
                {
                    "kind": "message",
                    "text": "look",
                    "image": {"mime_type": "image/png", "data": data},
                },
                method="PUT",
            ).close()
            app.idle(session)
            app.restart()
            app.prompt(session, "look again").close()
            app.idle(session)
            sent = json.dumps(provider.requests[-1]["request"])
            encoded = re.findall(r"data:image/png;base64,([A-Za-z0-9+/=]+)", sent)
            self.assertEqual(len(encoded), 1)
            self.assertEqual(base64.b64decode(encoded[0]), image)

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
                    "kind": "message",
                    "text": "look",
                    "image": {"mime_type": "image/png", "data": WIDE_DATA},
                }

                def switch(name):
                    with app.api(f"/sessions/{session}?view=configuration") as response:
                        json.load(response)
                        revision = response.headers["ETag"]
                    app.api(
                        f"/sessions/{session}?view=configuration",
                        {"provider_profile": name, "model": "fixture-model"},
                        method="PATCH",
                        headers={"If-Match": revision},
                    ).close()

                def attach_image():
                    return app.api(
                        f"/sessions/{session}/inputs/{operation_id()}",
                        attach,
                        method="PUT",
                    )

                def send(content):
                    start = len(provider.requests)
                    app.prompt(session, content).close()
                    app.idle(session)
                    return [r["request"] for r in provider.requests[start:]]

                attach_image().close()
                app.idle(session)
                self.assertEqual(widths(provider.requests[-1]["request"]), [1200])

                switch(strict)
                sent = len(provider.requests)
                with self.assertRaises(urllib.error.HTTPError) as refused:
                    attach_image().close()
                self.assertEqual(refused.exception.code, 409)
                self.assertIn(
                    "1000px edge limit", json.load(refused.exception)["detail"]
                )
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
                # show_image refuses it at the call, so the cell fails there.
                result = cell_result(output)
                self.assertEqual(result["status"], "error")
                self.assertIn(
                    "ValueError: 1200x10 image is over this model's 1000px edge limit",
                    result["output"],
                )
                self.assertNotIn("image_errors", result)
                entries = app.history(session)["items"]
                notes = [
                    part["text"]
                    for entry in entries
                    if entry["kind"] == "image_fit"
                    for part in entry["content"]
                    if part["kind"] == "text"
                ]
                self.assertEqual(len(notes), 1, notes)
                self.assertIn(NOTE, notes[0])
                original = [
                    entry
                    for entry in entries
                    if entry["kind"] == "user"
                    and any(
                        part["kind"] == "text" and part["text"] == "look"
                        for part in entry["content"]
                    )
                ]
                self.assertEqual(len(original), 1)
                [image] = [
                    part["image"]
                    for part in original[0]["content"]
                    if part["kind"] == "image"
                ]
                self.assertEqual(image["width"], 1200)
                self.assertEqual(image["height"], 10)
                self.assertEqual(image["original_bytes"], len(WIDE))

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
                checkpoint = next(
                    entry["checkpoint_id"]
                    for entry in entries
                    if entry["kind"] == "assistant"
                )
                branch = operation_id()
                app.api(
                    f"/sessions/{branch}",
                    {
                        "kind": "fork",
                        "source_session_id": session,
                        "checkpoint_id": checkpoint,
                    },
                    method="PUT",
                    headers={"If-None-Match": "*"},
                ).close()
                start = len(provider.requests)
                app.prompt(branch, "branch").close()
                app.idle(branch)
                [forked] = [r["request"] for r in provider.requests[start:]]
                self.assertEqual(widths(forked), [1200])
                self.assertNotIn(NOTE, json.dumps(forked))
        finally:
            provider.close()

    def test_a_remote_image_is_shown_under_the_same_limits(self):
        cell = (
            """import os
os.makedirs("bin", exist_ok=True)
with open("bin/ssh", "w") as script:
    script.write(%r)
os.chmod("bin/ssh", 0o755)
with open("bin/loginsh", "w") as script:
    script.write('#!/bin/sh\\n[ "$1" = -l ] && shift\\nexec /bin/sh "$@"\\n')
os.chmod("bin/loginsh", 0o755)
os.environ["SHELL"] = os.path.abspath("bin/loginsh")
os.environ["PATH"] = os.path.abspath("bin") + os.pathsep + os.environ["PATH"]
rem = await remote.connect("loopback")
try:
    print(await rem.show_image("small.png"))
    await rem.show_image("wide.png")
finally:
    await rem.close()
"""
            % LOOPBACK_SSH
        )

        def reply(request):
            if request["input"][-1].get("type") == "function_call_output":
                return text("done")
            return python(cell)

        provider = Provider(reply)
        profile = {
            "baseUrl": provider.url,
            "apiKey": "fixture-key",
            "model": "fixture-model",
            "protocol": "responses",
            "imageEdge": 1000,
        }
        try:
            with Albedo(
                provider,
                protocol="responses",
                providers={f"strict-{provider.route}": profile},
            ) as app:
                (app.workspace / "small.png").write_bytes(png(10, 10))
                (app.workspace / "wide.png").write_bytes(WIDE)
                session = app.session()
                app.prompt(session, "remote").close()
                app.idle(session)
                [request] = [
                    r["request"]
                    for r in provider.requests
                    if r["request"]["input"][-1].get("type") == "function_call_output"
                ]
                output = next(
                    item
                    for item in request["input"]
                    if item.get("type") == "function_call_output"
                )
                result = cell_result(output)
                # The small image came over the connection and went on to the
                # model; the wide one failed the cell at its call.
                self.assertIn("attached image/png", result["output"])
                self.assertEqual(result["status"], "error")
                self.assertIn(
                    "ValueError: 1200x10 image is over this model's 1000px edge limit",
                    result["output"],
                )
                self.assertEqual(widths(request), [10])
        finally:
            provider.close()
