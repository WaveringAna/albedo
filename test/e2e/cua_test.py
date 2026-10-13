"""End-to-end desktop GUI automation through the cua extension and real kernel."""

from __future__ import annotations

import base64
import json
import re
import struct
import unittest
import zlib

from harness import Albedo, Provider, python, text


def png_bytes(width: int, height: int) -> bytes:
    def chunk(kind: bytes, data: bytes) -> bytes:
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body))

    rows = b"".join(b"\x00" + b"\x20\x60\xa0" * width for _ in range(height))
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(rows))
        + chunk(b"IEND", b"")
    )


WINDOW_PNG = png_bytes(16, 12)
WINDOW_PNG_B64 = base64.b64encode(WINDOW_PNG).decode("ascii")

FAKE_DRIVER = f"""#!/usr/bin/env python3
import base64
import json
from pathlib import Path
import sys

PNG = base64.b64decode({WINDOW_PNG_B64!r})
PNG_B64 = {WINDOW_PNG_B64!r}
LOG = Path(sys.argv[0]).with_name("calls.jsonl")
SOCKET = sys.argv[sys.argv.index("--socket") + 1] if "--socket" in sys.argv else None

def record(entry):
    with LOG.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(entry) + "\\n")

def ok(req_id, structured=None, text_msg="ok", image_b64=None):
    content = [{{"type": "text", "text": text_msg}}]
    if image_b64 is not None:
        content.append({{"type": "image", "mimeType": "image/png", "data": image_b64}})
    result = {{"content": content, "isError": False}}
    if structured is not None:
        result["structuredContent"] = structured
    return {{"jsonrpc": "2.0", "id": req_id, "result": result}}

def err(req_id, code, message, extra=None):
    structured = {{"code": code, "effect": "refused", **(extra or {{}})}}
    return {{
        "jsonrpc": "2.0",
        "id": req_id,
        "result": {{
            "content": [{{"type": "text", "text": message}}],
            "isError": True,
            "structuredContent": structured,
        }},
    }}

for raw in sys.stdin:
    line = raw.strip()
    if not line:
        continue
    req = json.loads(line)
    req_id = req.get("id")
    method = req.get("method")
    params = req.get("params") or {{}}
    record({{"method": method, "params": params, "socket": SOCKET}})
    if method == "initialize":
        resp = {{
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {{
                "protocolVersion": "2025-06-18",
                "capabilities": {{"tools": {{}}}},
                "serverInfo": {{"name": "cua-driver", "version": "0.35.2"}},
            }},
        }}
    elif method == "tools/list":
        resp = {{
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {{
                "tools": [
                    {{"name": "list_apps", "description": "List apps", "inputSchema": {{"type": "object"}}}},
                    {{"name": "get_window_state", "description": "Observe window", "inputSchema": {{"type": "object"}}}},
                ]
            }},
        }}
    elif method == "tools/call":
        name = params.get("name")
        args = params.get("arguments") or {{}}
        if name == "list_apps":
            resp = ok(
                req_id,
                {{
                    "apps": [
                        {{
                            "pid": 4242,
                            "name": "Calculator",
                            "bundle_id": "com.apple.calculator",
                            "running": True,
                            "active": False,
                        }}
                    ]
                }},
            )
        elif name == "list_windows":
            resp = ok(
                req_id,
                {{
                    "windows": [
                        {{
                            "window_id": 101,
                            "pid": args.get("pid") or 4242,
                            "app_name": "Calculator",
                            "title": "Calculator",
                            "bounds": {{"x": 10, "y": 20, "width": 300, "height": 400}},
                            "is_on_screen": True,
                            "z_index": 1,
                        }}
                    ]
                }},
            )
        elif name == "launch_app":
            resp = ok(
                req_id,
                {{
                    "pid": 4242,
                    "bundle_id": args.get("bundle_id") or "com.apple.calculator",
                    "name": args.get("name") or "Calculator",
                    "windows": [{{"window_id": 101, "title": "Calculator"}}],
                }},
            )
        elif name in ("get_window_state", "get_desktop_state"):
            out_file = args.get("screenshot_out_file")
            if out_file:
                Path(out_file).write_bytes(PNG)
            resp = ok(
                req_id,
                {{
                    "pid": args.get("pid", 4242),
                    "window_id": args.get("window_id", 101),
                    "snapshot_id": "s0000002a",
                    "app_name": "Calculator",
                    "window_title": "Calculator",
                    "screenshot_width": 16,
                    "screenshot_height": 12,
                    "screenshot_file_path": out_file,
                    "elements": [
                        {{
                            "element_index": 0,
                            "element_token": "s0000002a:0",
                            "role": "window",
                            "label": "Calculator",
                            "depth": 0,
                            "enabled": True,
                        }},
                        {{
                            "element_index": 1,
                            "element_token": "s0000002a:1",
                            "role": "button",
                            "label": "Seven",
                            "value": "7",
                            "depth": 1,
                            "enabled": True,
                            "screenshot_frame": {{"x": 4, "y": 6, "w": 8, "h": 4}},
                        }},
                        {{
                            "element_index": 2,
                            "element_token": "s0000002a:2",
                            "role": "textfield",
                            "label": "Display",
                            "value": "42",
                            "depth": 1,
                            "enabled": True,
                        }},
                    ],
                }},
            )
        elif name == "zoom":
            resp = ok(
                req_id,
                {{"tool": "zoom", "args": args, "width": 8, "height": 4, "format": "png"}},
                image_b64=PNG_B64,
            )
        elif name == "click" and args.get("delivery_mode") == "background" and args.get("x") == 999:
            resp = err(
                req_id,
                "background_unavailable",
                "target is occluded at (999, 999)",
                {{"escalation": {{"recommended": "foreground"}}}},
            )
        elif name == "verify_state":
            resp = ok(
                req_id,
                {{"status": "satisfied", "predicates": [{{"outcome": "satisfied"}}]}},
            )
        else:
            resp = ok(
                req_id,
                {{"tool": name, "args": args, "effect": "confirmed", "route": "accessibility"}},
            )
    else:
        resp = {{"jsonrpc": "2.0", "id": req_id, "error": {{"code": -32601, "message": "not found"}}}}
    sys.stdout.write(json.dumps(resp) + "\\n")
    sys.stdout.flush()
"""


