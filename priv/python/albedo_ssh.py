"""One ssh layer for albedo: the daemon's remote kernels and the model's remote plugin.

Both ride the same multiplexed control connection per host: the ControlPath
the user's ssh config names, so their own ssh, colmena and git share it too,
or `/tmp/albedo-ssh-cm/%C` when it names none. BatchMode stays on: a host
that needs a passphrase, a second factor or a new host key answers
`needs_auth`, and the tui opens the master in the terminal instead.

    albedo_ssh.py probe <[user@]host>
    albedo_ssh.py commands <[user@]host> <home>
    albedo_ssh.py hosts

`probe` prints `{"step": "staging"}` on a line of its own before it copies
the bundle over, so a waiting client can say so, then one JSON object:
`{state, detail, os, arch, home, cpus, python}` and, once the home is known,
the `commands` answer: `{argv, control, bundle, bridge, signal, remove,
gather, auth_sock}`, the complete remote commands the daemon runs there.
state is ready, needs_auth, unreachable or unsupported. A ready probe has checked python >= 3.11 and staged the content-hashed bundle
under `~/.albedo-remote/<digest>`. `commands` needs no network, for a host
known only from a kernel's record while ssh is down. `hosts` lists the `Host`
names of ~/.ssh/config and its includes, patterns left out.
"""

from __future__ import annotations

import glob
import io
import json
import os
import shlex
import subprocess
import sys
import tempfile
from collections.abc import Callable

import albedo_bundle

CONNECT_TIMEOUT = 10  # seconds ssh may take to reach a host
PROBE_TIMEOUT = 30  # seconds for the whole probe command
STAGE_TIMEOUT = 120  # seconds to move the bundle over one ssh stream
MINIMUM_PYTHON = (3, 11)
STAGED_DIR = ".albedo-remote"


def control_dir() -> str:
    """Control sockets live under /tmp when it fits, else the temp dir: unix
    socket paths are capped (~104 bytes on macOS) and %C hashes to 40 more,
    so neither ALBEDO_HOME nor macOS's deep $TMPDIR may be on the path."""
    control = os.path.join("/tmp", "albedo-ssh-cm")
    if len(control) + 42 > 104:
        control = os.path.join(tempfile.gettempdir(), "albedo-ssh-cm")
    return control


def multiplexing(target: str) -> tuple[str, str]:
    """The control path and ControlPersist for `target`: the user's own when
    their ssh config names a ControlPath, so a master they or their tools
    opened carries albedo too and albedo's carries theirs; else albedo's.
    `ssh -G` only reads the config."""
    try:
        done = subprocess.run(
            ["ssh", "-G", target],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=5,
        )
        lines = done.stdout.splitlines() if done.returncode == 0 else []
    except (OSError, subprocess.SubprocessError):
        lines = []
    settings = {}
    for line in lines:
        key, _, value = line.partition(" ")
        settings[key] = value
    path = settings.get("controlpath", "none")
    if path == "none":
        return f"{control_dir()}/%C", "600"
    persist = settings.get("controlpersist", "no")
    # -G expanded the path's tokens; a % left in it is literal
    return path.replace("%", "%%"), "600" if persist in ("no", "0") else persist


def base(target: str) -> list[str]:
    """The ssh argv prefix for `target`, up to the target itself."""
    return options(*multiplexing(target))


def sign_in(target: str) -> list[str]:
    """What a person runs in a terminal to sign in to `target` where ssh can
    ask them: it opens the master albedo rides, which outlives it."""
    control, persist = multiplexing(target)
    return [
        "ssh",
        "-M",
        "-fN",
        "-o",
        f"ControlPath={control}",
        "-o",
        f"ControlPersist={persist}",
        target,
    ]


def options(control: str, persist: str) -> list[str]:
    """The ssh argv prefix riding the master at `control`."""
    os.makedirs(control_dir(), exist_ok=True)
    return [
        "ssh",
        "-o",
        "BatchMode=yes",
        "-o",
        f"ConnectTimeout={CONNECT_TIMEOUT}",
        "-o",
        "StrictHostKeyChecking=accept-new",
        "-o",
        "ControlMaster=auto",
        "-o",
        f"ControlPath={control}",
        "-o",
        f"ControlPersist={persist}",
    ]


