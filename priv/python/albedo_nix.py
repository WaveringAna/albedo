"""albedo's nix: the program behind the `nix` shim (albedo_shims.py) that
the model's jobs find first on PATH.

`nix` in a jj workspace that has no .git hands nix a plain path, and nix
copies that whole directory into the store, build and target dirs included,
on every evaluation. The shim names the workspace's commit in the
repository's git store instead (git+file://...?rev=...), so nix reads tracked
files only, and points the lock file nix may write back at the workspace
(--output-lock-file), where nix would have put it in a git checkout.

`nix develop [installable] -c program ...` runs the program in a dev shell
captured once, as `nix develop` would build it (the dev shell script and its
shellHook), and kept as the difference it makes to the environment. It is
cached under $ALBEDO_HOME/cache/nix-develop by the content of the files dev
shells are made of (SHELL_FILES), behind a profile nix's garbage collector
keeps, so an unchanged flake costs no nix call in any checkout of the
repository.

Commands are read with nix's own flag table (`nix __dump-cli`, cached per nix
binary); everything the shim has no reason to change goes to nix unchanged.
ALBEDO_PLAIN_NIX=1 runs nix as is.
"""

from __future__ import annotations

import fcntl
import fnmatch
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, NoReturn
from urllib.parse import quote

FEATURES = ["--extra-experimental-features", "nix-command flakes"]
# What a dev shell is made of; an edit anywhere else keeps the cached shell.
SHELL_FILES = ("*.nix", "flake.lock", "rust-toolchain", "rust-toolchain.toml")
# Never walked for SHELL_FILES in a directory outside version control.
UNWALKED = {"node_modules", "target", "build", "_build", "dist", "result"}
CACHE_LIMIT = 32  # cached shells; the least recently used goes first
REMOTE_TTL = 86400  # seconds a shell from a flake elsewhere (github:...) is kept
STEP_TIMEOUT = 600  # seconds for one jj or git call, or a shellHook
# Set by sourcing the shell script, meaningless outside the bash that did it.
VOLATILE = {"NIX_BUILD_TOP", "TMP", "TMPDIR", "TEMP", "TEMPDIR"}
VOLATILE |= {"PWD", "OLDPWD", "SHLVL", "_"}
# the nix compiler wrapper's inputs, which no build cache key covers (albedo_shims)
WRAPPER = ("NIX_CFLAGS", "NIX_LDFLAGS", "NIX_CC", "NIX_HARDENING_ENABLE")
# develop flags a cached shell honours: they change what nix prints, not the shell
QUIET = {"verbose", "quiet", "print-build-logs", "log-format", "show-trace"}
QUIET |= {"debug", "accept-flake-config", "no-write-lock-file", "no-update-lock-file"}
# flags that write into the repository the ref names, not into the workspace
WRITING = {"commit-lock-file"}
# nix's own spellings of commands the flag table lists under another name,
# by the command they are spelled under
ALIASES = {
    (): {"shell": ["env", "shell"], "dev-shell": ["develop"]},
    ("profile",): {"install": ["add"]},
}
# argument labels (nix __dump-cli) of one word naming a flake or its installable;
# "installables" is every word
FLAKE_ARGS = {"installable", "flake-url", "package", "dependency"}
VARIADIC = {"args", "strings", "paths", "elements", "hashes", "inputs"}
# flags that make installables something other than flakes
NOT_FLAKES = {"expr", "file"}
# commands that run the formatter of the flake at `.`, and the nix verb for that
FORMATTERS = {
    ("fmt",): "run",
    ("formatter", "run"): "run",
    ("formatter", "build"): "build",
}
NOTE = "albedo:"
REFUSED = (
    "nix would copy this jj workspace (it has no .git) into the store, build "
    "output included. Name the flake by its commit (git+file://<repo>?rev=<commit>) "
    "or set ALBEDO_PLAIN_NIX=1 to copy anyway."
)

# what a dev shell does to an environment: "set", "prepend", and "unset"
Change = dict[str, Any]


class NixError(RuntimeError):
    """jj, git, or nix could not prepare the shell; the message has their output."""


class Unreadable(Exception):
    """A flag or command nix's own table does not have: nix refuses it
    itself, or it is an alias the shim does not know."""


