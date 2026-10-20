"""Google Colab GPU runtimes: list, launch and stop them, and reach one over `remote`.

The account is the one `/login colab` saved. The daemon owns its tokens: the
kernel asks the `colab.account` host route for a fresh access token and never
reads creds.json. A runtime is reached through the ssh-over-websocket proxy
Colab exposes, run as ssh's ProxyCommand by `albedo_plugins.ws` (see `connect`).
"""

from __future__ import annotations

import asyncio
import base64
import http.client
import json
import re
import secrets
import shlex
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path
from typing import Any

import albedo_ssh
from albedo_api import PythonApi, Record
from albedo_plugins.remote import RemoteError, remote

API_BASE = "https://colab.research.google.com"
CONNECT_TIMEOUT = 60.0
API_TIMEOUT = 30.0
PRIV = Path(__file__).resolve().parent.parent
REFUSALS = {
    401: "authentication failed: invalid or expired token",
    403: "request forbidden",
    404: "resource not found",
    503: "GPU capacity exhausted",
}


class ColabError(RuntimeError):
    """A Google Colab operation failed; `status` is the HTTP status, if there was one."""

    def __init__(self, message: str, status: int | None = None) -> None:
        super().__init__(message)
        self.status = status


class ColabSshSessionError(ColabError):
    """The runtime refused ssh because its single session slot is occupied."""


class ColabInstance(Record):
    """One Google Colab runtime instance."""

    id: str
    endpoint: str
    name: str | None
    variant: str
    accelerator: str | None
    shape: str
    status: str
    url: str | None
    token: str | None
    token_expires_in: int | None
    raw: dict[str, Any]

    @property
    def gpu(self) -> str | None:
        """GPU accelerator name (e.g. 'T4', 'A100') or None."""
        return self.get("accelerator") if self.get("variant") == "GPU" else None

    @property
    def tpu(self) -> str | None:
        """TPU accelerator name or None."""
        return self.get("accelerator") if self.get("variant") == "TPU" else None

    @property
    def mem(self) -> str:
        """Memory size: 'high' or 'standard'."""
        return "high" if self.get("shape") in ("high", "highmem") else "standard"

    async def connect(self, **options: Any) -> Any:
        """`colab.connect(self, **options)`."""
        return await connect(self, **options)

    async def stop(self) -> Record:
        """`colab.stop(self)`."""
        return await stop(self)

    def __str__(self) -> str:
        parts = [f"ColabInstance(id={self.get('id', '')!r}"]
        for field in ("name", "variant", "accelerator", "status"):
            if self.get(field):
                parts.append(f"{field}={self[field]!r}")
        if self.mem != "standard":
            parts.append(f"mem={self.mem!r}")
        return ", ".join(parts) + ")"

    __repr__ = __str__


class ColabStatus(Record):
    """Overall Google Colab status and active instances."""

    authenticated: bool
    email: str | None
    instances: list[ColabInstance]
    active: int

    def __str__(self) -> str:
        head = f"Colab Status: {'authenticated' if self.get('authenticated') else 'unauthenticated'}"
        if self.get("email"):
            head += f" ({self['email']})"
        lines = [head, f"Active instances: {self.get('active', 0)}"]
        lines += [f"  - {inst}" for inst in self.get("instances", [])]
        return "\n".join(lines)

    __repr__ = __str__


host_call: Any = None
HostErrorType: type[Exception] = Exception


async def _account() -> dict[str, str]:
    """The signed-in account: `access` token and `email`, refreshed by the daemon."""
    try:
        return await host_call("colab.account", {})
    except HostErrorType as error:
        raise ColabError(str(error)) from error


def _send(
    method: str, url: str, headers: dict[str, str], body: bytes | None, timeout: float
) -> tuple[int, bytes]:
    request = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.read()
    except urllib.error.URLError as error:
        raise ColabError(f"network error connecting to Colab at {url}: {error.reason}")


def _plain(body: bytes) -> str:
    """The body as text, without the `)]}'` line Google puts before JSON."""
    text = body.decode("utf-8", errors="replace").strip()
    if text.startswith(")]}'"):
        text = text.partition("\n")[2].strip()
    return text


async def _request(
    method: str,
    path: str,
    *,
    query: dict[str, str] | None = None,
    headers: dict[str, str] | None = None,
    timeout: float = API_TIMEOUT,
) -> Any:
    url = f"{API_BASE}{path}?{urllib.parse.urlencode(query or {})}"
    status, body = await asyncio.to_thread(
        _send,
        method,
        url,
        {
            "Authorization": f"Bearer {(await _account())['access']}",
            "X-Colab-Tunnel": "Google",
            "Accept": "application/json",
            "X-Colab-Client-Agent": "colab-cli",
            "User-Agent": "albedo-colab-plugin/1.0",
            **(headers or {}),
        },
        None,
        timeout,
    )
    text = _plain(body)
    if status in (200, 201, 204):
        try:
            return json.loads(text) if text else {}
        except json.JSONDecodeError as error:
            raise ColabError(
                f"failed to parse Colab JSON response: {text[:200]}", status
            ) from error
    reason = REFUSALS.get(status, f"{method} {path} failed with HTTP {status}")
    raise ColabError(f"Colab {reason} ({status}): {text[:200]}", status)


