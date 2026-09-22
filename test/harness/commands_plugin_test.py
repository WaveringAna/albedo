"""The typed binding mint: no self leakage, honest help, strict dispatch."""
import asyncio
import importlib.util
import inspect
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "priv" / "python"))

SPEC = importlib.util.spec_from_file_location(
    "albedo_plugins.commands", Path(__file__).resolve().parents[2] / "priv" / "python" / "albedo_plugins" / "commands.py")
commands_plugin = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(commands_plugin)

CATALOG = [
    {"name": "/model", "description": "Show or switch", "method": "model", "usage": "/model [model] [provider]",
     "arguments": [{"name": "model", "description": "model id", "required": False},
                   {"name": "provider", "description": "provider", "required": False}],
     "modelCallable": True, "userTurn": False},
    {"name": "/locked", "description": "User only", "method": "locked", "usage": "/locked",
     "arguments": [], "modelCallable": False, "userTurn": False},
    {"name": "/catalog", "description": "Reserved", "method": "catalog_", "usage": "/catalog",
     "arguments": [], "modelCallable": True, "userTurn": False},
    {"name": "/__init__", "description": "Hostile", "method": "__init___", "usage": "/__init__",
     "arguments": [], "modelCallable": True, "userTurn": False},
]


class FakeApi:
    def __init__(self):
        self.calls = []
        self.HostError = RuntimeError

    async def host(self, method, args):
        self.calls.append((method, args))
        if method == "commands.list":
            return CATALOG
        return {"echo": args}


class CommandsPluginTest(unittest.TestCase):
    def boot(self):
        return asyncio.run(commands_plugin.setup(FakeApi()))

    def test_minted_methods_are_plain_functions_and_keep_exact_arguments(self):
        ns = self.boot()
        commands = ns["commands"]
        minted = vars(type(commands))
        for name in ("model", "catalog_", "__init___"):
            self.assertIn(name, minted)
        # One positional argument arrives as one argument: the method is a
        # staticmethod, so no self is ever injected.
        result = asyncio.run(commands.model("one  two"))
        self.assertEqual(result, {"echo": {"name": "/model", "args": {"model": "one  two"}}})

    def test_user_only_commands_are_not_minted(self):
        commands = self.boot()["commands"]
        self.assertFalse(hasattr(commands, "locked"))
        self.assertTrue(asyncio.run(commands.catalog()))

    def test_reserved_names_are_mintable_and_never_shadow_builtins(self):
        commands = self.boot()["commands"]
        self.assertNotIn("__init__", vars(type(commands)))
        # The host object keeps its own constructor and lookup helpers.
        self.assertEqual(asyncio.run(commands.invoke("/catalog")), {"echo": {"name": "/catalog", "arguments": ""}})
        self.assertTrue(inspect.iscoroutinefunction(commands.catalog))
        self.assertTrue(inspect.iscoroutinefunction(commands.invoke))

    def test_help_text_is_the_command_help(self):
        commands = self.boot()["commands"]
        self.assertEqual(inspect.signature(commands.model), inspect.signature(lambda model=None, provider=None: None))
        doc = commands.model.__doc__
        self.assertIn("Usage: /model [model] [provider]", doc)
        self.assertIn("model id (optional)", doc)

    def test_unknown_keyword_and_missing_positional_bounds(self):
        commands = self.boot()["commands"]
        with self.assertRaises(TypeError):
            asyncio.run(commands.model(bogus="x"))
        with self.assertRaises(TypeError):
            asyncio.run(commands.model("a", "b", "c"))
        # None values are omitted rather than sent as strings.
        asyncio.run(commands.model(model=None, provider="acme"))
        # and invoke takes raw text or a dict
        asyncio.run(commands.invoke("/model", "raw text"))
        asyncio.run(commands.invoke("model", {"model": "x"}))
        with self.assertRaises(LookupError):
            asyncio.run(commands.invoke("/nope"))


if __name__ == "__main__":
    unittest.main()
