"""Bounded Erlang inspection transport shared by isolated daemon scenarios."""

import json
import re
import subprocess
import uuid


class Inspection:
    def __init__(self, app, source=None):
        self.app = app
        self.module = source.stem if source is not None else None
        if source is not None:
            result = subprocess.run(
                ["erlc", "-Werror", "-o", str(app.root), str(source)],
                capture_output=True,
                text=True,
                timeout=30,
            )
            if result.returncode != 0:
                raise AssertionError(
                    f"probe compilation failed: {source}\n{result.stdout}{result.stderr}"
                )

    def evaluate(self, expression, *, timeout=40):
        app = self.app
        log = (app.home / "daemon.log").read_text(errors="replace")
        nodes = re.findall(rf"inspect: node (albedo_{app.daemon._pid}@[^\s]+)", log)
        if not nodes:
            raise AssertionError(
                "daemon did not announce an inspection node; enable ALBEDO_INSPECT before boot"
            )
        cookie = (app.home / "inspect.cookie").read_text().strip()
        node = nodes[-1]
        prefix = (
            f"Node = '{node}', "
            "Call = fun(Module, Function, Arguments) -> "
            f"case rpc:call(Node, Module, Function, Arguments, {int(timeout * 1000)}) of "
            "{badrpc, Reason} -> error({rpc_failed, Module, Function, Reason}); "
            "Value -> Value end end, "
        )
        if self.module is not None:
            beam = app.root / (self.module + ".beam")
            prefix += (
                f"{{ok, Binary}} = file:read_file({json.dumps(str(beam))}), "
                f"{{module, {self.module}}} = Call(code, load_binary, "
                f'[{self.module}, "probe.erl", Binary]), '
            )
        try:
            result = subprocess.run(
                [
                    "erl",
                    "+S",
                    "2:2",
                    "-sname",
                    f"probe_{uuid.uuid4().hex}",
                    "-setcookie",
                    cookie,
                    "-noshell",
                    "-eval",
                    prefix + expression + ", halt().",
                ],
                cwd=app.root,
                capture_output=True,
                text=True,
                timeout=timeout,
            )
        except subprocess.TimeoutExpired as error:
            raise AssertionError(
                f"inspection of {node} timed out after {timeout}s"
            ) from error
        if result.returncode != 0:
            raise AssertionError(
                f"inspection of {node} failed:\n{result.stdout}{result.stderr}"
            )
        return result.stdout

    def call(self, function, arguments="[]"):
        if self.module is None:
            raise ValueError("calling a probe requires its source module")
        return self.evaluate(
            f"io:put_chars(Call({self.module}, {function}, {arguments}))"
        )

    def call_json(self, function, arguments="[]"):
        output = self.call(function, arguments)
        try:
            return json.loads(output)
        except ValueError as error:
            raise AssertionError(
                f"{self.module}:{function} returned invalid JSON: {output}"
            ) from error