def _parse_instance(item: dict[str, Any]) -> ColabInstance:
    endpoint = str(item.get("endpoint") or item.get("id") or "")
    proxy = item.get("runtimeProxyInfo")
    if not isinstance(proxy, dict):
        proxy = {}
    return ColabInstance(
        id=endpoint,
        endpoint=endpoint,
        name=item.get("name"),
        variant=item.get("variant", "GPU"),
        accelerator=item.get("accelerator"),
        shape=item.get("shape", "standard"),
        status=item.get("status", "active"),
        url=proxy.get("url"),
        token=proxy.get("token"),
        token_expires_in=proxy.get("tokenExpiresInSeconds"),
        raw=item,
    )


def _find(candidates: list[ColabInstance], ref: str | ColabInstance) -> ColabInstance:
    target = ref.id if isinstance(ref, ColabInstance) else str(ref)
    for inst in candidates:
        if target in (inst.id, inst.name):
            return inst
    raise ColabError(f"no Colab instance found matching id {target!r}")


async def instances() -> list[ColabInstance]:
    """Active Google Colab runtimes."""
    data = await _request("GET", "/tun/m/assignments", query={"authuser": "0"})
    items = data.get("assignments") if isinstance(data, dict) else data
    if not isinstance(items, list):
        return []
    return [_parse_instance(item) for item in items if isinstance(item, dict)]


async def status(id: str | None = None) -> ColabStatus | ColabInstance:
    """Active runtimes and the signed-in account, or one runtime by id or name."""
    active = await instances()
    if id is not None:
        return _find(active, id)
    account = await _account()
    return ColabStatus(
        authenticated=True,
        email=account.get("email") or None,
        instances=active,
        active=len(active),
    )


def _notebook_hash() -> str:
    """A 44-character web-safe Colab notebook hash (nbh)."""
    text = str(uuid.uuid4()).replace("-", "_")
    return text + "." * (44 - len(text))


async def launch(
    gpu: str | None = "T4",
    *,
    mem: str = "standard",
    shape: str | None = None,
    variant: str | None = None,
    tpu: str | None = None,
    name: str | None = None,
    timeout: float = CONNECT_TIMEOUT,
) -> ColabInstance:
    """Launch a Colab runtime, or return the one already assigned."""
    chosen = shape if shape is not None else mem
    high = chosen in ("high", "highmem")
    if tpu:
        kind, accelerator = variant or "TPU", tpu
    elif gpu:
        kind, accelerator = variant or "GPU", gpu
    else:
        kind, accelerator = variant or "CPU", None

    query = {"authuser": "0", "nbh": _notebook_hash(), "variant": kind}
    if accelerator is not None:
        query["accelerator"] = accelerator
    if high and accelerator not in ("L4", "v5e1", "v6e1", "V5E1", "V6E1"):
        query["shape"] = "hm"

    # The first GET returns an existing assignment or the XSRF token that lets
    # the POST provision a VM.
    answer = await _request("GET", "/tun/m/assign", query=query, timeout=timeout)
    if (
        isinstance(answer, dict)
        and "token" in answer
        and not ("endpoint" in answer or "runtimeProxyInfo" in answer)
    ):
        answer = await _request(
            "POST",
            "/tun/m/assign",
            query=query,
            headers={"X-Goog-Colab-Token": str(answer["token"])},
            timeout=timeout,
        )
    if not isinstance(answer, dict):
        raise ColabError(f"unexpected response from Colab assign: {answer}")

    assignment = answer.get("assignment", answer)
    assignment.setdefault("variant", kind)
    if accelerator:
        assignment.setdefault("accelerator", accelerator)
    assignment.setdefault("shape", chosen)
    if name:
        assignment.setdefault("name", name)
    return _parse_instance(assignment)


async def stop(id: str | ColabInstance) -> Record:
    """Stop an active Colab runtime, and forget the ssh name `connect` gave it."""
    endpoint = id.id if isinstance(id, ColabInstance) else str(id)
    path = f"/tun/m/unassign/{urllib.parse.quote(endpoint)}"
    albedo_ssh.unalias(_host(endpoint))
    try:
        # The GET hands out the XSRF token the POST commits with.
        answer = await _request("GET", path, query={"authuser": "0"})
        xsrf = answer.get("token") if isinstance(answer, dict) else None
        await _request(
            "POST",
            path,
            query={"authuser": "0"},
            headers={"X-Goog-Colab-Token": str(xsrf)} if xsrf else None,
        )
        return Record(id=endpoint, success=True, message="instance stopped")
    except ColabError as error:
        if error.status != 404:
            raise
        return Record(
            id=endpoint, success=False, message="instance not found or already stopped"
        )


