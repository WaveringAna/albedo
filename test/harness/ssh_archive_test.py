"""The bundle staged on a remote host holds the python sources and nothing a
tool left in the tree: a cache directory would travel to every host, and
shipping it changed what the host runs from."""

import io
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "priv" / "python"))
import albedo_bundle  # noqa: E402
import albedo_ssh  # noqa: E402


class ArchiveTest(unittest.TestCase):
    def test_sources_travel_and_caches_do_not(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            for name in (
                "a.py",
                "plugins/b.py",
                "plugins/__pycache__/b.cpython-314.pyc",
                ".ruff_cache/0.16.10/entry",
                "plugins/.mypy_cache/meta.json",
            ):
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("x")
            with mock.patch.object(albedo_bundle, "ROOT", root):
                data = albedo_ssh.archive()
        names = {
            name.removeprefix("./")
            for name in tarfile.open(fileobj=io.BytesIO(data)).getnames()
        }
        self.assertEqual(
            {name for name in names if not name.endswith(("plugins", "."))},
            {"a.py", "plugins/b.py"},
        )


if __name__ == "__main__":
    unittest.main()
