"""The cargo shim through the real kernel: cargo goes through mbx, without
the SDKROOT that keeps mbx from caching native links."""

import json
import unittest

from harness import Albedo, Provider, python, text


def script_for(test):
    def script(request):
        if request["messages"][-1].get("role") == "user":
            return python(test.code)
        return text("done")

    return script


def cell_results(app, session):
    return [
        json.loads(part["value"])
        for entry in app.history(session)["items"]
        if entry["kind"] == "tool_result" and entry["tool"]["name"] == "python"
        for part in entry["content"]
        if part["kind"] == "json" and part["field"] == "result"
    ]


FAKE_MBX = """#!/bin/sh
echo "mbx $* sdk=${SDKROOT-unset} cc=${CC-unset} mode=$MBX_CARGO_SHIM_MODE"
"""


class CargoShimTests(unittest.TestCase):
    def setUp(self):
        self.provider = Provider(script_for(self))
        self.addCleanup(self.provider.close)
        self.app = Albedo(self.provider)
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)

    def test_cargo_runs_through_mbx_without_what_keeps_builds_apart(self):
        bin = self.app.workspace / "bin"
        bin.mkdir()
        (bin / "mbx").write_text(FAKE_MBX)
        (bin / "mbx").chmod(0o755)
        session = self.app.session()
        self.code = (
            f"path = {str(bin)!r} + ':' + os.environ['PATH']\n"
            "env = {'PATH': path, 'SDKROOT': '/nix/store/x-sdk', 'CC': 'clang'}\n"
            "job = run('cargo', 'build', env=env)\n"
            "await job\n"
            "print(job.tail().strip())\n"
        )
        self.app.prompt(session, "build").close()
        self.app.idle(session)
        output = cell_results(self.app, session)[-1]["output"]
        self.assertEqual(output.strip(), "mbx build sdk=unset cc=clang mode=1")


if __name__ == "__main__":
    unittest.main()