def _host(endpoint: str) -> str:
    return f"colab-{endpoint}"


def _ssh_key(path: str | None) -> tuple[str | None, str]:
    """The private key ssh should offer (None: its own defaults) and the public
    key text Colab authorizes for the session."""
    if path:
        private = Path(path).expanduser()
        if private.suffix == ".pub":
            private = private.with_suffix("")
        candidates = [private]
    else:
        candidates = [
            Path.home() / ".ssh" / name for name in ("id_ed25519", "id_ecdsa")
        ]
    for key in candidates:
        public = key.with_name(key.name + ".pub")
        if public.is_file():
            return (str(key) if path else None), public.read_text(
                encoding="utf-8"
            ).strip()
    raise ColabError(
        "no ssh public key found; create one with `ssh-keygen -t ed25519` or pass ssh_key="
    )


async def connect(
    instance: str | ColabInstance,
    *,
    remote_cwd: str | None = None,
    python: str | None = None,
    modules: list[str] | None = None,
    timeout: float = CONNECT_TIMEOUT,
    ssh_key: str | None = None,
) -> Any:
    """Connect `remote` to a Colab runtime and return the RemoteConnection.

    ssh runs `python -m albedo_plugins.ws` as its ProxyCommand, bridging stdio to the
    runtime's websocket proxy. The proxy url and token come from a fresh listing
    (they expire) and reach the bridge through its environment, never a command
    line. Nothing is written to ~/.ssh/config.
    """
    live = _find(await instances(), instance)
    if not (live.url and live.token):
        raise ColabError(f"Colab instance {live.id} has no runtime proxy yet")
    private, public = _ssh_key(ssh_key)
    url = urllib.parse.urlsplit(live.url)
    socket_url = urllib.parse.urlunsplit(
        (
            "wss" if url.scheme == "https" else "ws",
            url.netloc,
            "/colab/ssh",
            urllib.parse.urlencode({"colab-runtime-proxy-token": live.token}),
            "",
        )
    )
    proxy = f"{shlex.quote(sys.executable)} -m albedo_plugins.ws".replace("%", "%%")
    host = _host(live.id)
    albedo_ssh.alias(
        host,
        [
            f"ProxyCommand={proxy}",
            "User=root",
            "StrictHostKeyChecking=no",
            "UserKnownHostsFile=/dev/null",
            *([f"IdentityFile={private}", "IdentitiesOnly=yes"] if private else []),
        ],
        {
            "PYTHONPATH": str(PRIV),
            "ALBEDO_WS_URL": socket_url,
            "ALBEDO_WS_HEADERS": json.dumps({"X-Colab-Ssh-Pubkey": public}),
        },
    )
    try:
        return await remote.connect(
            host,
            remote_cwd=remote_cwd or "/content",
            python=python or "/usr/bin/python3",
            modules=modules,
            timeout=timeout,
        )
    except RemoteError as error:
        try:
            occupied = await asyncio.to_thread(
                _ssh_session_occupied, socket_url, public, min(timeout, 10.0)
            )
        except (OSError, http.client.HTTPException):
            occupied = False
        if occupied:
            raise ColabSshSessionError(
                "Colab allows one ssh session per runtime; a previously held session "
                "was not released. This is server-side and does not clear on retry. "
                "Use the HTTP file routes to keep working: colab.contents(), "
                "colab.read(), colab.pull() (and colab.runtime_status() for liveness). "
                "stop()/unassign is the only forceful reset and destroys the VM.",
                429,
            ) from error
        raise


def _ssh_session_occupied(url: str, public: str, timeout: float) -> bool:
    target = urllib.parse.urlsplit(url)
    transport = (
        http.client.HTTPSConnection
        if target.scheme == "wss"
        else http.client.HTTPConnection
    )
    connection = transport(target.netloc, timeout=timeout)
    try:
        connection.request(
            "GET",
            f"{target.path}?{target.query}",
            headers={
                "Upgrade": "websocket",
                "Connection": "Upgrade",
                "Sec-WebSocket-Key": base64.b64encode(secrets.token_bytes(16)).decode(),
                "Sec-WebSocket-Version": "13",
                "X-Colab-Ssh-Pubkey": public,
            },
        )
        response = connection.getresponse()
        return response.status == 429 and b"already-active-session" in response.read(
            4096
        )
    finally:
        connection.close()


