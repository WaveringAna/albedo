"""Load unittest files without letting an empty selection report success."""

import importlib.util
from pathlib import Path
import sys
import unittest


def suite_for(path, test_name=None):
    path = Path(path).resolve()
    sys.path.insert(0, str(path.parent))
    spec = importlib.util.spec_from_file_location(path.stem, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[path.stem] = module
    spec.loader.exec_module(module)
    loader = unittest.TestLoader()
    suite = (
        loader.loadTestsFromName(test_name, module)
        if test_name
        else loader.loadTestsFromModule(module)
    )
    if suite.countTestCases() == 0:
        raise ValueError(f"no tests collected from {path}")
    return suite


def main():
    try:
        suite = suite_for(sys.argv[1])
    except ValueError as error:
        print(error, file=sys.stderr)
        return 1
    return 0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(main())