class CuaTests(unittest.TestCase):
    def _enable_cua(self, app: Albedo, session: str) -> None:
        route = f"/sessions/{session}?view=configuration"
        with app.api(route) as response:
            json.load(response)
            etag = response.headers["ETag"]
        with app.api(
            route,
            {"selection": {"extensions": {"cua": True}}},
            method="PATCH",
            headers={"If-Match": etag},
        ) as response:
            json.load(response)
        with app.api(f"/sessions/{session}/reload", {"target": "session"}) as response:
            reloaded = json.load(response)
        self.assertEqual(reloaded["session"]["state"], "applied", reloaded)

    def test_cua_workflow_attaches_screenshots_and_surfaces_structured_refusals(self):
        cell_code = ""

        def script(request):
            inputs = request.get("input", [])
            if inputs and inputs[-1].get("type") == "function_call_output":
                return text("done")
            return python(cell_code)

        provider = Provider(script)
        self.addCleanup(provider.close)
        with Albedo(provider, protocol="responses") as app:
            session = app.session()
            self._enable_cua(app, session)

            driver_bin = app.workspace / "bin" / "cua-driver"
            driver_bin.parent.mkdir(parents=True, exist_ok=True)
            driver_bin.write_text(FAKE_DRIVER, encoding="utf-8")
            driver_bin.chmod(0o755)
            log_file = driver_bin.with_name("calls.jsonl")
            marker = app.workspace / "cua-passed"

            cell_code = f"""
from pathlib import Path

# Missing explicit binary fails closed without falling back
try:
    cua.configure(executable={str(app.workspace / "bin" / "missing-driver")!r})
except CuaError as error:
    assert error.code == "executable_not_found", error.to_dict()
else:
    raise AssertionError("missing explicit binary should raise CuaError")

os.environ["ALBEDO_CUA_DRIVER"] = {str(driver_bin)!r}
os.environ["ALBEDO_CUA_SOCKET"] = "/tmp/env-cua.sock"
env_cfg = cua.configure()
assert env_cfg.executable == {str(driver_bin.resolve())!r}, env_cfg
assert env_cfg.socket == "/tmp/env-cua.sock", env_cfg
del os.environ["ALBEDO_CUA_DRIVER"]
del os.environ["ALBEDO_CUA_SOCKET"]

cfg = cua.configure(executable={str(driver_bin)!r}, socket="/tmp/fake-cua.sock")
assert cfg.executable == {str(driver_bin.resolve())!r}, cfg
assert cfg.socket == "/tmp/fake-cua.sock", cfg

tools = await cua.tools()
assert [t.name for t in tools] == ["list_apps", "get_window_state"], tools

apps = await cua.apps()
assert len(apps) == 1 and apps[0].pid == 4242, apps

launched = await cua.launch("com.apple.calculator")
assert launched.pid == 4242 and launched.window_id == 101 and launched.bundle_id == "com.apple.calculator", launched

wins = await cua.windows(launched)
assert len(wins) == 1 and wins[0].window_id == 101, wins

win = await cua.window("Calculator")
assert win.pid == 4242 and win.window_id == 101, win

snap = await win.observe()
rendered = snap.render()
assert rendered == cua.render(snap), rendered
assert "Snapshot s0000002a" in rendered and "[s0000002a:1] button \\"Seven\\"" in rendered, rendered

found_btns = snap.find(role="button")
assert len(found_btns) == 1 and found_btns[0].element_token == "s0000002a:1", found_btns

btn = snap.one(role="button", label="Seven")
assert btn.element_token == "s0000002a:1", btn

clicked = await win.click(btn)
assert clicked.args.element_token == "s0000002a:1", clicked
assert clicked.args.delivery_mode == "background", clicked
assert clicked.args.target == {{"kind": "window", "pid": 4242, "window_id": 101}}, clicked

dclicked = await win.double_click(btn)
assert dclicked.tool == "double_click" and dclicked.args.element_token == "s0000002a:1", dclicked

rclicked = await win.right_click(10, 20)
assert rclicked.tool == "right_click" and rclicked.args.window_id == 101, rclicked

typed = await win.type_text(btn, "42")
assert typed.args.text == "42" and typed.args.element_token == "s0000002a:1", typed

val_set = await win.set_value(btn, "84")
assert val_set.args.value == "84" and val_set.args.pid == 4242 and val_set.args.element_token == "s0000002a:1", val_set

keyed = await win.press_key("Return", modifiers=["shift"])
assert keyed.args.key == "Return" and keyed.args.modifiers == ["shift"], keyed

chord = await win.hotkey("cmd", "s")
assert chord.args["keys"] == ["cmd", "s"], chord

menu_res = await win.menu("View", "Scientific")
assert menu_res.args.path == ["View", "Scientific"], menu_res

frame_res = await win.frame(0, 0, 400, 500)
assert frame_res.args.width == 400 and frame_res.args.height == 500, frame_res

zoomed = await win.zoom(0, 0, 8, 4)
assert zoomed.tool == "zoom" and zoomed.args.window_id == 101 and zoomed.args.x2 == 8, zoomed

focused = await win.focus()
assert focused.tool == "bring_to_front" and focused.args.pid == 4242 and focused.args.window_id == 101, focused

cb_r = await cua.clipboard()
assert cb_r.tool == "clipboard_read" and cb_r.args.include_text is True, cb_r
cb_w = await cua.clipboard("hello clipboard")
assert cb_w.tool == "clipboard_write" and cb_w.args.text == "hello clipboard", cb_w

perms = await cua.permissions()
assert perms.tool == "check_permissions" and perms.args.prompt is False, perms
hlth = await cua.health(include=["accessibility"])
assert hlth.tool == "health_report" and hlth.args.include == ["accessibility"], hlth

rec_dir = {str(app.workspace / "rec")!r}
rec_start = await cua.start_recording(rec_dir, record_video=True)
assert rec_start.tool == "start_recording" and rec_start.args.output_dir == rec_dir and rec_start.args.record_video is True, rec_start
rec_st = await cua.recording_state()
assert rec_st.tool == "get_recording_state", rec_st
rec_stop = await cua.stop_recording()
assert rec_stop.tool == "stop_recording", rec_stop

verified = await win.verify(
    {{"element": {{"selector": {{"label_contains": "Display"}}, "value_equals": "42"}}}},
)
assert verified.status == "satisfied", verified

killed = await win.kill()
assert killed.tool == "kill_app" and killed.args.pid == 4242, killed

# Structured background_unavailable refusal surfaces code + escalation details
try:
    await win.click(999, 999)
except CuaError as error:
    assert error.code == "background_unavailable", error.to_dict()
    assert error.details["escalation"]["recommended"] == "foreground", error.to_dict()
else:
    raise AssertionError("expected background_unavailable CuaError")

await cua.close()
Path({str(marker)!r}).write_text("ok", encoding="utf-8")
"""
            app.prompt(session, "drive calculator").close()
            app.idle(session)

            self.assertTrue(marker.exists(), app.stream_page(session))
            sent = json.dumps(provider.requests[-1]["request"])
            encoded = re.findall(r"data:image/png;base64,([A-Za-z0-9+/=]+)", sent)
            self.assertEqual(len(encoded), 2)
            self.assertEqual(base64.b64decode(encoded[0]), WINDOW_PNG)
            self.assertEqual(base64.b64decode(encoded[1]), WINDOW_PNG)

            calls = [
                json.loads(line)
                for line in log_file.read_text(encoding="utf-8").splitlines()
                if line.strip()
            ]
            self.assertEqual(calls[0]["method"], "initialize")
            self.assertEqual(calls[0]["socket"], "/tmp/fake-cua.sock")
            self.assertEqual(calls[-1]["params"].get("name"), "end_session")


if __name__ == "__main__":
    unittest.main()
