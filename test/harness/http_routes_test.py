"""Catch routes missing from OpenAPI and operations without a dispatch arm.

E2E checks response schemas only for requests it sends; it cannot inventory
unvisited routes or notice an obsolete operation that no client calls.
"""

from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
METHOD = r"Get|Post|Put|Patch|Delete|Head|Options|Trace|Connect"


def function(source: str, name: str) -> str:
    match = re.search(
        rf"^(?:pub )?fn {name}\(.*?(?=^(?:pub )?fn |\Z)", source, re.M | re.S
    )
    if match is None:
        raise AssertionError(f"missing route function {name}")
    return match[0]


def dispatch_routes(source: str, prefix: str) -> set[str]:
    source = re.sub(r"//[^\n]*", "", source)
    # Only arms of the outer dispatch, not admission or parameter validation.
    arms = re.findall(rf"^    ((?:{METHOD}),.*?)\s*->", source, re.M)
    routes = set()
    for arm in arms:
        for alternative in arm.split("|"):
            match = re.fullmatch(rf"({METHOD}),\s*\[([^\]]*)\]", alternative.strip())
            if match is None:
                raise AssertionError(f"unsupported route arm: {arm}")
            method, body = match.groups()
            segments = []
            for segment in body.split(",") if body.strip() else []:
                segment = segment.strip()
                if re.fullmatch(r'"[^"/]*"', segment):
                    segments.append(segment[1:-1])
                elif re.fullmatch(r"[a-z_][a-z_0-9]*", segment):
                    segments.append("{}")
                else:
                    raise AssertionError(f"unsupported route segment: {segment}")
            routes.add(f"{method.upper()} {prefix}/{'/'.join(segments)}")
    if not routes:
        raise AssertionError(f"no dispatch routes found for {prefix or 'daemon'}")
    return routes


def daemon_routes() -> set[str]:
    daemon = ROOT / "src/albedo/daemon/server.gleam"
    routes = dispatch_routes(function(daemon.read_text(), "daemon_route"), "")
    extensions = ROOT / "src/albedo/harness/extensions"
    for extension in extensions.glob("*/extension.gleam"):
        source = extension.read_text()
        if "ServicePlugin(" not in source:
            continue
        name = re.search(r'Extension\(\s*"([^"\n]+)"', source)
        if name is None:
            raise AssertionError(f"cannot read extension name: {extension}")
        service = extension.with_name("service.gleam")
        dispatch = (
            function(service.read_text(), "dispatch")
            if service.exists()
            else function(source, "dispatch")
        )
        routes |= dispatch_routes(dispatch, f"/extensions/{name[1]}")
    return routes


def openapi_operations() -> set[str]:
    source = (ROOT / "docs/openapi.yaml").read_text()
    paths = source.split("\npaths:\n", 1)[1].split("\ncomponents:", 1)[0]
    operations = set()
    path = ""
    for line in paths.splitlines():
        if re.fullmatch(r"  /[^:]+:", line):
            path = re.sub(r"\{[^}]+\}", "{}", line.strip()[:-1])
        elif re.fullmatch(rf"    ({METHOD.lower()}):", line):
            operations.add(f"{line.strip()[:-1].upper()} {path}")
    # Fail rather than silently accept YAML layout this scanner cannot read.
    if len(operations) != len(re.findall(r"^      operationId:", paths, re.M)):
        raise AssertionError("OpenAPI scanner did not read every operationId")
    return operations


class HttpRoutesTest(unittest.TestCase):
    def test_routes_and_openapi_operations_agree(self):
        routes, operations = daemon_routes(), openapi_operations()
        self.assertEqual(
            routes,
            operations,
            f"undocumented routes: {sorted(routes - operations)}\n"
            f"operations without routes: {sorted(operations - routes)}",
        )


if __name__ == "__main__":
    unittest.main()
