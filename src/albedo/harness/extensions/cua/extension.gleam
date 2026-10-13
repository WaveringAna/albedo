//// Native desktop GUI automation via cua-driver.

import albedo/harness/extension

pub fn extension() -> extension.Extension {
  extension.python_module(
    "cua",
    "Control native desktop GUI apps through cua-driver from Python.",
    "cua",
    "cua drives native desktop apps through cua-driver ($ALBEDO_CUA_DRIVER, $CUA_DRIVER_PATH,"
      <> " the \"cua\" section of extensions.json, or cua-driver on PATH; cua.configure(executable=..., socket=...)"
      <> " overrides it)."
      <> " await cua.apps() lists apps, await cua.windows(pid=None) lists Window handles,"
      <> " win = await cua.window(target=None, window_id=None, app=None, title=None) resolves one Window handle, and"
      <> " await cua.launch(name_or_bundle_id, **options) starts an app in the background."
      <> " snap = await win.observe() (or await cua.observe(window_or_pid, window_id=None) or await cua.desktop())"
      <> " snapshots a window or the primary desktop, attaches its screenshot to the cell, and"
      <> " snap.render(), snap.find(...), and snap.one(...) (or cua.render(snap), cua.find(snap, ...), cua.one(snap, ...))"
      <> " inspect its elements. await win.zoom(x1, y1, x2, y2) (or await cua.zoom(target, x1, y1, x2, y2))"
      <> " crops a high-res region and attaches it."
      <> " Act in the background by default on a Window handle (`await win.click(...)`, `await win.type_text(...)`, etc.)"
      <> " or via await cua.click(target, element_or_x=None, y=None, **options),"
      <> " await cua.double_click(...), await cua.right_click(...), await cua.move(target, x, y),"
      <> " await cua.drag(target, from_x, from_y, to_x, to_y, **options),"
      <> " await cua.scroll(target, x, y, direction=\"down\", **options),"
      <> " await cua.type_text(target, text, **options), await cua.set_value(target, value, **options),"
      <> " await cua.press_key(target, key, **options), await cua.hotkey(target, *keys, **options),"
      <> " await cua.menu(target, *path), await cua.frame(target, x, y, width, height),"
      <> " await cua.focus(target), and await cua.kill(target)."
      <> " await cua.clipboard(text=None, file_path=None, image_path=None) reads or writes the system clipboard;"
      <> " await cua.permissions(prompt=False) and await cua.health() inspect permissions and health;"
      <> " await cua.start_recording(output_dir, record_video=False), await cua.stop_recording(), and"
      <> " await cua.recording_state() manage trajectory and screen recordings."
      <> " await cua.verify(target, expect, **options) checks postconditions, await cua.tools() lists"
      <> " raw driver tools, await cua.call(tool, arguments=None, **kwargs) calls any tool, and"
      <> " await cua.close() ends the driver session. Failures raise CuaError.",
    ["python"],
  )
}
