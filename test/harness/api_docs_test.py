"""Every public call in the model's Python namespace is named in the text the
model is given. Agents otherwise discover the API with dir() and help(), or
miss parts of it entirely (files.write, cells.last_id, and bash's timeout were
all real but undocumented)."""

import asyncio
import importlib
import inspect
import re
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "priv" / "python"))
import albedo_kernel as kernel  # noqa: E402
from albedo_api import PythonApi  # noqa: E402

# Plumbing the kernel or the remote relay calls; not part of the model's API.
INTERNAL = {"run.Job.claim", "remote.Remote.connect_many"}


def model_text() -> str:
    """Every string literal the harness can show the model, joined."""
    sources = [
        *ROOT.glob("src/albedo/harness/extensions/*/extension.gleam"),
        ROOT / "src/albedo/harness/command.gleam",
    ]
    literals = []
    for source in sources:
        literals += re.findall(r'"((?:[^"\\]|\\.)*)"', source.read_text())
    return "".join(literals).replace('\\"', '"')


def namespace() -> dict[str, object]:
    loop = asyncio.new_event_loop()

    async def host(method, args):
        return [] if method == "commands.list" else {}

    api = PythonApi(
        loop,
        host,
        RuntimeError,
        None,
        100,
        lambda e: None,
        lambda c: None,
        lambda _: None,
    )
    bindings = {
        "cells": kernel.Cells(),
        "output": kernel.Output(),
        "show_image": kernel.show_image,
    }
    for name in ["run", "work", "files", "skills", "commands", "remote", "view"]:
        result = importlib.import_module("albedo_plugins." + name).setup(api)
        bindings.update(
            loop.run_until_complete(result) if inspect.isawaitable(result) else result
        )
    loop.close()
    return bindings


class ApiDocsTest(unittest.TestCase):
    def test_every_public_call_is_named_for_the_model(self):
        text = model_text()
        missing = []
        for name, value in namespace().items():
            if isinstance(value, (dict, type)):
                if name not in text:
                    missing.append(name)
                continue
            if inspect.isfunction(value):
                if f"{name}(" not in text:
                    missing.append(f"{name}(")
                continue
            for attribute in dir(type(value)) + list(vars(value)):
                if (
                    attribute.startswith("_")
                    or f"{type(value).__module__.split('.')[-1]}.{type(value).__name__}.{attribute}"
                    in INTERNAL
                ):
                    continue
                if not re.search(
                    rf"\b{re.escape(name)}\.{re.escape(attribute)}\b", text
                ):
                    missing.append(f"{name}.{attribute}")
        self.assertEqual(
            sorted(set(missing)), [], "public API the model is never told about"
        )

    def test_job_handles_are_documented(self):
        from albedo_plugins import run

        text = model_text()
        public = [
            name
            for name in vars(run.Job)
            if not name.startswith("_") and f"run.Job.{name}" not in INTERNAL
        ]
        fields = ["id", "command", "exit_code", "duration", "waited", "timed_out"]
        missing = [
            name for name in public + fields if not re.search(rf"\bjob\.{name}\b", text)
        ]
        self.assertEqual(
            missing, [], "job handle members the model is never told about"
        )


if __name__ == "__main__":
    unittest.main()
