"""Optional Chrome scenarios exercise the CDP client against a real browser."""

from __future__ import annotations

from pathlib import Path
import shutil
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "priv" / "python"))

from albedo_plugins.browser import spawn, render, one  # noqa: E402
from albedo_plugins.browser.errors import NotActionable  # noqa: E402
from albedo_plugins.browser.launch import _command  # noqa: E402


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
                "<label for='pick'>Pick</label>"
                "<select id='pick' onchange='window.picked=this.value'>"
                "<option value='a'>Alpha</option>"
                "<option value='b'>Beta</option>"
                "<option value='c' disabled>Gamma</option>"
                "</select>"
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

            # Select takes an option's value or its label
            picker = one(obs, role="combobox", name="Pick")
            self.assertIsNotNone(picker)
            await page.select(picker, "b")
            self.assertEqual(
                await page.evaluate(
                    "[window.picked, document.querySelector('#pick').value]"
                ),
                ["b", "b"],
            )
            await page.select(picker, "Alpha")
            self.assertEqual(
                await page.evaluate("document.querySelector('#pick').value"), "a"
            )
            with self.assertRaises(NotActionable) as refused:
                await page.select(picker, "Gamma")
            self.assertEqual(refused.exception.details["found"], False)

            # Close page
            await page.close()
        finally:
            await b.close()


PROFILE = Path("/tmp/profile")


class LaunchCommandTest(unittest.TestCase):
    """The argv albedo hands Chrome, read without starting one."""

    def test_macos_launches_stay_out_of_the_login_keychain(self):
        # Chrome raises a blocking "Keychain Not Found" panel when it cannot
        # resolve a default keychain for its own process.
        command = _command(
            "/opt/chrome", PROFILE, headless=False, sandbox=True, args=[]
        )
        self.assertEqual("--use-mock-keychain" in command, sys.platform == "darwin")

    def test_the_owned_options_are_the_ones_asked_for(self):
        command = _command(
            "/opt/chrome", PROFILE, headless=False, sandbox=False, args=["--lang=en"]
        )
        self.assertEqual(command[0], "/opt/chrome")
        self.assertIn("--user-data-dir=/tmp/profile", command)
        self.assertIn("--remote-debugging-port=0", command)
        self.assertNotIn("--headless=new", command)
        self.assertIn("--no-sandbox", command)
        self.assertEqual(command[-2:], ["--lang=en", "about:blank"])
        headless = _command(
            "/opt/chrome", PROFILE, headless=True, sandbox=True, args=[]
        )
        self.assertIn("--headless=new", headless)


if __name__ == "__main__":
    unittest.main()
