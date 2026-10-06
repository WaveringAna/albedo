"""Browser discovery through the real kernel, without starting a GUI app."""

import unittest

from harness import Albedo, Provider, exclusive, python, text


@exclusive
class BrowserTests(unittest.TestCase):
    def test_headless_shell_preserves_overrides_headed_launches_and_fallback(self):
        code = ""

        def script(request):
            if request["messages"][-1].get("role") == "user":
                return python(code)
            return text("done")

        def prepare(app):
            nonlocal code
            bin_dir = app.workspace / "bin"
            bin_dir.mkdir()
            chrome = bin_dir / "chromium"
            shell = bin_dir / "headless-shell"
            shell_link = app.home / "browsers/chrome-headless-shell"
            shell_link.parent.mkdir()
            shell_link.symlink_to(shell)
            for executable in (chrome, shell):
                executable.write_text(
                    '#!/bin/sh\necho "test browser exited" >&2\nexit 23\n'
                )
                executable.chmod(0o755)
            for variable in (
                "ALBEDO_BROWSER_EXECUTABLE",
                "PRIME_BROWSER_EXECUTABLE",
                "CHROME_PATH",
            ):
                app.daemon.env[variable] = ""

            code = f"""
from pathlib import Path
from albedo_plugins.browser import LaunchError
chrome = {str(chrome)!r}
shell = {str(shell)!r}
os.environ['PATH'] = {str(bin_dir)!r}
async def check(expected, **options):
    try:
        b = await browser.spawn(sandbox=False, timeout=3, **options)
    except LaunchError as error:
        assert error.details['executable'] == expected, error.to_dict()
        assert error.details['reason'] == 'process_exited', error.to_dict()
        assert 'test browser exited' in error.details['stderr_tail'], error.to_dict()
        assert not Path(error.details['profile']).exists()
    else:
        await b.close()
        raise AssertionError('test browser should exit during startup')
await check(shell)
path_shell = Path({str(bin_dir / "chrome-headless-shell")!r})
path_shell.symlink_to(chrome)
await check(chrome)
path_shell.unlink()
await check(chrome, headless=False)
await check(chrome, executable=chrome)
os.environ['ALBEDO_BROWSER_EXECUTABLE'] = chrome
await check(chrome)
del os.environ['ALBEDO_BROWSER_EXECUTABLE']
Path({str(shell_link)!r}).unlink()
await check(chrome)
try:
    await browser.spawn(executable={str(shell_link)!r}, sandbox=False)
except LaunchError as error:
    assert error.details['reason'] == 'executable_not_found', error.to_dict()
else:
    raise AssertionError('missing explicit browser must not fall back')
Path({str(app.workspace / "passed")!r}).write_text('passed')
"""

        provider = Provider(script)
        self.addCleanup(provider.close)
        with Albedo(provider, prepare=prepare) as app:
            session = app.session()
            app.prompt(session, "try the installed browsers").close()
            app.idle(session)
            self.assertTrue((app.workspace / "passed").exists(), app.history(session))
