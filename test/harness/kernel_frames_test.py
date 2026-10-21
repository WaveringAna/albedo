"""Catch frame names that drift across Python, Erlang, Gleam and kernel docs.

E2E exercises selected frames, not the complete vocabulary. A misspelled frame
in an unvisited handler otherwise survives until that operation runs.
"""

import ast
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
PYTHON = ROOT / "priv/python"
NATIVE = ROOT / "src/albedo/harness/extensions/python"

# These operations belong to remote.py, not the daemon's port owner.
REMOTE_REQUESTS = {"invoke", "introspect", "release"}
REMOTE_REPLIES = {"invoked", "introspected", "mirror"}
# Count observations are sent and handled but have no protocol TypedDict yet.
UNTYPED_OBSERVATIONS = {"cells", "jobs"}


def strings(node: ast.AST) -> set[str]:
    return {
        child.value
        for child in ast.walk(node)
        if isinstance(child, ast.Constant) and isinstance(child.value, str)
    }


def type_fields(tree: ast.AST) -> list[ast.expr]:
    fields = []
    for node in ast.walk(tree):
        if not isinstance(node, ast.Dict):
            continue
        fields.extend(
            value
            for key, value in zip(node.keys, node.values)
            if isinstance(key, ast.Constant) and key.value == "type"
        )
    return fields


def typed_frames() -> tuple[set[str], set[str]]:
    tree = ast.parse((PYTHON / "albedo_protocol.py").read_text())
    frames: dict[str, set[str]] = {}
    aliases: dict[str, ast.AST] = {}
    for node in tree.body:
        if isinstance(node, ast.ClassDef):
            for field in node.body:
                if (
                    isinstance(field, ast.AnnAssign)
                    and isinstance(field.target, ast.Name)
                    and field.target.id == "type"
                ):
                    frames[node.name] = strings(field.annotation)
        elif isinstance(node, ast.Assign) and isinstance(node.targets[0], ast.Name):
            name = node.targets[0].id
            aliases[name] = node.value
            # Invoke uses functional TypedDict syntax because `await` is a field.
            if isinstance(node.value, ast.Call):
                frames[name] = set().union(
                    *(strings(value) for value in type_fields(node.value))
                )

    def members(name: str) -> set[str]:
        return set().union(
            *(
                frames[child.id]
                for child in ast.walk(aliases[name])
                if isinstance(child, ast.Name)
            )
        )

    return members("Incoming"), members("RemoteMessage")


def daemon_frames() -> tuple[set[str], set[str]]:
    erlang = (NATIVE / "albedo_python.erl").read_text()
    erlang = re.sub(r"%[^\n]*", "", erlang)
    consumed = set(re.findall(r'<<"type">>\s*:=\s*<<"([a-z_]+)">>', erlang))
    consumed |= set(re.findall(r'Kind =:= <<"([a-z_]+)">>', erlang))
    produced = set(re.findall(r'type => <<"([a-z_]+)">>', erlang))
    produced |= set(re.findall(r'ask\(Pid, <<"([a-z_]+)">>', erlang))
    produced |= set(re.findall(r'\\"type\\":\\"([a-z_]+)\\"', erlang))
    gleam = (NATIVE / "kernel.gleam").read_text()
    produced |= set(re.findall(r'#\("type", json.string\("([a-z_]+)"\)\)', gleam))
    produced |= set(re.findall(r'state\(kernel, "([a-z_]+)"', gleam))
    return produced, consumed


def python_frame_literals() -> set[str]:
    kinds: set[str] = set()
    for path in (
        "albedo_cells.py",
        "albedo_plugins/run.py",
        "albedo_plugins/remote.py",
    ):
        tree = ast.parse((PYTHON / path).read_text())
        kinds |= {
            value.value
            for value in type_fields(tree)
            if isinstance(value, ast.Constant) and isinstance(value.value, str)
        }
    return kinds


class KernelFramesTest(unittest.TestCase):
    def test_daemon_requests_have_python_types(self):
        incoming, _ = typed_frames()
        produced, _ = daemon_frames()
        self.assertEqual(incoming - REMOTE_REQUESTS, produced)
        remote = (PYTHON / "albedo_plugins/remote.py").read_text()
        for kind in REMOTE_REQUESTS:
            self.assertRegex(remote, rf'"type": "{kind}"')

    def test_python_request_handlers_match_types(self):
        incoming, _ = typed_frames()
        tree = ast.parse((PYTHON / "albedo_cells.py").read_text())
        handled: set[str] = set()
        for node in ast.walk(tree):
            if (
                isinstance(node, ast.Compare)
                and isinstance(node.left, ast.Subscript)
                and isinstance(node.left.value, ast.Name)
                and node.left.value.id == "message"
                and isinstance(node.left.slice, ast.Constant)
                and node.left.slice.value == "type"
            ):
                for value in node.comparators:
                    handled |= strings(value)
        # state_reply treats the non-snapshot branch as restore.
        self.assertEqual(handled, incoming - {"restore"})
        protocol = ast.parse((PYTHON / "albedo_protocol.py").read_text())
        parser = next(
            node
            for node in protocol.body
            if isinstance(node, ast.FunctionDef) and node.name == "parse_incoming"
        )
        whitelist = next(
            node.comparators[0]
            for node in ast.walk(parser)
            if isinstance(node, ast.Compare)
            and isinstance(node.left, ast.Name)
            and node.left.id == "kind"
            and isinstance(node.ops[0], ast.NotIn)
        )
        self.assertEqual(strings(whitelist), incoming)

    def test_daemon_consumers_have_python_types(self):
        _, outgoing = typed_frames()
        _, consumed = daemon_frames()
        self.assertEqual(consumed - outgoing, UNTYPED_OBSERVATIONS)
        self.assertEqual(outgoing - consumed, REMOTE_REPLIES)
        remote = (PYTHON / "albedo_plugins/remote.py").read_text()
        for kind in REMOTE_REPLIES:
            self.assertRegex(remote, rf'frame\["type"\] == "{kind}"')

    def test_frame_literals_have_types_and_counterparts(self):
        incoming, outgoing = typed_frames()
        produced, consumed = daemon_frames()
        literals = python_frame_literals()
        self.assertEqual(literals - incoming - outgoing, UNTYPED_OBSERVATIONS)
        self.assertEqual(
            literals | produced,
            incoming | outgoing | UNTYPED_OBSERVATIONS,
        )
        # Job view replies copy the request's type instead of using a literal.
        self.assertEqual(
            (literals - incoming - REMOTE_REPLIES) | (literals & outgoing & incoming),
            consumed - {"job_list", "job_read"},
        )

    def test_kernel_docs_list_every_frame(self):
        incoming, outgoing = typed_frames()
        docs = (ROOT / "robot-docs/kernel.md").read_text()
        inventory = docs.split("## frame vocabulary\n", 1)[1].split("\n## ", 1)[0]
        documented = set(re.findall(r"`([a-z_]+)`", inventory))
        self.assertEqual(documented, incoming | outgoing | UNTYPED_OBSERVATIONS)


if __name__ == "__main__":
    unittest.main()