async def _runtime_url(instance: str | ColabInstance, path: str, **query: str) -> str:
    live = _find(await instances(), instance)
    if not (live.url and live.token):
        raise ColabError(f"Colab instance {live.id} has no runtime proxy yet")
    target = urllib.parse.urlsplit(live.url)
    return urllib.parse.urlunsplit(
        (
            target.scheme,
            target.netloc,
            path,
            urllib.parse.urlencode({"colab-runtime-proxy-token": live.token, **query}),
            "",
        )
    )


def _runtime_open(url: str, headers: dict[str, str] | None = None) -> Any:
    request = urllib.request.Request(
        url, headers={"X-Colab-Client-Agent": "colab-cli", **(headers or {})}
    )
    try:
        return urllib.request.urlopen(request, timeout=API_TIMEOUT)
    except urllib.error.HTTPError as error:
        status = error.code
        error.close()
        raise ColabError(
            f"Colab runtime HTTP request failed ({status})", status
        ) from None
    except urllib.error.URLError:
        raise ColabError(
            "network error connecting to the Colab runtime proxy"
        ) from None


def _runtime_json(url: str) -> Any:
    with _runtime_open(url) as response:
        return json.load(response)


async def runtime_status(instance: str | ColabInstance) -> Record:
    """Jupyter liveness over HTTPS, independent of the ssh session slot."""
    url = await _runtime_url(instance, "/api/status")
    return Record(await asyncio.to_thread(_runtime_json, url))


async def contents(
    instance: str | ColabInstance, path: str = "", *, content: bool = True
) -> Record:
    """Jupyter metadata, directory entries, or text-file content over HTTPS.

    Paths are relative to Jupyter's root, not the ssh working directory.
    Use content=False for file metadata without loading the file.
    """
    route = "/api/contents/" + urllib.parse.quote(path.lstrip("/"), safe="/")
    url = await _runtime_url(
        instance, route, content="1" if content else "0", format="text"
    )
    return Record(await asyncio.to_thread(_runtime_json, url))


async def read(instance: str | ColabInstance, path: str) -> str:
    """Read one text file over HTTPS; use pull() for large or binary files."""
    result = await contents(instance, path)
    if result.get("type") != "file" or not isinstance(result.get("content"), str):
        raise ColabError(f"not a text file: {path!r}")
    return result["content"]


def _pull(url: str, local: Path, resume: bool) -> Path:
    have = local.stat().st_size if resume and local.exists() else 0
    headers = {"Range": f"bytes={have}-"} if have else {}
    with _runtime_open(url, headers) as response:
        total = None
        if response.status == 206:
            match = re.fullmatch(
                r"bytes (\d+)-(\d+)/(\d+)", response.headers.get("Content-Range", "")
            )
            if not match or int(match[1]) != have or int(match[2]) + 1 != int(match[3]):
                raise ColabError(
                    "invalid Content-Range from Colab; local file left unchanged"
                )
            total = int(match[3])
        elif response.status == 200:
            # An ignored Range must replace the partial file, not append to it.
            have = 0
            length = response.headers.get("Content-Length")
            total = int(length) if length is not None else None
        else:
            raise ColabError(f"unexpected Colab download response ({response.status})")
        local.parent.mkdir(parents=True, exist_ok=True)
        with local.open("ab" if have else "wb") as output:
            while chunk := response.read(1 << 20):
                output.write(chunk)
                have += len(chunk)
        if total is not None and have != total:
            raise ColabError(
                f"incomplete Colab download: got {have} of {total} bytes; retry to resume"
            )
    return local


async def pull(
    instance: str | ColabInstance,
    remote: str,
    local: str | Path,
    *,
    resume: bool = True,
) -> Path:
    """Stream a Jupyter-root-relative file to disk over HTTPS, without ssh.

    Partial downloads remain on disk for retry. Resume assumes the remote file
    has not changed; use resume=False for mutable files. A 416 response is an
    error, not proof that the local file is complete.
    """
    route = "/files/" + urllib.parse.quote(remote.lstrip("/"), safe="/")
    url = await _runtime_url(instance, route)
    return await asyncio.to_thread(_pull, url, Path(local).expanduser(), resume)


class Colab:
    """Google Colab management interface."""

    instances = staticmethod(instances)
    status = staticmethod(status)
    launch = staticmethod(launch)
    stop = staticmethod(stop)
    connect = staticmethod(connect)
    runtime_status = staticmethod(runtime_status)
    contents = staticmethod(contents)
    read = staticmethod(read)
    pull = staticmethod(pull)


colab = Colab()


def setup(api: PythonApi) -> dict[str, object]:
    """Expose the Colab plugin in the Python kernel environment."""
    global host_call, HostErrorType
    host_call, HostErrorType = api.host, api.HostError
    return {
        "colab": colab,
        "ColabError": ColabError,
        "ColabSshSessionError": ColabSshSessionError,
        "ColabInstance": ColabInstance,
        "ColabStatus": ColabStatus,
    }