def agent_socket() -> str | None:
    """SSH_AUTH_SOCK, or a standard agent socket when it was not inherited, so
    hardware keys, 1Password, and ssh-agent work out of the box."""
    if "SSH_AUTH_SOCK" in os.environ:
        return os.environ["SSH_AUTH_SOCK"]
    for candidate in (
        os.path.expanduser("~/.ssh/agent.sock"),
        os.path.expanduser(
            "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
        ),
    ):
        if os.path.exists(candidate):
            return candidate
    return None


def env() -> dict[str, str]:
    """The local environment for ssh client processes."""
    environment = dict(os.environ)
    socket = agent_socket()
    if socket is not None:
        environment["SSH_AUTH_SOCK"] = socket
    return environment


def in_login_shell(script: str) -> str:
    """The remote command that runs `script` under the user's login shell.

    Non-interactive SSH commands run under `$SHELL -c` without sourcing
    `/etc/profile` or user profiles, which leaves PATH minimal (missing
    Nix, Homebrew, or user tool paths); a login shell finds python3 and the
    user's tools. Profiles often print (a motd, a greeting), which would
    corrupt a framed stdout and fill the daemon's log on every command, so
    the login shell starts with both on /dev/null and the real ones kept on
    fds 3 and 4, and `script` gets them back. The outer `/bin/sh` makes the
    redirections work whatever the user's shell is.
    """
    login = f"exec 1>&3 2>&4 3>&- 4>&-; {script}"
    outer = (
        "exec 3>&1 4>&2 1>/dev/null 2>&1; "
        f'exec "${{SHELL:-/bin/sh}}" -l -c {shlex.quote(login)}'
    )
    return f"/bin/sh -c {shlex.quote(outer)}"


def commands(target: str, home: str) -> dict[str, object]:
    """Everything the daemon runs on a host whose home is known, as complete
    remote commands: it never quotes anything itself. Variable inputs travel
    on stdin (the bridge's first frame, the ladder's request line, the run
    directory to remove), never in the command line."""
    bundle = f"{home}/{staged_name()}"
    python = "exec python3 -u "
    control, persist = multiplexing(target)
    answer: dict[str, object] = {
        "host": target,
        "argv": [*options(control, persist), target],
        "control": control,
        "bundle": bundle,
        "bridge": in_login_shell(
            python + shlex.quote(f"{bundle}/albedo_bridge.py") + " --frame"
        ),
        "signal": in_login_shell(
            python + shlex.quote(f"{bundle}/albedo_signal.py") + " -"
        ),
        "remove": in_login_shell('read -r run && rm -rf -- "$run"'),
        "gather": in_login_shell(python + shlex.quote(f"{bundle}/albedo_gather.py")),
    }
    socket = agent_socket()
    if socket is not None:
        answer["auth_sock"] = socket
    return answer


def staged_name(digest: str | None = None) -> str:
    """The bundle's directory under the remote home."""
    return f"{STAGED_DIR}/{(digest or albedo_bundle.digest())[:16]}"


def archive() -> bytes:
    import tarfile  # staging a host is rare; not worth every kernel's boot

    data = io.BytesIO()
    with tarfile.open(fileobj=data, mode="w") as tar:
        tar.add(
            str(albedo_bundle.ROOT),
            arcname=".",
            filter=lambda info: None if "__pycache__" in info.name else info,
        )
    return data.getvalue()


def stage_script(remote: str) -> str:
    """Unpack beside the target, then move into place, so a bundle directory
    that exists is always complete."""
    return (
        f'mkdir -p "{remote}.part.$$" && tar -C "{remote}.part.$$" -xf - && '
        f'{{ mv "{remote}.part.$$" "{remote}" 2>/dev/null || rm -rf "{remote}.part.$$"; }}'
    )


def run(
    target: str, script: str, timeout: float, data: bytes | None = None
) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(
        [*base(target), target, script],
        input=data,
        stdin=None if data is not None else subprocess.DEVNULL,
        capture_output=True,
        timeout=timeout,
        env=env(),
    )


def failure(stderr: str) -> tuple[str, str]:
    """What ssh's own exit (255) means: a host we could reach with a person's
    help, or one we could not reach at all."""
    text = stderr.strip()
    lines = [line for line in text.splitlines() if line.strip()]
    detail = lines[-1] if lines else "ssh failed"
    lowered = text.lower()
    interactive = (
        "permission denied",
        "host key verification failed",
        "passphrase",
        "keyboard-interactive",
        "verification code",
        "too many authentication failures",
    )
    if any(phrase in lowered for phrase in interactive):
        return "needs_auth", detail
    return "unreachable", detail


