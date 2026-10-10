"""Google Colab GPU runtimes: manage instances and connect via remote kernels.

This plugin lets the model and user query active Google Colab assignments,
launch GPU/TPU/CPU instances, terminate them, and connect to them over SSH
delegating to albedo's `remote` tool.

Credentials are read from `$ALBEDO_HOME/creds.json` under `accounts["google-colab"]`.
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import socket
import ssl
import struct
import subprocess
import sys
import threading
import urllib.error
import urllib.parse
import urllib.request
import uuid
from typing import Any, Awaitable, Callable

from albedo_api import PythonApi, Record

COLAB_API_BASE = "https://colab.research.google.com"
DEFAULT_CONNECT_TIMEOUT = 60.0
DEFAULT_API_TIMEOUT = 30.0


class ColabError(RuntimeError):
    """A Google Colab operation failed; the message names what happened."""


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
        s = self.get("shape", "standard")
        return "high" if s in ("high", "highmem") else "standard"

    def __str__(self) -> str:
        parts = [f"ColabInstance(id={self.get('id', '')!r}"]
        if self.get("name"):
            parts.append(f"name={self['name']!r}")
        if self.get("variant"):
            parts.append(f"variant={self['variant']!r}")
        if self.get("accelerator"):
            parts.append(f"accelerator={self['accelerator']!r}")
        if self.mem != "standard":
            parts.append(f"mem={self.mem!r}")
        if self.get("status"):
            parts.append(f"status={self['status']!r}")
        return ", ".join(parts) + ")"

    __repr__ = __str__


class ColabStatus(Record):
    """Overall Google Colab status and active instances."""

    authenticated: bool
    email: str | None
    instances: list[ColabInstance]
    active: int

    def __str__(self) -> str:
        status_line = f"Colab Status: {'authenticated' if self.get('authenticated') else 'unauthenticated'}"
        if self.get("email"):
            status_line += f" ({self['email']})"
        parts = [status_line, f"Active instances: {self.get('active', 0)}"]
        for inst in self.get("instances", []):
            parts.append(f"  - {inst}")
        return "\n".join(parts)

    __repr__ = __str__


# In-memory overrides
_configured: dict[str, Any] = {}

loop: asyncio.AbstractEventLoop | None = None
host_call: Callable[[str, dict[str, Any]], Awaitable[Any]] | None = None


def configure(
    *,
    token: str | None = None,
    api_base: str | None = None,
    proxy_mode: str | None = None,
    ssh_key: str | None = None,
) -> None:
    """Override Google Colab runtime options in this session."""
    if token is not None:
        _configured["token"] = token
    if api_base is not None:
        _configured["api_base"] = api_base.rstrip("/")
    if proxy_mode is not None:
        _configured["proxy_mode"] = proxy_mode
    if ssh_key is not None:
        _configured["ssh_key"] = ssh_key


def reset_configuration() -> None:
    """Clear in-memory configuration overrides."""
    _configured.clear()


def _get_albedo_home() -> Path:
    val = os.environ.get("ALBEDO_HOME")
    if val:
        return Path(val)
    return Path.home() / ".albedo"


def read_colab_credentials() -> dict[str, Any]:
    """Read Google Colab OAuth credentials from creds.json."""
    creds_path = _get_albedo_home() / "creds.json"
    if not creds_path.is_file():
        raise ColabError(
            f"no creds.json found at {creds_path}. Sign in with `/login colab`."
        )

    try:
        content = creds_path.read_text(encoding="utf-8")
        data = json.loads(content)
    except Exception as error:
        raise ColabError(f"Failed to read {creds_path}: {error}") from error

    accounts = data.get("accounts", {})
    entry = accounts.get("google-colab") or accounts.get("colab")
    if not entry:
        raise ColabError(
            "no 'google-colab' account found in credentials. Sign in with `/login colab`."
        )

    # Could be a single account dict or a list of accounts
    if isinstance(entry, list):
        if not entry:
            raise ColabError("Google Colab account list in creds.json is empty.")
        # Pick selected or first
        selected = next((acc for acc in entry if acc.get("selected")), entry[0])
        return selected

    if isinstance(entry, dict):
        return entry

    if isinstance(entry, str):
        return {"token": entry}

    raise ColabError("Invalid format for Google Colab credentials in creds.json.")


def get_token() -> str:
    """Retrieve the OAuth access token for Google Colab."""
    if _configured.get("token"):
        return str(_configured["token"])
    if os.environ.get("COLAB_TOKEN"):
        return os.environ["COLAB_TOKEN"]

    cred = read_colab_credentials()
    token = cred.get("access") or cred.get("accessToken") or cred.get("token")
    if not token or not isinstance(token, str):
        raise ColabError("Google Colab credential has no access token")
    return token.strip()


def get_api_base() -> str:
    """The Colab API base URL."""
    return str(
        _configured.get("api_base")
        or os.environ.get("COLAB_API_BASE")
        or COLAB_API_BASE
    ).rstrip("/")


def _sync_http_request(
    method: str,
    url: str,
    headers: dict[str, str],
    body: bytes | None,
    timeout: float,
) -> tuple[int, bytes]:
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as error:
        err_body = error.read()
        return error.code, err_body
    except urllib.error.URLError as error:
        raise ColabError(
            f"network error connecting to Colab at {url}: {error.reason}"
        ) from error


def _clean_json_body(body_bytes: bytes) -> Any:
    text = body_bytes.decode("utf-8", errors="replace").strip()
    if text.startswith(")]}'"):
        _, _, text = text.partition("\n")
        text = text.strip()
    if not text:
        return {}
    try:
        return json.loads(text)
    except json.JSONDecodeError as error:
        raise ColabError(
            f"failed to parse Colab JSON response: {error} ({text[:200]})"
        ) from error


async def _api_request(
    method: str,
    path: str,
    *,
    token: str | None = None,
    json_data: dict[str, Any] | None = None,
    query: dict[str, str] | None = None,
    extra_headers: dict[str, str] | None = None,
    timeout: float = DEFAULT_API_TIMEOUT,
) -> Any:
    auth_token = token or get_token()
    base = get_api_base()
    url = f"{base}{path}"
    if query:
        sep = "&" if "?" in url else "?"
        url += f"{sep}{urllib.parse.urlencode(query)}"

    headers = {
        "Authorization": f"Bearer {auth_token}",
        "X-Colab-Tunnel": "Google",
        "Accept": "application/json",
        "X-Colab-Client-Agent": "colab-cli",
        "User-Agent": "albedo-colab-plugin/1.0",
    }
    if extra_headers:
        headers.update(extra_headers)

    body: bytes | None = None
    if json_data is not None:
        headers["Content-Type"] = "application/json"
        body = json.dumps(json_data).encode("utf-8")

    status_code, resp_bytes = await asyncio.to_thread(
        _sync_http_request, method, url, headers, body, timeout
    )

    if status_code in (200, 201, 204):
        if status_code == 204 or not resp_bytes:
            return {}
        return _clean_json_body(resp_bytes)

    # Handle error responses
    err_text = resp_bytes.decode("utf-8", errors="replace").strip()
    if err_text.startswith(")]}'"):
        _, _, err_text = err_text.partition("\n")
        err_text = err_text.strip()

    if status_code == 401:
        raise ColabError(
            f"Colab authentication failed (401 Unauthorized): invalid or expired token ({err_text[:200]})"
        )
    if status_code == 403:
        raise ColabError(f"Colab request forbidden (403 Forbidden): {err_text[:200]}")
    if status_code == 404:
        raise ColabError(f"Colab resource not found (404 Not Found): {err_text[:200]}")
    if status_code == 503:
        raise ColabError(
            f"Colab GPU capacity exhausted (503 Service Unavailable): {err_text[:200]}"
        )
    raise ColabError(
        f"Colab API request {method} {path} failed with HTTP {status_code}: {err_text[:200]}"
    )


def _parse_instance(item: dict[str, Any]) -> ColabInstance:
    endpoint = str(item.get("endpoint") or item.get("id") or "")
    proxy_info = item.get("runtimeProxyInfo")
    if not isinstance(proxy_info, dict):
        proxy_info = {}
    return ColabInstance(
        id=endpoint,
        endpoint=endpoint,
        name=item.get("name"),
        variant=item.get("variant", "GPU"),
        accelerator=item.get("accelerator"),
        shape=item.get("shape", "standard"),
        status=item.get("status", "active"),
        url=proxy_info.get("url"),
        token=proxy_info.get("token"),
        token_expires_in=proxy_info.get("tokenExpiresInSeconds"),
        raw=item,
    )


async def instances(*, token: str | None = None) -> list[ColabInstance]:
    """Query active Google Colab assignments / instances."""
    data = await _api_request(
        "GET", "/tun/m/assignments", token=token, query={"authuser": "0"}
    )
    raw_list = data.get("assignments") if isinstance(data, dict) else data
    if not isinstance(raw_list, list):
        return []
    return [_parse_instance(item) for item in raw_list if isinstance(item, dict)]


async def status(
    id: str | None = None, *, token: str | None = None
) -> ColabStatus | ColabInstance:
    """Get active Colab status summary or check a specific instance."""
    insts = await instances(token=token)
    if id is not None:
        target = str(id)
        for inst in insts:
            if inst.id == target or inst.endpoint == target or inst.name == target:
                return inst
        raise ColabError(f"no Colab instance found matching id {id!r}")

    email: str | None = None
    try:
        cred = read_colab_credentials()
        email = cred.get("email")
    except Exception:
        pass

    return ColabStatus(
        authenticated=True,
        email=email,
        instances=insts,
        active=len(insts),
    )


def _format_notebook_hash(u: uuid.UUID | None = None) -> str:
    """Format a UUID as a 44-character web-safe Colab notebook hash (nbh)."""
    val = u or uuid.uuid4()
    uuid_str = str(val).replace("-", "_")
    return uuid_str + "." * (44 - len(uuid_str))


async def launch(
    gpu: str | None = "T4",
    *,
    mem: str = "standard",
    shape: str | None = None,
    variant: str | None = None,
    tpu: str | None = None,
    name: str | None = None,
    token: str | None = None,
    timeout: float = DEFAULT_CONNECT_TIMEOUT,
) -> ColabInstance:
    """Launch or request a new Google Colab instance."""
    # Resolve memory size: mem="standard" | "high" (or shape="standard" | "highmem")
    chosen_mem = shape if shape is not None else mem
    wire_shape = "highmem" if chosen_mem in ("high", "highmem") else "standard"

    if tpu:
        var = variant or "TPU"
        acc: str | None = tpu
    elif gpu:
        var = variant or "GPU"
        acc = gpu
    else:
        var = variant or "CPU"
        acc = None

    assign_query: dict[str, str] = {
        "authuser": "0",
        "nbh": _format_notebook_hash(),
        "variant": var,
    }
    if acc is not None:
        assign_query["accelerator"] = acc
    if wire_shape == "highmem" and acc not in ("L4", "v5e1", "v6e1", "V5E1", "V6E1"):
        assign_query["shape"] = "hm"

    # Step 1: GET to check for an existing assignment or obtain XSRF token
    pre_data = await _api_request(
        "GET",
        "/tun/m/assign",
        token=token,
        query=assign_query,
        timeout=timeout,
    )

    assignment: dict[str, Any]
    if isinstance(pre_data, dict) and (
        "endpoint" in pre_data or "runtimeProxyInfo" in pre_data
    ):
        assignment = pre_data.get("assignment", pre_data)
    elif isinstance(pre_data, dict) and "token" in pre_data:
        # Step 2: POST with XSRF token to provision VM
        xsrf_token = str(pre_data["token"])
        post_data = await _api_request(
            "POST",
            "/tun/m/assign",
            token=token,
            query=assign_query,
            extra_headers={"X-Goog-Colab-Token": xsrf_token},
            timeout=timeout,
        )
        if isinstance(post_data, dict):
            assignment = post_data.get("assignment", post_data)
        else:
            raise ColabError(f"unexpected response from Colab assign: {post_data}")
    elif isinstance(pre_data, dict):
        assignment = pre_data.get("assignment", pre_data)
    else:
        raise ColabError(f"unexpected response from Colab assign: {pre_data}")

    if isinstance(assignment, dict):
        assignment.setdefault("variant", var)
        if acc:
            assignment.setdefault("accelerator", acc)
        assignment.setdefault("shape", chosen_mem)
        if name:
            assignment.setdefault("name", name)
        return _parse_instance(assignment)

    raise ColabError(f"unexpected response from Colab assign: {pre_data}")


# Alias
request = launch


async def stop(id: str | ColabInstance, *, token: str | None = None) -> Record:
    """Stop / unassign an active Google Colab instance."""
    endpoint = id.id if isinstance(id, ColabInstance) else str(id)
    endpoint_quoted = urllib.parse.quote(endpoint)
    unassign_path = f"/tun/m/unassign/{endpoint_quoted}"
    try:
        # Step 1: GET to acquire the unassign XSRF token
        get_data = await _api_request(
            "GET",
            unassign_path,
            token=token,
            query={"authuser": "0"},
        )
        xsrf_token = get_data.get("token") if isinstance(get_data, dict) else None
        extra_headers = {"X-Goog-Colab-Token": str(xsrf_token)} if xsrf_token else None

        # Step 2: POST to commit unassign
        await _api_request(
            "POST",
            unassign_path,
            token=token,
            extra_headers=extra_headers,
            query={"authuser": "0"},
        )
        return Record(id=endpoint, success=True, message="instance stopped")
    except ColabError as error:
        if "404" in str(error):
            return Record(
                id=endpoint,
                success=False,
                message="instance not found or already stopped",
            )
        raise


# Alias
unassign = stop


def ssh_config_block(
    host_alias: str,
    proxy_cmd: str,
    user: str = "root",
    identity_file: str | None = None,
) -> str:
    """Format an OpenSSH config block with albedo markers."""
    lines = [
        f"# albedo: colab begin {host_alias}",
        f"Host {host_alias}",
        f"    HostName {host_alias}",
        f"    User {user}",
        f"    ProxyCommand {proxy_cmd}",
        "    StrictHostKeyChecking no",
        "    UserKnownHostsFile /dev/null",
    ]
    if identity_file:
        lines.append(f"    IdentityFile {identity_file}")
    lines.append(f"# albedo: colab end {host_alias}")
    return "\n".join(lines) + "\n"


def configure_ssh(
    session: str,
    proxy_cmd: str,
    *,
    host_alias: str | None = None,
    ssh_config_path: str | Path | None = None,
    user: str = "root",
    identity_file: str | None = None,
) -> str:
    """Ensure ~/.ssh/config contains the entry for this Colab session."""
    alias = host_alias or (
        session if session.startswith("colab-") else f"colab-{session}"
    )
    config_path = (
        Path(ssh_config_path) if ssh_config_path else Path.home() / ".ssh" / "config"
    )
    config_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)

    block = ssh_config_block(alias, proxy_cmd, user=user, identity_file=identity_file)
    existing = ""
    if config_path.is_file():
        existing = config_path.read_text(encoding="utf-8")

    begin_marker = f"# albedo: colab begin {alias}"
    end_marker = f"# albedo: colab end {alias}"

    if begin_marker in existing and end_marker in existing:
        pattern = re.compile(
            re.escape(begin_marker) + r".*?" + re.escape(end_marker) + r"\n?",
            re.DOTALL,
        )
        new_content = pattern.sub(block, existing)
    else:
        new_content = existing
        if new_content and not new_content.endswith("\n"):
            new_content += "\n"
        new_content += block

    config_path.write_text(new_content, encoding="utf-8")
    config_path.chmod(0o600)
    return alias


def remove_ssh_config(
    host_alias: str,
    *,
    ssh_config_path: str | Path | None = None,
) -> bool:
    """Remove the managed OpenSSH config block for host_alias."""
    config_path = (
        Path(ssh_config_path) if ssh_config_path else Path.home() / ".ssh" / "config"
    )
    if not config_path.is_file():
        return False
    existing = config_path.read_text(encoding="utf-8")
    begin_marker = f"# albedo: colab begin {host_alias}"
    end_marker = f"# albedo: colab end {host_alias}"
    if begin_marker not in existing:
        return False
    pattern = re.compile(
        re.escape(begin_marker) + r".*?" + re.escape(end_marker) + r"\n?",
        re.DOTALL,
    )
    new_content = pattern.sub("", existing)
    config_path.write_text(new_content, encoding="utf-8")
    return True


async def _default_remote_connect(*args: Any, **kwargs: Any) -> Any:
    from albedo_plugins.remote import remote

    return await remote.connect(*args, **kwargs)


_remote_connect_fn: Callable[..., Awaitable[Any]] = _default_remote_connect


def set_remote_connect(fn: Callable[..., Awaitable[Any]]) -> None:
    """Set the remote.connect delegate (useful for testing)."""
    global _remote_connect_fn
    _remote_connect_fn = fn


async def connect(
    instance_id_or_name: str | ColabInstance,
    *,
    remote_cwd: str | None = None,
    python: str | None = None,
    modules: list[str] | None = None,
    timeout: float = DEFAULT_CONNECT_TIMEOUT,
    proxy_mode: str | None = None,
    ssh_key: str | None = None,
    rm: bool = False,
    ssh_config_path: str | Path | None = None,
    update_ssh_config: bool = True,
    remote_connect: Callable[..., Awaitable[Any]] | None = None,
) -> Any:
    """Connect to a Google Colab instance, returning a RemoteConnection.

    Sets up the SSH proxy connection (using `colab ssh --proxy-mode -s <session>`
    or direct websocket tunnel) and delegates to `remote.connect(...)`.
    """
    if isinstance(instance_id_or_name, ColabInstance):
        session = str(instance_id_or_name.id)
    else:
        session = str(instance_id_or_name)

    host_alias = session if session.startswith("colab-") else f"colab-{session}"

    mode = proxy_mode or _configured.get("proxy_mode")
    colab_bin = shutil.which("colab")
    priv_dir = str(Path(__file__).resolve().parent.parent)

    if mode in ("websocket", "direct") or not colab_bin:
        parts = [
            "env",
            f"PYTHONPATH={priv_dir}",
            sys.executable,
            "-m",
            "albedo_plugins.colab",
            "tunnel",
            "-s",
            session,
        ]
        if ssh_key:
            parts.extend(["-i", ssh_key])
        proxy_cmd = " ".join(shlex.quote(p) for p in parts)
    else:
        parts = [colab_bin, "ssh", "--proxy-mode", "-s", shlex.quote(session)]
        if rm:
            parts.append("--rm")
        if ssh_key:
            parts.extend(["-i", shlex.quote(ssh_key)])
        proxy_cmd = " ".join(parts)

    if update_ssh_config:
        configure_ssh(
            session,
            proxy_cmd,
            host_alias=host_alias,
            ssh_config_path=ssh_config_path,
            identity_file=ssh_key,
        )

    connect_fn = remote_connect or _remote_connect_fn
    return await connect_fn(
        host_alias,
        remote_cwd=remote_cwd or "/content",
        python=python or "/usr/bin/python3",
        modules=modules,
        timeout=timeout,
    )


def _read_exact(sock: Any, n: int) -> bytes:
    buf = bytearray()
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            break
        buf.extend(chunk)
    return bytes(buf)


def _read_ws_frame(sock: Any) -> tuple[int, bytes] | None:
    head = _read_exact(sock, 2)
    if len(head) < 2:
        return None
    b1, b2 = head[0], head[1]
    opcode = b1 & 0x0F
    is_masked = bool(b2 & 0x80)
    length = b2 & 0x7F
    if length == 126:
        ext = _read_exact(sock, 2)
        if len(ext) < 2:
            return None
        length = struct.unpack("!H", ext)[0]
    elif length == 127:
        ext = _read_exact(sock, 8)
        if len(ext) < 8:
            return None
        length = struct.unpack("!Q", ext)[0]

    mask = _read_exact(sock, 4) if is_masked else None
    payload = _read_exact(sock, length)
    if is_masked and mask:
        unmasked = bytearray(length)
        for i in range(length):
            unmasked[i] = payload[i] ^ mask[i % 4]
        payload = bytes(unmasked)
    return opcode, payload


def _encode_ws_frame(data: bytes, opcode: int = 0x2, mask: bool = True) -> bytes:
    length = len(data)
    first_byte = 0x80 | (opcode & 0x0F)
    if length <= 125:
        header = bytearray([first_byte, (0x80 if mask else 0) | length])
    elif length <= 65535:
        header = bytearray([first_byte, (0x80 if mask else 0) | 126])
        header.extend(struct.pack("!H", length))
    else:
        header = bytearray([first_byte, (0x80 if mask else 0) | 127])
        header.extend(struct.pack("!Q", length))
    if mask:
        mask_key = os.urandom(4)
        header.extend(mask_key)
        masked = bytearray(length)
        for i in range(length):
            masked[i] = data[i] ^ mask_key[i % 4]
        return bytes(header) + bytes(masked)
    return bytes(header) + data


def _get_ssh_pubkey(key_path: str | None = None) -> str | None:
    if key_path:
        p = Path(key_path).expanduser()
        if p.is_file():
            content = p.read_text(encoding="utf-8").strip()
            if content.startswith(("ssh-ed25519", "ecdsa-sha2-", "ssh-rsa")):
                return content
            pub = Path(str(p) + ".pub")
            if pub.is_file():
                return pub.read_text(encoding="utf-8").strip()
            try:
                res = subprocess.run(
                    ["ssh-keygen", "-y", "-f", str(p)],
                    check=True,
                    capture_output=True,
                    text=True,
                )
                if res.stdout.strip():
                    return res.stdout.strip()
            except Exception:
                pass
            return content
    candidates = [
        Path.home() / ".ssh" / "id_ed25519.pub",
        Path.home() / ".ssh" / "id_ecdsa.pub",
    ]
    for candidate in candidates:
        if candidate.is_file():
            return candidate.read_text(encoding="utf-8").strip()
    return None


def run_websocket_tunnel(
    session: str,
    *,
    token: str | None = None,
    api_base: str | None = None,
    key_path: str | None = None,
) -> int:
    """Run a bidirectional stdin/stdout to Colab WebSocket SSH bridge."""
    if api_base:
        configure(api_base=api_base)
    auth_token = token or get_token()

    # Query assignment to find runtime proxy URL and token
    target_instance: ColabInstance | None = None
    try:
        insts = asyncio.run(instances(token=auth_token))
        for inst in insts:
            if inst.id == session or inst.endpoint == session or inst.name == session:
                target_instance = inst
                break
    except Exception as error:
        sys.stderr.write(
            f"colab tunnel: failed to resolve session {session}: {error}\n"
        )
        return 1

    if target_instance is None:
        sys.stderr.write(f"colab tunnel: no active instance found for {session}\n")
        return 1

    proxy_url = target_instance.url
    proxy_token = target_instance.token or auth_token
    if not proxy_url:
        sys.stderr.write(f"colab tunnel: instance {session} has no proxy URL\n")
        return 1

    parsed = urllib.parse.urlparse(proxy_url)
    host = parsed.hostname or "localhost"
    port = parsed.port or (443 if parsed.scheme == "https" else 80)
    path = f"/colab/ssh?colab-runtime-proxy-token={proxy_token}"

    ws_key = base64.b64encode(os.urandom(16)).decode("ascii")
    headers = [
        f"GET {path} HTTP/1.1",
        f"Host: {host}",
        "Upgrade: websocket",
        "Connection: Upgrade",
        f"Sec-WebSocket-Key: {ws_key}",
        "Sec-WebSocket-Version: 13",
    ]
    pubkey = _get_ssh_pubkey(key_path)
    if pubkey:
        headers.append(f"X-Colab-Ssh-Pubkey: {pubkey}")
    headers.extend(["", ""])
    handshake = "\r\n".join(headers).encode("ascii")

    raw_sock = socket.create_connection((host, port), timeout=15)
    if parsed.scheme == "https":
        ctx = ssl.create_default_context()
        sock = ctx.wrap_socket(raw_sock, server_hostname=host)
    else:
        sock = raw_sock

    sock.sendall(handshake)
    response_head = bytearray()
    while b"\r\n\r\n" not in response_head:
        chunk = sock.recv(1024)
        if not chunk:
            break
        response_head.extend(chunk)

    head_str = response_head.decode("latin1", errors="replace")
    if not head_str.startswith("HTTP/1.1 101") and not head_str.startswith(
        "HTTP/1.0 101"
    ):
        sys.stderr.write(
            f"colab tunnel: WebSocket upgrade rejected: {head_str[:200]}\n"
        )
        sock.close()
        return 1

    # Bidirectional bridge between stdin/stdout and websocket
    stdin_fd = sys.stdin.buffer.fileno()
    running = True

    def stdin_to_ws() -> None:
        nonlocal running
        try:
            while running:
                data = os.read(stdin_fd, 4096)
                if not data:
                    break
                sock.sendall(_encode_ws_frame(data, opcode=0x2, mask=True))
        except Exception:
            pass
        finally:
            running = False
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except Exception:
                pass

    bridge_thread = threading.Thread(target=stdin_to_ws, daemon=True)
    bridge_thread.start()

    try:
        while running:
            frame = _read_ws_frame(sock)
            if frame is None:
                break
            opcode, data = frame
            if opcode == 0x8:  # Close
                break
            if opcode in (0x1, 0x2):  # Text or Binary
                sys.stdout.buffer.write(data)
                sys.stdout.buffer.flush()
            elif opcode == 0x9:  # Ping
                sock.sendall(_encode_ws_frame(data, opcode=0xA, mask=True))
    except (KeyboardInterrupt, BrokenPipeError, ConnectionResetError):
        pass
    finally:
        running = False
        sock.close()

    return 0


def main(argv: list[str] | None = None) -> int:
    """CLI entrypoint for colab module (tunnel and diagnostics)."""
    parser = argparse.ArgumentParser(description="Albedo Colab plugin utilities")
    subparsers = parser.add_subparsers(dest="command")

    tunnel_parser = subparsers.add_parser(
        "tunnel", help="Run SSH WebSocket proxy bridge"
    )
    tunnel_parser.add_argument(
        "-s", "--session", required=True, help="Colab session ID or name"
    )
    tunnel_parser.add_argument("--token", help="Colab OAuth token override")
    tunnel_parser.add_argument("--api-base", help="Colab API base URL override")
    tunnel_parser.add_argument("-i", "--key", help="SSH public or private key path")

    args = parser.parse_args(argv)
    if args.command == "tunnel":
        return run_websocket_tunnel(
            args.session,
            token=args.token,
            api_base=args.api_base,
            key_path=args.key,
        )
    parser.print_help()
    return 0


class Colab:
    """Google Colab management interface."""

    instances = staticmethod(instances)
    status = staticmethod(status)
    launch = staticmethod(launch)
    request = staticmethod(request)
    stop = staticmethod(stop)
    unassign = staticmethod(unassign)
    connect = staticmethod(connect)
    configure = staticmethod(configure)
    credentials = staticmethod(read_colab_credentials)
    token = staticmethod(get_token)
    configure_ssh = staticmethod(configure_ssh)
    remove_ssh_config = staticmethod(remove_ssh_config)


colab = Colab()


def setup(api: PythonApi) -> dict[str, object]:
    """Expose the Colab plugin in the Python kernel environment."""
    global loop, host_call
    loop = api.loop
    host_call = api.host
    return {
        "colab": colab,
        "Colab": Colab,
        "ColabError": ColabError,
        "ColabInstance": ColabInstance,
        "ColabStatus": ColabStatus,
    }


if __name__ == "__main__":
    sys.exit(main())
