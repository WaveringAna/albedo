# cua

the `cua` extension (requires `python`, installed and off by default) drives
native desktop GUI applications through [`cua-driver`](https://github.com/trycua/cua)
from the Python kernel (`priv/python/albedo_plugins/cua.py`).

- **binary resolution**: resolved lazily on the first `cua.*` call (or
  `cua.configure(executable=..., socket=...)`) in order:
  1. `cua.configure(executable=...)`
  2. `$ALBEDO_CUA_DRIVER`
  3. `$CUA_DRIVER_PATH`
  4. `extensions.json` under `"cua": {"executable": "...", "socket": "..."}`
  5. `cua-driver` on `PATH`
  6. standard install paths (`~/.local/bin/cua-driver`,
     `/Applications/CuaDriver.app/Contents/MacOS/cua-driver`,
     `~/Applications/CuaDriver.app/Contents/MacOS/cua-driver`,
     `%LOCALAPPDATA%\Programs\Cua\cua-driver\bin\cua-driver.exe`)
- **transport and lifecycle**: one persistent `cua-driver mcp` stdio subprocess
  per kernel (`DO_NOT_TRACK=1`, `CUA_TELEMETRY=0`), initialized with a fresh
  kernel-scoped `session` label (`albedo-<hex>`) whenever the subprocess starts
  so snapshot `element_token` handles remain valid across cells and across
  `await cua.close()` restarts. `await cua.close()` and kernel shutdown call
  `end_session` and terminate the stdio subprocess.
- **window handles and observations**: `await cua.windows(pid=None)` returns
  bound `Window` handles (`Record` subclasses carrying `pid` and `window_id`),
  `await cua.window(target=None, window_id=None, app=None, title=None)` resolves
  a single `Window` handle by app/title substring or `(pid, window_id)`, and
  `await cua.launch(...)` returns a bound `Window` handle when the launched app
  exposes a single window. `await win.observe()` (or
  `await cua.observe(window_or_pid, window_id=None)` and `await cua.desktop()`)
  captures the screenshot into a temporary PNG (`screenshot_out_file`), attaches
  its bytes to the running cell via `api.attach_image`, and returns an
  `Observation` (`Record` subclass with `.render()`, `.find(...)`, and
  `.one(...)` alongside `cua.render(snap)`, `cua.find(snap, ...)`, and
  `cua.one(snap, ...)`). `await win.zoom(x1, y1, x2, y2)` (or
  `await cua.zoom(target, x1, y1, x2, y2)`) crops a full-resolution region and
  attaches the cropped image to the cell.
- **actions**: bound on `Window` (`await win.click(...)`,
  `await win.double_click(...)`, `await win.right_click(...)`,
  `await win.move(x, y)`, `await win.drag(...)`, `await win.scroll(...)`,
  `await win.type_text(...)`, `await win.set_value(...)`,
  `await win.press_key(...)`, `await win.hotkey(...)`, `await win.menu(...)`,
  `await win.frame(...)`, `await win.focus()`, `await win.kill()`,
  `await win.verify(...)`) and top-level on `cua.*(target, ...)`. Window targets
  default to `delivery_mode="background"` and `"desktop"` defaults to
  `delivery_mode="foreground"`, raising `CuaError` (with `error.code` and
  `error.details`) on tool refusals such as `background_unavailable` or
  `stale_element_token`.
- **clipboard, permissions, health, and recording**:
  `await cua.clipboard(text=None, file_path=None, image_path=None)` reads
  (`clipboard_read`) or writes (`clipboard_write`) the system clipboard;
  `await cua.permissions(prompt=False)` and `await cua.health()` wrap
  `check_permissions` and `health_report`; `await cua.start_recording(output_dir, record_video=False)`,
  `await cua.stop_recording()`, and `await cua.recording_state()` wrap
  per-turn trajectory and ScreenCaptureKit MP4 recording.
- **escape hatch**: `await cua.tools()` lists the live `cua-driver` tool schemas
  and `await cua.call(tool, arguments=None, **kwargs)` invokes any tool
  directly.
- **tests**: `test/e2e/cua_test.py` drives the real daemon and kernel against a
  hermetic fake `cua-driver` MCP script; `test/harness/api_docs_test.py` checks
  that every public `cua` method is documented in the model prompt.