PROBE = (
    "uname -s; uname -m; printf '%s\\n' \"$HOME\"; "
    "getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 1; "
    "python3 -c 'import sys; print(\"%d.%d\" % sys.version_info[:2])' 2>/dev/null "
    "|| echo none; "
    'test -f "$HOME/{bundle}/albedo_bridge.py" && echo staged || echo missing'
)


def probe(
    target: str, step: Callable[[str], None] = lambda _: None
) -> dict[str, object]:
    control, persist = multiplexing(target)
    answer: dict[str, object] = {
        "host": target,
        "argv": [*options(control, persist), target],
        "control": control,
    }
    bundle = staged_name()
    try:
        done = run(target, in_login_shell(PROBE.format(bundle=bundle)), PROBE_TIMEOUT)
    except subprocess.TimeoutExpired:
        return {**answer, "state": "unreachable", "detail": "ssh timed out"}
    except OSError as error:
        return {**answer, "state": "unreachable", "detail": f"ssh: {error}"}
    fields = done.stdout.decode(errors="replace").splitlines()
    if done.returncode == 255 or len(fields) != 6:
        state, detail = failure(done.stderr.decode(errors="replace"))
        return {**answer, "state": state, "detail": detail}
    system, arch, home, cpus, python, staged = (field.strip() for field in fields)
    answer.update(
        commands(target, home),
        os=system,
        arch=arch,
        home=home,
        cpus=int(cpus) if cpus.isdigit() and int(cpus) > 0 else 1,
        python=python,
    )
    version = (
        tuple(int(part) for part in python.split(".")) if python[:1].isdigit() else None
    )
    if version is None:
        return {
            **answer,
            "state": "unsupported",
            "detail": "needs python >= 3.11 (python3 not found)",
        }
    if version < MINIMUM_PYTHON:
        return {
            **answer,
            "state": "unsupported",
            "detail": f"needs python >= 3.11 (found {python})",
        }
    if staged != "staged":
        step("staging")
        try:
            staging = run(
                target,
                in_login_shell(stage_script(f"$HOME/{bundle}")),
                STAGE_TIMEOUT,
                archive(),
            )
        except subprocess.TimeoutExpired:
            return {**answer, "state": "unreachable", "detail": "staging timed out"}
        if staging.returncode != 0:
            detail = staging.stderr.decode(errors="replace").strip()[-500:]
            return {
                **answer,
                "state": "unreachable",
                "detail": f"staging failed: {detail}",
            }
    return {**answer, "state": "ready", "detail": ""}


def config_hosts(path: str | None = None, seen: set[str] | None = None) -> list[str]:
    """`Host` names in ~/.ssh/config and the files it includes, in order,
    without patterns (`*`, `?`, `!`): the hosts a person can name."""
    path = path or os.path.expanduser("~/.ssh/config")
    seen = set() if seen is None else seen
    if path in seen:
        return []
    seen.add(path)
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            lines = handle.read().splitlines()
    except OSError:
        return []
    names: list[str] = []
    for line in lines:
        words = shlex.split(line, comments=True) if line.strip() else []
        if len(words) < 2:
            continue
        keyword = words[0].lower()
        if keyword == "host":
            names += [w for w in words[1:] if not any(c in w for c in "*?!")]
        elif keyword == "include":
            for pattern in words[1:]:
                pattern = os.path.expanduser(pattern)
                if not os.path.isabs(pattern):
                    pattern = os.path.join(os.path.expanduser("~/.ssh"), pattern)
                for included in sorted(glob.glob(pattern)):
                    names += config_hosts(included, seen)
    return list(dict.fromkeys(names))


def announce(step: str) -> None:
    print(json.dumps({"step": step}), flush=True)


def main(argv: list[str]) -> int:
    if len(argv) == 3 and argv[1] == "probe":
        print(json.dumps(probe(argv[2], announce)))
        return 0
    if len(argv) == 2 and argv[1] == "hosts":
        print(json.dumps(config_hosts()))
        return 0
    if len(argv) == 4 and argv[1] == "commands":
        print(json.dumps(commands(argv[2], argv[3])))
        return 0
    print(
        "usage: albedo_ssh.py probe <[user@]host> | commands <[user@]host> <home>",
        file=sys.stderr,
    )
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
