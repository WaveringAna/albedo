"""The explicit setup(api) -> REPL-bindings boundary; no service credentials."""
import asyncio
from pathlib import Path
import sys
from types import ModuleType
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "priv" / "python"))
from albedo_api import PythonApi, load_plugins


class PluginTest(unittest.TestCase):
    def setUp(self):
        self.loop = asyncio.new_event_loop()
        self.addCleanup(self.loop.close)
        self.cleanup = []
        self.events = []
        self.api = PythonApi(self.loop, None, RuntimeError, None, 100,
                             self.events.append, self.cleanup.append, lambda _: None)
        self.namespace = {"__name__": "__main__", "cells": object(), "output": object()}

    def module(self, setup):
        module = ModuleType("fixture.tools")
        module.setup = setup
        return module

    def test_explicit_dotted_plugin_injects_callable_state_and_cleanup(self):
        def setup(api):
            api.on_shutdown(lambda: self.events.append("closed"))
            async def answer():
                return 42
            return {"answer": answer}
        with patch.dict(sys.modules, {"fixture.tools": self.module(setup)}):
            load_plugins(["fixture.tools"], self.api, self.namespace)
        self.assertEqual(self.loop.run_until_complete(self.namespace["answer"]()), 42)
        self.cleanup[0]()
        self.assertEqual(self.events, ["closed"])

    def test_composition_rejects_duplicate_and_reserved_bindings(self):
        for exports in [{"cells": 1}, {"output": 1}, {"__name__": 1}, {"bad-name": 1}, {"class": 1}, {1: 2}, ["not a dict"]]:
            with self.subTest(exports=exports), patch.dict(sys.modules, {"fixture.tools": self.module(lambda _: exports)}):
                with self.assertRaisesRegex(RuntimeError, "Python plugin fixture.tools"):
                    load_plugins(["fixture.tools"], self.api, self.namespace)
        with patch.dict(sys.modules, {"fixture.tools": self.module(lambda _: {"answer": 42})}):
            load_plugins(["fixture.tools"], self.api, self.namespace)
            with self.assertRaisesRegex(RuntimeError, "duplicate or reserved"):
                load_plugins(["fixture.tools"], self.api, self.namespace)

    def test_modules_are_validated_before_setup_and_errors_name_the_plugin(self):
        with patch("albedo_api.importlib.import_module") as importer:
            for names in [["bash", "albedo_plugins.bash"], ["fixture..tools"], ["fixture.class"]]:
                with self.assertRaises(ValueError):
                    load_plugins(names, self.api, self.namespace)
            importer.assert_not_called()
        def broken(_):
            raise ValueError("setup failed")
        with patch.dict(sys.modules, {"fixture.tools": self.module(broken)}):
            with self.assertRaisesRegex(RuntimeError, "fixture.tools: setup failed"):
                load_plugins(["fixture.tools"], self.api, self.namespace)


if __name__ == "__main__":
    unittest.main()
