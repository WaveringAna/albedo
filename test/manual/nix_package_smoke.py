"""Check a packaged binary outside its checkout, without development tools on PATH.

Usage: python3 test/manual/nix_package_smoke.py /absolute/path/to/bin/albedo
"""

import json
import pathlib
import subprocess
import sys
import tempfile
import urllib.request

binary = sys.argv[1]
with tempfile.TemporaryDirectory(prefix="albedo-nix-smoke-") as directory:
    base = pathlib.Path(directory)
    home = base / "home"
    home.mkdir()
    (home / "extensions.json").write_text(json.dumps({"models": {"refreshHours": 0}}))
    env = {
        "HOME": str(base),
        "ALBEDO_HOME": str(home),
        "ALBEDO_NO_BROWSER": "1",
        "PATH": "/usr/bin:/bin",
        "TERM": "dumb",
    }
    try:
        result = subprocess.run(
            [binary, "sessions", "--json"],
            cwd=base,
            env=env,
            capture_output=True,
            text=True,
            timeout=45,
        )
        if result.returncode:
            print(result.stdout, result.stderr)
            log = home / "daemon.log"
            if log.exists():
                print(log.read_text()[-10000:])
            raise SystemExit(result.returncode)
        assert json.loads(result.stdout) == [], result.stdout
        record = json.loads((home / "daemon.json").read_text())
        req = urllib.request.Request(
            f"http://127.0.0.1:{record['port']}/health",
            headers={"Authorization": "Bearer " + record["token"]},
        )
        with urllib.request.urlopen(req, timeout=5) as response:
            health = json.load(response)
        assert health["version"] == 2, health
        print(json.dumps({"binary": binary, "sessions": [], "health": health}))
    finally:
        stop = subprocess.run(
            [binary, "daemon", "--stop"],
            cwd=base,
            env=env,
            capture_output=True,
            text=True,
            timeout=10,
        )
        assert stop.returncode == 0, "shutdown error: " + stop.stderr
