"""Optional Chrome scenarios exercise the CDP client against a real browser."""

from __future__ import annotations

from pathlib import Path
import shutil
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "priv" / "python"))

from albedo_plugins.browser import spawn, render, one  # noqa: E402


class BrowserIntegrationTest(unittest.IsolatedAsyncioTestCase):
    """End-to-end integration tests using local Chromium if present."""

    async def asyncSetUp(self):
        self.has_chrome = (
            shutil.which("chromium") is not None
            or shutil.which("google-chrome") is not None
            or Path("/Applications/Chromium.app/Contents/MacOS/Chromium").exists()
            or Path(
                "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
            ).exists()
        )

    async def test_spawn_navigate_observe_interact_close(self):
        if not self.has_chrome:
            self.skipTest("No Chrome or Chromium installed on this system")

        b = await spawn(headless=True)
        try:
            page = await b.new_page()
            html = (
                "data:text/html,"
                "<!doctype html>"
                "<html><head><title>Albedo Test</title></head>"
                "<body>"
                "<h1>Header</h1>"
                "<label for='name'>Name</label><input id='name' value='initial'>"
                "<button id='save' onclick='window.clicked=true'>Save</button>"
                "</body></html>"
            )
            await page.goto(html)

            # Observe
            obs = await page.observe()
            self.assertEqual(obs["title"], "Albedo Test")
            text = render(obs)
            self.assertIn("Header", text)
            self.assertIn("Save", text)

            # Find and One
            btn = one(obs, role="button", name="Save")
            self.assertIsNotNone(btn)
            field = one(obs, role="textbox", name="Name")
            self.assertIsNotNone(field)

            # Fill and Click
            await page.fill(field, "new value")
            self.assertEqual(
                await page.evaluate("document.querySelector('#name').value"),
                "new value",
            )

            await page.click(btn)
            self.assertTrue(await page.evaluate("window.clicked"))

            # Close page
            await page.close()
        finally:
            await b.close()


if __name__ == "__main__":
    unittest.main()