@dataclass(frozen=True)
class Flake:
    """A local flake and the checkout it lives in."""

    directory: Path  # holds flake.nix
    root: Path  # the jj workspace, the git work tree, or the directory itself
    vcs: str  # "jj", "git", or "" outside version control

    @property
    def copied(self) -> bool:
        """Whether nix, handed this directory, copies all of it: a jj
        workspace with no .git beside .jj is a plain path to nix."""
        return self.vcs == "jj" and not (self.root / ".git").exists()


def _above(start: Path, name: str) -> Path | None:
    for directory in (start, *start.parents):
        if (directory / name).exists():
            return directory
    return None


def locate(start: Path) -> Flake | None:
    """The flake at or above `start`. jj wins over git at the same root, as
    the picker reads a colocated repository."""
    directory = _above(start, "flake.nix")
    if directory is None:
        return None
    jj, git = _above(directory, ".jj"), _above(directory, ".git")
    if jj is not None and (git is None or git == jj or git in jj.parents):
        return Flake(directory, jj, "jj")
    if git is not None:
        return Flake(directory, git, "git")
    return Flake(directory, directory, "")


def system() -> str:
    """This host's nix system, as nix names it."""
    machine = {"arm64": "aarch64", "amd64": "x86_64"}.get(platform.machine().lower())
    kernel = "darwin" if sys.platform == "darwin" else "linux"
    return f"{machine or platform.machine()}-{kernel}"


def _local(base: str) -> bool:
    """Whether an installable's flake part names a local directory."""
    return base in ("", ".", "..") or base.startswith(("./", "../", "/", "path:"))


