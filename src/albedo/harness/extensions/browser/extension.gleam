//// Browser automation: control Chrome or Chromium through CDP from Python.

import albedo/harness/extension

pub fn extension() -> extension.Extension {
  extension.python_module(
    "browser",
    "Control Chrome or Chromium through CDP from Python.",
    "browser",
    "b = await browser.spawn() (or await browser.connect()) controls Chrome or Chromium through CDP."
      <> " page = await b.new_page() creates a page."
      <> " On a page: await page.goto(url), snapshot = await page.observe(), browser.render(snapshot),"
      <> " await page.click(node), await page.fill(node, text), await page.type(node, text),"
      <> " await page.select(node, value), await page.hover(node), await page.press(key),"
      <> " await page.wait_for(...), and await page.screenshot()."
      <> " browser.find(snapshot, ...) and browser.one(snapshot, ...) locate nodes in an observation."
      <> " Finish with await b.close(). Failures raise BrowserError.",
    ["python"],
  )
}
