"""Shared editable daemon and model-driven cells for kernel E2E scenarios."""

import json
from pathlib import Path
import shutil
import tempfile

import harness
from harness import Albedo, Provider, latest_user

MARKER = '\nMARKER = "new bundle"\n'


def editable_daemon(root):
    """A copy of the test daemon whose python bundle is ours to edit: every
    package links back to the snapshot except albedo's priv/python."""
    assert harness._executable is not None, "the runner snapshots the daemon first"
    source = Path(harness._executable).parent
    out = Path(tempfile.mkdtemp(prefix="daemon-", dir=root))
    for package in source.iterdir():
        if package.is_dir() and package.name != "albedo":
            (out / package.name).symlink_to(package)
    albedo = out / "albedo"
    (albedo / "priv").mkdir(parents=True)
    (albedo / "ebin").symlink_to(source / "albedo" / "ebin")
    priv = (source / "albedo" / "priv").resolve()
    for entry in priv.iterdir():
        if entry.name == "python":
            shutil.copytree(
                entry,
                albedo / "priv" / "python",
                ignore=shutil.ignore_patterns("__pycache__"),
            )
        else:
            (albedo / "priv" / entry.name).symlink_to(entry)
    launcher = out / "albedo-daemon"
    launcher.write_text(
        "#!/bin/sh\n"
        f"exec erl -pa {out}/*/ebin -eval 'albedo@@main:run(albedo)' -noshell -extra\n"
    )
    launcher.chmod(0o755)
    return launcher, albedo / "priv" / "python"


class ModelCells:
    """Run queued Python cells through the fixture's provider and session."""

    cells: list[str]
    app: Albedo
    provider: Provider
    session: str

    def cell(self, code):
        """Run one cell through a model turn; its result and the turn's prompt."""
        self.cells.append(code)
        self.app.prompt(self.session, "run it").close()
        self.app.idle(self.session)
        results = [
            json.loads(part["value"])
            for entry in self.app.history(self.session)["items"]
            if entry["kind"] == "tool_result" and entry["tool"]["name"] == "python"
            for part in entry["content"]
            if part["kind"] == "json" and part["field"] == "result"
        ]
        request = next(
            r["request"]
            for r in reversed(self.provider.requests)
            if any(i.get("role") == "user" for i in r["request"]["input"])
        )
        prompt = latest_user(request)
        return results[-1], prompt
