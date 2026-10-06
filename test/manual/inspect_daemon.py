"""Run albedo_inspect against the live daemon.

Start the daemon with ALBEDO_INSPECT=1 first. Then:
  python3 test/manual/inspect_daemon.py cpu [seconds]    where the VM's work goes (default 30)
  python3 test/manual/inspect_daemon.py report           memory by process, binary and session
  python3 test/manual/inspect_daemon.py stacks          where every albedo process is waiting now
  python3 test/manual/inspect_daemon.py peak [ms]        memory high-water mark (default 5000)
  python3 test/manual/inspect_daemon.py eval EXPRESSION  any expression run on the daemon; it is
                                                  printed with ~p unless it is iodata

$ALBEDO_HOME (default ~/.albedo) says which daemon.
"""

import json
import os
from pathlib import Path
import re
import subprocess
import sys
import uuid

HOME = Path(os.environ.get("ALBEDO_HOME", Path.home() / ".albedo"))


def node() -> str:
    pid = json.loads((HOME / "daemon.json").read_text())["pid"]
    log = (HOME / "daemon.log").read_text(errors="replace")
    found = re.findall(rf"inspect: node (albedo_{pid}@\S+)", log)
    if not found:
        sys.exit(f"daemon {pid} is not inspectable; restart it with ALBEDO_INSPECT=1")
    return found[-1]


def expression(argv: list[str]) -> tuple[str, int]:
    """The call to make on the daemon, and how long to wait for it in seconds."""
    match argv:
        case ["cpu", *rest]:
            seconds = int(rest[0]) if rest else 30
            return f"albedo_inspect:cpu({seconds})", seconds + 30
        case ["report"]:
            return "albedo_inspect:report()", 60
        case ["stacks"]:
            return "albedo_inspect:stacks()", 60
        case ["peak", *rest]:
            ms = int(rest[0]) if rest else 5000
            return f"albedo_inspect:peak({ms})", ms // 1000 + 30
        case ["eval", text]:
            return text, 120
    sys.exit(__doc__)


def main() -> None:
    call, timeout = expression(sys.argv[1:])
    target = node()
    cookie = (HOME / "inspect.cookie").read_text().strip()
    program = (
        f"Value = case rpc:call('{target}', erlang, apply, [fun() -> {call} end, []], "
        f'{timeout * 1000}) of {{badrpc, Reason}} -> io_lib:format("badrpc ~p~n", [Reason]); '
        "V -> V end, "
        'io:put_chars(try iolist_to_binary(Value) catch _:_ -> io_lib:format("~p~n", [Value]) end), '
        "halt()."
    )
    result = subprocess.run(
        [
            "erl",
            "+S",
            "1:1",
            "-sname",
            f"probe_{uuid.uuid4().hex[:12]}",
            "-setcookie",
            cookie,
            "-noshell",
            "-eval",
            program,
        ],
        capture_output=True,
        text=True,
        timeout=timeout + 15,
    )
    sys.stdout.write(result.stdout)
    sys.stderr.write(result.stderr)
    sys.exit(result.returncode)


if __name__ == "__main__":
    main()
