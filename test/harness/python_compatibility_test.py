"""Keep the shipped kernel parseable on the version in pyrightconfig.json.

E2E uses the local interpreter, so Python 3.14 can hide syntax that breaks
remote boot on older hosts. Check every module, including disabled plugins.
"""

import ast
import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class PythonCompatibilityTest(unittest.TestCase):
    def test_bundle_parses_on_supported_python(self):
        config = json.loads((ROOT / "pyrightconfig.json").read_text())
        major, minor = config["pythonVersion"].split(".")
        version = (int(major), int(minor))
        for path in sorted((ROOT / "priv" / "python").rglob("*.py")):
            with self.subTest(path=str(path.relative_to(ROOT))):
                ast.parse(path.read_text(), filename=str(path), feature_version=version)


if __name__ == "__main__":
    unittest.main()