def _step(argv: list[str], cwd: Path | None, what: str) -> str:
    """One program the shim needs the output of, or a NixError with it."""
    try:
        done = subprocess.run(
            argv, cwd=cwd, capture_output=True, text=True, timeout=STEP_TIMEOUT
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise NixError(f"{what} failed: {error}") from error
    if done.returncode != 0:
        raise NixError(
            f"{what} failed (exit {done.returncode}):\n{done.stderr[-4000:]}"
        )
    return done.stdout


def _home() -> Path:
    return Path(os.environ.get("ALBEDO_HOME") or os.path.expanduser("~/.albedo"))


# ---- reading a command line ----


def flag_table(nix: str) -> dict[str, Any]:
    """nix's commands and the arity of each flag, from `nix __dump-cli`,
    kept per nix binary."""
    binary = os.path.realpath(nix)
    cache = _home() / "cache" / "nix-cli"
    entry = cache / (hashlib.sha256(binary.encode()).hexdigest()[:32] + ".json")
    try:
        return json.loads(entry.read_text())
    except (OSError, ValueError):
        pass
    dump = json.loads(_step([binary, "__dump-cli"], None, "nix __dump-cli"))["args"]

    def node(command: dict[str, Any]) -> dict[str, Any]:
        flags = command.get("flags", {})
        return {
            "flags": {name: flag.get("arity") or 0 for name, flag in flags.items()},
            "short": {
                flag["shortName"]: name
                for name, flag in flags.items()
                if flag.get("shortName")
            },
            "args": [arg.get("label", "") for arg in command.get("args", [])],
            "commands": {
                name: node(sub) for name, sub in command.get("commands", {}).items()
            },
        }

    table = node(dump)
    cache.mkdir(parents=True, exist_ok=True)
    temporary = cache / f".{entry.name}.{os.getpid()}"
    temporary.write_text(json.dumps(table))
    temporary.replace(entry)
    return table


@dataclass
class Command:
    """One nix command line, read with the flag table."""

    words: list[str]
    path: list[str]  # the subcommand, e.g. ["flake", "check"]
    named: list[int]  # indices of the words that spell the subcommand
    positional: list[int]  # indices of the words that are not flags or values
    flags: dict[str, list[int]]  # flag name -> index of each use
    args: list[str]  # the subcommand's argument labels
    program: list[str]  # what follows --command / -c (develop, shell)
    stop: int  # index of `--`, or of the end

    @property
    def passed(self) -> list[str]:
        """What follows `--`."""
        return self.words[self.stop + 1 :]

    @property
    def end(self) -> int:
        """Where flags for the subcommand can go: just past its words."""
        return self.named[-1] + 1 if self.named else 0


def read(words: list[str], table: dict[str, Any]) -> Command:
    """The command `words` (nix's arguments) spell, or Unreadable."""
    node, path, named = table, [], []
    positional: list[int] = []
    flags: dict[str, list[int]] = {}
    program: list[str] = []
    index = 0
    while index < len(words):
        word = words[index]
        if word == "--":
            break
        if word.startswith("--"):
            name = word[2:]
        elif word.startswith("-") and len(word) == 2:
            name = node["short"].get(word[1]) or table["short"].get(word[1], "")
        elif word.startswith("-") and word != "-":
            raise Unreadable(word)
        else:
            names = ALIASES.get(tuple(path), {}).get(word, [word])
            if not positional and names[0] in node["commands"]:
                for name in names:
                    node = node["commands"][name]
                path.extend(names)
                named.append(index)
            elif node["commands"]:
                raise Unreadable(word)  # a command nix spells some other way
            else:
                positional.append(index)
            index += 1
            continue
        if name == "command" and path in (["develop"], ["env", "shell"]):
            program = words[index + 1 :]
            flags.setdefault(name, []).append(index)
            index = len(words)
            break
        arity = node["flags"].get(name, table["flags"].get(name))
        if arity is None:
            raise Unreadable(word)
        flags.setdefault(name, []).append(index)
        index += 1 + arity
    return Command(words, path, named, positional, flags, node["args"], program, index)


def _flake_words(command: Command) -> list[int]:
    """Indices of the words that name a flake (or an installable of one),
    following the subcommand's argument labels."""
    if NOT_FLAKES & command.flags.keys():
        return []  # installables are attribute paths or store paths then
    found, left = [], list(command.positional)
    for label in command.args:
        if not left:
            break
        if label == "installables":
            found, left = found + left, []
        elif label in FLAKE_ARGS:
            found.append(left.pop(0))
        elif label in VARIADIC:
            left = []
        else:
            left.pop(0)
    return found


# ---- refs that never copy a jj workspace ----


def flake_ref(flake: Flake) -> str:
    """The ref nix reads `flake` through without copying the working copy."""
    if flake.vcs == "git":
        return str(flake.directory)
    if flake.vcs != "jj":
        return f"path:{flake.directory}"
    # jj log snapshots the working copy, so the commit holds every edit
    log = _step(
        ["jj", "log", "-r", "@", "--no-graph", "-T", '"commit=" ++ commit_id ++ "\\n"'],
        flake.root,
        "jj log",
    )
    commit = re.search(r"commit=([0-9a-f]{40})", log)
    if commit is None:
        raise NixError(f"jj log named no commit:\n{log[-2000:]}")
    lines = _step(["jj", "git", "root"], flake.root, "jj git root").splitlines()
    store = Path([line for line in lines if line.strip()][-1].strip())
    # a colocated .git is read through its work tree, a bare store as itself
    repository = store.parent if store.name == ".git" else store
    ref = f"git+file://{quote(str(repository))}?rev={commit.group(1)}"
    relative = flake.directory.relative_to(flake.root)
    return ref if relative == Path(".") else f"{ref}&dir={quote(relative.as_posix())}"


def _copied(word: str, cwd: Path) -> Flake | None:
    """The flake `word` names when it is a local one nix would copy."""
    base = word.partition("#")[0]
    if not _local(base):
        return None
    flake = locate((cwd / base.removeprefix("path:")).resolve())
    return flake if flake is not None and flake.copied else None


def _formatter(
    command: Command, flake: Flake, verb: str
) -> tuple[list[str], dict[str, str]]:
    """`nix fmt` and `nix formatter run|build` as the `nix run|build` of the
    workspace flake's formatter, run from the flake's root as nix fmt does."""
    words = command.words
    skipped = {*command.named, *command.positional}
    keep = [word for i, word in enumerate(words[: command.stop]) if i not in skipped]
    passed = [words[i] for i in command.positional] + command.passed
    lock = ["--output-lock-file", str(flake.directory / "flake.lock")]
    rewritten = [
        verb,
        *lock,
        f"{flake_ref(flake)}#formatter.{system()}",
        *keep,
        *(["--", *passed] if passed and verb == "run" else []),
    ]
    return rewritten, {"PRJ_ROOT": str(flake.directory)}


def rewritten(command: Command, cwd: Path) -> tuple[list[str], dict[str, str]] | None:
    """`command` with every local flake of a jj workspace named by its
    commit, and the environment changes that go with it; None when no word
    names such a flake.

    nix writes a lock file it had to create or update into the repository
    the ref names, the main checkout, so the workspace's own goes to the
    workspace (--output-lock-file); that flag covers every flake the command
    locks, so a command that locks another flake too writes none."""
    verb = FORMATTERS.get(tuple(command.path))
    if verb is not None:
        flake = _copied(".", cwd)
        return None if flake is None else _formatter(command, flake, verb)
    words = list(command.words)
    targets = _flake_words(command)
    if command.path == ["flake", "update"]:
        targets = [index + 1 for index in command.flags.get("flake", [])]
    takes = command.path == ["flake", "update"] or any(
        label == "installables" or label in FLAKE_ARGS for label in command.args
    )
    # nix reads `.` when no flake is named, except for nix eval
    implicit = (
        _copied(".", cwd)
        if takes
        and not targets
        and (command.path == ["flake", "update"] or not command.positional)
        and command.path != ["eval"]
        and not (NOT_FLAKES | {"stdin", "all"}) & command.flags.keys()
        else None
    )
    rewrites: dict[int, Flake] = {}
    for index in [*targets, *(i + 1 for i in command.flags.get("inputs-from", []))]:
        flake = _copied(words[index], cwd)
        if flake is not None:
            rewrites[index] = flake
    if not rewrites and implicit is None:
        return None
    if WRITING & command.flags.keys():
        raise NixError(
            f"--commit-lock-file would commit in the main checkout; {REFUSED}"
        )
    for index, flake in rewrites.items():
        _, hash_, attribute = words[index].partition("#")
        words[index] = flake_ref(flake) + hash_ + attribute
    locked = {rewrites[index].directory for index in targets if index in rewrites}
    others = [index for index in targets if index not in rewrites]
    if implicit is not None:
        ref = flake_ref(implicit)
        flag = ["--flake", ref] if command.path == ["flake", "update"] else [ref]
        words[command.end : command.end] = flag
        locked = {implicit.directory}
    if not {"output-lock-file", "no-write-lock-file"} & command.flags.keys():
        if len(locked) == 1 and not others:
            lock = ["--output-lock-file", str(locked.pop() / "flake.lock")]
        else:
            lock = ["--no-write-lock-file"]
        words[command.end : command.end] = lock
    return words, {}


# ---- dev shells ----


def _shell_files(flake: Flake) -> list[str]:
    """The checkout's SHELL_FILES, relative to its root: what jj or git
    tracks, or a walk outside version control."""
    if flake.vcs == "jj":
        fileset = " | ".join(f'glob:"**/{pattern}"' for pattern in SHELL_FILES)
        output = _step(
            ["jj", "file", "list", "--ignore-working-copy", fileset],
            flake.root,
            "jj file list",
        )
        return output.splitlines()
    if flake.vcs == "git":
        specs = [f":(glob)**/{pattern}" for pattern in SHELL_FILES]
        output = _step(
            ["git", "ls-files", "-z", "--", *specs], flake.root, "git ls-files"
        )
        return [path for path in output.split("\0") if path]
    found = []
    for directory, names, entries in os.walk(flake.root):
        names[:] = [n for n in names if not n.startswith(".") and n not in UNWALKED]
        found += [
            os.path.relpath(os.path.join(directory, entry), flake.root)
            for entry in entries
            if any(fnmatch.fnmatch(entry, pattern) for pattern in SHELL_FILES)
        ]
    return found


def _key(flake: Flake, attribute: str) -> str:
    """Names the shell by what makes it: the system, the attribute, where the
    flake sits in its checkout, and the content of every shell file."""
    digest = hashlib.sha256()
    relative = flake.directory.relative_to(flake.root).as_posix()
    for part in (system(), attribute, relative):
        digest.update(part.encode() + b"\0")
    for path in sorted(_shell_files(flake)):
        try:
            content = (flake.root / path).read_bytes()
        except OSError:
            continue  # tracked, but deleted in the working copy
        digest.update(path.encode() + b"\0" + hashlib.sha256(content).digest())
    return digest.hexdigest()[:32]


def delta(before: dict[str, str], after: dict[str, str]) -> Change:
    """What a dev shell did to an environment: variables it set, prefixes it
    put before a list it kept (PATH), and variables it unset."""
    changed: dict[str, str] = {}
    prepended: dict[str, str] = {}
    for name, value in after.items():
        old = before.get(name)
        if name in VOLATILE or old == value:
            continue
        if old and value.endswith(":" + old):
            prepended[name] = value[: -len(old) - 1]
        else:
            changed[name] = value
    unset = [
        n for n in before if n not in after and n not in VOLATILE and n.isidentifier()
    ]
    return {"set": changed, "prepend": prepended, "unset": unset}


def applied(change: Change, base: dict[str, str]) -> dict[str, str]:
    """`base` as the dev shell leaves it."""
    unset = set(change.get("unset", ()))
    environment = {name: value for name, value in base.items() if name not in unset}
    environment.update(change.get("set", {}))
    for name, prefix in change.get("prepend", {}).items():
        environment[name] = (
            f"{prefix}:{environment[name]}" if environment.get(name) else prefix
        )
    return environment


def capture(nix: str, arguments: list[str], profile: Path, cwd: Path | None) -> Change:
    """Build the dev shell, source it with its shellHook, and keep what it
    changed. The profile is a garbage-collector root for the shell. nix's
    progress and the hook's output go to stderr."""
    profile.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="albedo-nix-") as scratch:
        script = Path(scratch, "rc")
        with script.open("w") as out:
            built = subprocess.run(
                [
                    nix,
                    "print-dev-env",
                    *FEATURES,
                    "--profile",
                    str(profile),
                    *arguments,
                ],
                cwd=cwd,
                stdout=out,
            )
        if built.returncode != 0:
            raise NixError(f"nix print-dev-env failed (exit {built.returncode})")
        variables = json.loads(Path(os.path.realpath(profile)).read_text()).get(
            "variables", {}
        )
        bash = variables.get("shell", {}).get("value", "")
        if os.path.basename(bash) != "bash":
            bash = shutil.which("bash") or "bash"  # the script needs bash 4 or later
        sourced = subprocess.run(
            [
                bash,
                "--noprofile",
                "--norc",
                "-c",
                'exec 3>&1 1>&2; . "$1"; rm -rf "$NIX_BUILD_TOP"; env -0 >&3',
                "bash",
                str(script),
            ],
            cwd=cwd,
            stdout=subprocess.PIPE,
            timeout=STEP_TIMEOUT,
        )
        if sourced.returncode != 0:
            raise NixError(
                f"the dev shell's shellHook failed (exit {sourced.returncode})"
            )
    after = dict(
        item.split("=", 1)
        for item in sourced.stdout.decode("utf-8", "surrogateescape").split("\0")
        if "=" in item
    )
    change = delta(dict(os.environ), after)
    wrapper = sorted((n, v) for n, v in after.items() if n.startswith(WRAPPER))
    if wrapper:  # the shell's compiler-wrapper flags, for the cargo shim
        digest = hashlib.sha256(json.dumps(wrapper).encode()).hexdigest()[:16]
        change["set"]["ALBEDO_NIX_ENV"] = digest
    return change


def _cache() -> Path:
    return _home() / "cache" / "nix-develop"


def _cached(key: str, ttl: float | None) -> dict[str, Any] | None:
    entry = _cache() / f"{key}.json"
    try:
        record = json.loads(entry.read_text())
    except (OSError, ValueError):
        return None
    profile = _cache() / record.get("profile", key)
    stale = ttl is not None and time.time() - float(record.get("created", 0)) > ttl
    if stale or not os.path.exists(profile):  # collected since, or never built
        return None
    os.utime(entry)
    return record


def _keep(key: str, record: dict[str, Any]) -> None:
    """Store a shell, then drop the least recently used past CACHE_LIMIT."""
    cache = _cache()
    temporary = cache / f".{key}.{os.getpid()}"
    temporary.write_text(json.dumps({**record, "created": time.time()}))
    temporary.replace(cache / f"{key}.json")
    entries = sorted(cache.glob("*.json"), key=lambda path: path.stat().st_mtime)
    for old in entries[:-CACHE_LIMIT]:
        profile = cache / old.stem
        for path in [
            old,
            profile,
            profile.with_suffix(".lock"),
            *cache.glob(f"{old.stem}-*-link"),
        ]:
            path.unlink(missing_ok=True)


def dev_shell(nix: str, installable: str, cwd: Path) -> Change | None:
    """The cached dev shell for `installable`, built first if it is not
    cached; None for a local installable with no flake.nix. Two shims asking
    for the same shell at once share one build."""
    base, hash_, attribute = installable.partition("#")
    if _local(base):
        flake = locate((cwd / base.removeprefix("path:")).resolve())
        if flake is None:
            return None
        key, ttl, where = _key(flake, attribute), None, flake.directory
    else:  # nixpkgs#hello, github:owner/repo: nothing to copy
        flake, ttl, where = None, REMOTE_TTL, None
        key = hashlib.sha256(f"{system()}\0{installable}".encode()).hexdigest()[:32]
    record = _cached(key, ttl)
    if record is not None:
        return record["delta"]
    _cache().mkdir(parents=True, exist_ok=True)
    with (_cache() / f"{key}.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        record = _cached(key, ttl)  # built while this one waited
        if record is None:
            arguments = [installable]
            if flake is not None:
                ref = flake_ref(flake)
                arguments = [ref + hash_ + attribute]
                if flake.copied:
                    arguments += [
                        "--output-lock-file",
                        str(flake.directory / "flake.lock"),
                    ]
            print(
                f"{NOTE} building the dev shell for {where or installable}; "
                "later runs reuse it until its nix files change",
                file=sys.stderr,
            )
            change = capture(nix, arguments, _cache() / key, where)
            record = {"ref": arguments[0], "delta": change, "profile": key}
            _keep(key, record)
            # nix may have written the lock file it locked, a shell file too
            if flake is not None and (written := _key(flake, attribute)) != key:
                _keep(written, record)
            return change
    return record["delta"]


# ---- the shim ----


def develop(nix: str, here: str, command: Command, cwd: Path) -> None:
    """Run a `nix develop ... -c program` in its cached dev shell; return
    when a flag asks for more than the shell's environment."""
    if command.path != ["develop"] or not command.program:
        return
    if set(command.flags) - QUIET - {"command"}:
        return
    named = [command.words[index] for index in command.positional]
    change = dev_shell(nix, named[0] if named else ".", cwd)
    if change is None:
        return
    environment = applied(change, dict(os.environ))
    # the shims stay first, ahead of the shell's own programs
    shims = [
        entry
        for entry in os.environ.get("PATH", "").split(os.pathsep)
        if Path(entry).parent == Path(here).parent
    ]
    rest = environment.get("PATH", "").split(os.pathsep)
    environment["PATH"] = os.pathsep.join(
        [*shims, *(entry for entry in rest if entry not in shims)]
    )
    found = shutil.which(command.program[0], path=environment["PATH"])
    if found is None:
        sys.exit(f"{NOTE} {command.program[0]}: not found in the dev shell")
    os.execve(found, command.program, environment)


def main(argv: list[str]) -> NoReturn:
    here, words = argv[1], argv[2:]
    path = os.environ.get("PATH", "").split(os.pathsep)
    nix = shutil.which("nix", path=os.pathsep.join(e for e in path if e != here))
    if nix is None:
        sys.exit(f"{NOTE} nix is not on PATH")
    cwd = Path.cwd()
    try:
        table = flag_table(nix)
    except NixError as error:
        flake = locate(cwd)
        if flake is not None and flake.copied:
            sys.exit(f"{NOTE} {error}\n{NOTE} {REFUSED}")
        os.execv(nix, [nix, *words])
    try:
        command = read(words, table)
    except Unreadable:
        os.execv(nix, [nix, *words])  # a flag nix does not know: nix says so
    try:
        develop(nix, here, command, cwd)
        result = rewritten(command, cwd)
    except NixError as error:
        sys.exit(f"{NOTE} {error}")
    if result is None:
        os.execv(nix, [nix, *words])
    words, extra = result
    print(
        f"{NOTE} reading this jj workspace from its commit, not copying it: "
        f"nix {' '.join(words)}",
        file=sys.stderr,
    )
    os.execve(nix, [nix, *words], {**os.environ, **extra})


if __name__ == "__main__":
    main(sys.argv)
