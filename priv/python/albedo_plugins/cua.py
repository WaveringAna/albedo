"""Native desktop GUI automation through cua-driver.

The plugin speaks MCP JSON-RPC 2.0 over a persistent `cua-driver mcp` stdio
subprocess per kernel session, so snapshot element tokens and session state stay
alive across cells and are reaped automatically when the kernel exits or calls
`await cua.close()`.
"""

from __future__ import annotations

import asyncio
import base64
from collections.abc import Callable
import contextlib
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import uuid
from typing import Any, cast

from albedo_api import PythonApi, Record, check_timeout
import albedo_trace
from albedo_plugins import hook

STARTUP_TIMEOUT = 15.0
CALL_TIMEOUT = 60.0
STDERR_TAIL = 8192
STREAM_LIMIT = 16 * 1024 * 1024  # 16 MiB per JSON-RPC line

attach_image: Callable[[bytes], str] | None = None
configured: dict[str, str | None] = {}


class CuaError(RuntimeError):
    """A cua-driver operation failed; `code` and `details` carry structured refusal facts."""

    def __init__(
        self,
        message: str,
        *,
        code: str = "cua_error",
        **details: Any,
    ) -> None:
        super().__init__(message)
        self.code = code
        self.details = details

    def to_dict(self) -> dict[str, Any]:
        return {"code": self.code, "message": str(self), **self.details}


def _record(value: Any) -> Any:
    if isinstance(value, dict):
        return Record({key: _record(item) for key, item in value.items()})
    if isinstance(value, list):
        return [_record(item) for item in value]
    return value


class Observation(Record):
    """A window or desktop snapshot record with `.render()`, `.find()`, and `.one()` helpers."""

    def render(self, *, max_chars: int = 8000) -> str:
        return render(self, max_chars=max_chars)

    def find(
        self,
        *,
        role: str | None = None,
        label: str | None = None,
        name: str | None = None,
        text: str | None = None,
        value: str | None = None,
        enabled: bool | None = None,
        selected: bool | None = None,
        exact: bool = True,
        **fields: Any,
    ) -> list[Record]:
        return find(
            self,
            role=role,
            label=label,
            name=name,
            text=text,
            value=value,
            enabled=enabled,
            selected=selected,
            exact=exact,
            **fields,
        )

    def one(self, **query: Any) -> Record:
        return one(self, **query)


class Window(Record):
    """A desktop window handle (`pid` + `window_id`) with bound observation and action methods."""

    @property
    def pid(self) -> int:
        return int(self["pid"])

    @property
    def window_id(self) -> int:
        return int(self["window_id"])

    async def observe(
        self,
        *,
        query: str | None = None,
        include_screenshot: bool = True,
        include_accessibility_tree: bool = True,
        tree_format: str = "elements",
        max_elements: int | None = None,
        max_depth: int | None = None,
        max_image_dimension: int | None = None,
        since: str | None = None,
        screenshot_out_file: str | os.PathLike[str] | None = None,
        timeout: float = CALL_TIMEOUT,
    ) -> Observation:
        return await cua.observe(
            self,
            query=query,
            include_screenshot=include_screenshot,
            include_accessibility_tree=include_accessibility_tree,
            tree_format=tree_format,
            max_elements=max_elements,
            max_depth=max_depth,
            max_image_dimension=max_image_dimension,
            since=since,
            screenshot_out_file=screenshot_out_file,
            timeout=timeout,
        )

    async def zoom(
        self,
        x1: float,
        y1: float,
        x2: float,
        y2: float,
        *,
        timeout: float = CALL_TIMEOUT,
    ) -> Record:
        return await cua.zoom(self, x1, y1, x2, y2, timeout=timeout)

    async def focus(self, *, timeout: float = CALL_TIMEOUT) -> Record:
        return await cua.focus(self, timeout=timeout)

    async def kill(self, *, timeout: float = CALL_TIMEOUT) -> Record:
        return await cua.kill(self, timeout=timeout)

    async def click(
        self,
        element_or_x: Any = None,
        y: float | None = None,
        *,
        element_token: str | None = None,
        button: str | None = None,
        count: int | None = None,
        delivery_mode: str | None = None,
        timeout: float = CALL_TIMEOUT,
        **options: Any,
    ) -> Record:
        return await cua.click(
            self,
            element_or_x,
            y,
            element_token=element_token,
            button=button,
            count=count,
            delivery_mode=delivery_mode,
            timeout=timeout,
            **options,
        )

    async def double_click(
        self,
        element_or_x: Any = None,
        y: float | None = None,
        *,
        element_token: str | None = None,
        delivery_mode: str | None = None,
        timeout: float = CALL_TIMEOUT,
        **options: Any,
    ) -> Record:
        return await cua.double_click(
            self,
            element_or_x,
            y,
            element_token=element_token,
            delivery_mode=delivery_mode,
            timeout=timeout,
            **options,
        )

    async def right_click(
        self,
        element_or_x: Any = None,
        y: float | None = None,
        *,
        element_token: str | None = None,
        delivery_mode: str | None = None,
        timeout: float = CALL_TIMEOUT,
        **options: Any,
    ) -> Record:
        return await cua.right_click(
            self,
            element_or_x,
            y,
            element_token=element_token,
            delivery_mode=delivery_mode,
            timeout=timeout,
            **options,
        )

    async def move(
        self,
        x: float,
        y: float,
        *,
        timeout: float = CALL_TIMEOUT,
        **options: Any,
    ) -> Record:
        return await cua.move(self, x, y, timeout=timeout, **options)

    async def drag(
        self,
        from_x: float,
        from_y: float,
        to_x: float,
        to_y: float,
        *,
        delivery_mode: str | None = None,
        duration_ms: int | None = None,
        steps: int | None = None,
        button: str | None = None,
        timeout: float = CALL_TIMEOUT,
        **options: Any,
    ) -> Record:
        return await cua.drag(
            self,
            from_x,
            from_y,
            to_x,
            to_y,
            delivery_mode=delivery_mode,
            duration_ms=duration_ms,
            steps=steps,
            button=button,
            timeout=timeout,
            **options,
        )

    async def scroll(
        self,
        x: float,
        y: float,
        direction: str = "down",
        *,
        amount: int | None = None,
        by: str | None = None,
        delivery_mode: str | None = None,
        timeout: float = CALL_TIMEOUT,
        **options: Any,
    ) -> Record:
        return await cua.scroll(
            self,
            x,
            y,
            direction,
            amount=amount,
            by=by,
            delivery_mode=delivery_mode,
            timeout=timeout,
            **options,
        )

    async def type_text(
        self,
        text_or_element: Any,
        text: str | None = None,
        *,
        element: Any = None,
        element_token: str | None = None,
        x: float | None = None,
        y: float | None = None,
        delivery_mode: str | None = None,
        timeout: float = CALL_TIMEOUT,
        **options: Any,
    ) -> Record:
        if text is not None and element is None and element_token is None:
            actual_text = text
            actual_element = text_or_element
        else:
            actual_text = str(text_or_element)
            actual_element = element
        return await cua.type_text(
            self,
            actual_text,
            element=actual_element,
            element_token=element_token,
            x=x,
            y=y,
            delivery_mode=delivery_mode,
            timeout=timeout,
            **options,
        )

    async def set_value(
        self,
        value_or_element: Any,
        value: str | None = None,
        *,
        element: Any = None,
        element_token: str | None = None,
        timeout: float = CALL_TIMEOUT,
        **options: Any,
    ) -> Record:
        if value is not None and element is None and element_token is None:
            actual_value = value
            actual_element = value_or_element
        else:
            actual_value = str(value_or_element)
            actual_element = element
        return await cua.set_value(
            self,
            actual_value,
            element=actual_element,
            element_token=element_token,
            timeout=timeout,
            **options,
        )

    async def press_key(
        self,
        key: str,
        *,
        modifiers: list[str] | None = None,
        delivery_mode: str | None = None,
        timeout: float = CALL_TIMEOUT,
        **options: Any,
    ) -> Record:
        return await cua.press_key(
            self,
            key,
            modifiers=modifiers,
            delivery_mode=delivery_mode,
            timeout=timeout,
            **options,
        )

    async def hotkey(
        self,
        *keys: str | list[str] | tuple[str, ...],
        delivery_mode: str | None = None,
        timeout: float = CALL_TIMEOUT,
        **options: Any,
    ) -> Record:
        return await cua.hotkey(
            self,
            *keys,
            delivery_mode=delivery_mode,
            timeout=timeout,
            **options,
        )

    async def menu(
        self,
        *path: str | list[str] | tuple[str, ...],
        timeout: float = CALL_TIMEOUT,
    ) -> Record:
        return await cua.menu(self, *path, timeout=timeout)

    async def frame(
        self,
        x: float,
        y: float,
        width: float,
        height: float,
        *,
        timeout: float = CALL_TIMEOUT,
    ) -> Record:
        return await cua.frame(self, x, y, width, height, timeout=timeout)

    async def verify(
        self,
        expect: list[dict[str, Any]] | dict[str, Any],
        *,
        timeout_ms: int | None = None,
        stable_samples: int | None = None,
        include_screenshot: bool = False,
        timeout: float = CALL_TIMEOUT,
    ) -> Record:
        return await cua.verify(
            self,
            expect,
            timeout_ms=timeout_ms,
            stable_samples=stable_samples,
            include_screenshot=include_screenshot,
            timeout=timeout,
        )


def _as_window(raw: dict[str, Any]) -> Window:
    rec = _record(raw)
    return Window(rec if isinstance(rec, dict) else {})


def _as_observation(raw: dict[str, Any]) -> Observation:
    rec = _record(raw)
    return Observation(rec if isinstance(rec, dict) else {})


def _settings() -> dict[str, str]:
    """The `cua` section of extensions.json; malformed settings raise CuaError."""
    home = os.environ.get("ALBEDO_HOME") or os.path.expanduser("~/.albedo")
    try:
        with (
            albedo_trace.unobserved(),
            open(os.path.join(home, "extensions.json"), "rb") as handle,
        ):
            sections = json.load(handle)
    except FileNotFoundError:
        return {}
    except Exception as error:
        raise CuaError(
            f"could not read extensions.json: {error}",
            code="invalid_settings",
        ) from error
    if not isinstance(sections, dict):
        raise CuaError(
            "extensions.json must hold an object",
            code="invalid_settings",
        )
    section = sections.get("cua")
    if section is None:
        return {}
    if not isinstance(section, dict):
        raise CuaError(
            "extensions.json cua section must be an object",
            code="invalid_settings",
        )
    result: dict[str, str] = {}
    for key in ("executable", "socket"):
        if key in section:
            if not isinstance(section[key], str) or not section[key].strip():
                raise CuaError(
                    f"extensions.json cua.{key} must be a non-empty string",
                    code="invalid_settings",
                )
            result[key] = section[key].strip()
    return result


def _candidate_paths() -> list[Path]:
    home = Path.home()
    candidates = [
        home / ".local" / "bin" / "cua-driver",
        Path("/Applications/CuaDriver.app/Contents/MacOS/cua-driver"),
        home / "Applications" / "CuaDriver.app/Contents/MacOS/cua-driver",
    ]
    local_app_data = os.environ.get("LOCALAPPDATA")
    if local_app_data:
        candidates.append(
            Path(local_app_data)
            / "Programs"
            / "Cua"
            / "cua-driver"
            / "bin"
            / "cua-driver.exe"
        )
    return candidates


def _macos_needs_direct(socket: str | None) -> bool:
    """When macOS has neither CuaDriver.app nor a running daemon socket, a standalone
    cua-driver binary must run with `mcp --direct` instead of `open -a CuaDriver`."""
    if sys.platform != "darwin" or socket is not None:
        return False
    home = Path.home()
    for bundle in (
        Path("/Applications/CuaDriver.app"),
        home / "Applications" / "CuaDriver.app",
    ):
        if bundle.exists():
            return False
    for sock in (
        home / "Library" / "Caches" / "cua-driver" / "cua-driver.sock",
        home / "Library" / "Caches" / "cua-driver-local" / "cua-driver.sock",
    ):
        if sock.exists():
            return False
    return True


def _resolve_config(
    executable: str | os.PathLike[str] | None = None,
    socket: str | os.PathLike[str] | None = None,
) -> tuple[str, str | None]:
    settings = _settings()
    raw_exec = (
        os.fspath(executable)
        if executable is not None
        else configured.get("executable")
        or os.environ.get("ALBEDO_CUA_DRIVER")
        or os.environ.get("CUA_DRIVER_PATH")
        or settings.get("executable")
    )
    raw_socket = (
        os.fspath(socket)
        if socket is not None
        else configured.get("socket")
        or os.environ.get("ALBEDO_CUA_SOCKET")
        or settings.get("socket")
    )
    resolved_socket = (
        os.path.expanduser(raw_socket.strip())
        if raw_socket and raw_socket.strip()
        else None
    )
    if raw_exec and raw_exec.strip():
        expanded = os.path.expanduser(raw_exec.strip())
        found = shutil.which(expanded)
        if not found and os.path.isfile(expanded) and os.access(expanded, os.X_OK):
            found = str(Path(expanded).resolve())
        if found:
            return found, resolved_socket
        raise CuaError(
            f"cua-driver executable was not found or is not executable: {expanded}",
            code="executable_not_found",
            executable=expanded,
            recovery=(
                'Pass cua.configure(executable="/path/to/cua-driver"), set '
                "$ALBEDO_CUA_DRIVER, or install cua-driver onto PATH."
            ),
        )
    found = shutil.which("cua-driver")
    if found:
        return found, resolved_socket
    for path in _candidate_paths():
        if path.is_file() and os.access(path, os.X_OK):
            return str(path), resolved_socket
    raise CuaError(
        "cua-driver was not found on PATH or in standard install locations.",
        code="executable_not_found",
        recovery=(
            'Install cua-driver, set $ALBEDO_CUA_DRIVER or the "cua" section '
            'of extensions.json, or call cua.configure(executable="/path/to/cua-driver").'
        ),
    )


def _target_spec(
    target: Any,
    window_id: int | None = None,
) -> dict[str, Any]:
    """Normalize a target into cua-driver's tagged `{kind, ...}` union."""
    if isinstance(target, str):
        if target == "desktop" or target == "primary":
            if window_id is not None:
                raise ValueError("desktop target cannot be combined with window_id")
            return {"kind": "desktop", "display_id": "primary"}
        if target.startswith("desktop:"):
            if window_id is not None:
                raise ValueError("desktop target cannot be combined with window_id")
            display = target.partition(":")[2].strip() or "primary"
            return {"kind": "desktop", "display_id": display}
        raise ValueError(
            f"invalid target string {target!r}; use 'desktop', a (pid, window_id) pair, or a window/snapshot record"
        )
    if isinstance(target, (tuple, list)) and len(target) == 2:
        if window_id is not None:
            raise ValueError("target tuple already includes window_id")
        pid_val, wid_val = int(target[0]), int(target[1])
        if pid_val <= 0 or wid_val <= 0:
            raise ValueError("window target requires positive pid and window_id")
        return {"kind": "window", "pid": pid_val, "window_id": wid_val}
    if isinstance(target, dict):
        if target.get("kind") == "desktop" or target.get("scope") == "desktop":
            if window_id is not None:
                raise ValueError("desktop target cannot be combined with window_id")
            return {
                "kind": "desktop",
                "display_id": str(target.get("display_id") or "primary"),
            }
        pid = target.get("pid")
        wid = window_id if window_id is not None else target.get("window_id")
        if (
            wid is None
            and isinstance(target.get("windows"), list)
            and len(target["windows"]) == 1
        ):
            first = target["windows"][0]
            if isinstance(first, dict):
                wid = first.get("window_id")
        if isinstance(pid, int) and pid > 0 and isinstance(wid, int) and wid > 0:
            return {"kind": "window", "pid": int(pid), "window_id": int(wid)}
        raise ValueError(
            "target dict must carry positive pid and window_id (or kind='desktop')"
        )
    if isinstance(target, int) and not isinstance(target, bool):
        if (
            window_id is None
            or isinstance(window_id, bool)
            or int(window_id) <= 0
            or target <= 0
        ):
            raise ValueError(
                "an integer pid target requires a positive window_id argument"
            )
        return {"kind": "window", "pid": int(target), "window_id": int(window_id)}
    raise TypeError(
        f"unsupported target {target!r}; pass a window/observation record, (pid, window_id), or 'desktop'"
    )


def _window_ids(target: Any, window_id: int | None = None) -> tuple[int, int]:
    """Extract exact `(pid, window_id)` for window-only tools."""
    spec = _target_spec(target, window_id)
    if spec.get("kind") != "window":
        raise ValueError(
            "this operation requires a window target (pid and window_id), not desktop"
        )
    return int(spec["pid"]), int(spec["window_id"])


def _pid_and_optional_wid(
    target: Any, window_id: int | None = None
) -> tuple[int, int | None]:
    """Extract `pid` and optional `window_id` from a pid, window, app, or snapshot."""
    if isinstance(target, (tuple, list)) and len(target) == 2:
        if window_id is not None:
            raise ValueError("target tuple already includes window_id")
        pid_val, wid_val = int(target[0]), int(target[1])
        if pid_val <= 0 or wid_val <= 0:
            raise ValueError("window target requires positive pid and window_id")
        return pid_val, wid_val
    if isinstance(target, dict):
        pid = target.get("pid")
        if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0:
            raise ValueError("target dict must carry a positive pid")
        wid = window_id if window_id is not None else target.get("window_id")
        if (
            wid is None
            and isinstance(target.get("windows"), list)
            and len(target["windows"]) == 1
        ):
            first = target["windows"][0]
            if isinstance(first, dict):
                wid = first.get("window_id")
        if wid is not None:
            if isinstance(wid, bool) or int(wid) <= 0:
                raise ValueError("window_id must be a positive integer")
            return int(pid), int(wid)
        return int(pid), None
    if isinstance(target, int) and not isinstance(target, bool) and target > 0:
        if window_id is not None:
            if isinstance(window_id, bool) or int(window_id) <= 0:
                raise ValueError("window_id must be a positive integer")
            return int(target), int(window_id)
        return int(target), None
    raise ValueError("target must be a positive pid or a record with a positive pid")


def _element_token(value: Any) -> str | None:
    if isinstance(value, str) and value.strip():
        return value.strip()
    if isinstance(value, dict):
        token = value.get("element_token") or value.get("ref")
        if isinstance(token, str) and token.strip():
            return token.strip()
    return None


def _default_delivery(target_spec: dict[str, Any], delivery_mode: str | None) -> str:
    if delivery_mode is not None:
        if delivery_mode not in ("background", "foreground"):
            raise ValueError("delivery_mode must be 'background' or 'foreground'")
        return delivery_mode
    return "foreground" if target_spec.get("kind") == "desktop" else "background"


def _extract_error(tool: str, result: dict[str, Any]) -> CuaError:
    structured = result.get("structuredContent")
    details: dict[str, Any] = dict(structured) if isinstance(structured, dict) else {}
    refusal = details.get("refusal")
    code = "tool_error"
    message = ""
    if isinstance(refusal, dict):
        if isinstance(refusal.get("code"), str) and refusal["code"]:
            code = refusal["code"]
        if isinstance(refusal.get("message"), str) and refusal["message"]:
            message = refusal["message"]
    if (
        code == "tool_error"
        and isinstance(details.get("code"), str)
        and details["code"]
    ):
        code = details["code"]
    texts: list[str] = []
    for item in result.get("content") or []:
        if isinstance(item, dict) and item.get("type") == "text":
            text = item.get("text")
            if isinstance(text, str) and text.strip():
                texts.append(text.strip())
    if not message:
        message = "\n".join(texts) if texts else f"cua-driver {tool} failed"
    details.pop("code", None)
    details.pop("message", None)
    return CuaError(message, code=code, tool=tool, **details)


def _attach_from_result(
    result: dict[str, Any], out_file: Path | None = None
) -> bytes | None:
    """Read PNG/JPEG bytes from `out_file` or inline MCP image content and attach to the cell."""
    raw: bytes | None = None
    with albedo_trace.unobserved():
        if out_file is not None and out_file.is_file():
            with contextlib.suppress(OSError):
                data = out_file.read_bytes()
                if data:
                    raw = data
    if raw is None:
        for item in result.get("content") or []:
            if isinstance(item, dict) and item.get("type") == "image":
                b64 = item.get("data")
                if isinstance(b64, str) and b64:
                    with contextlib.suppress(Exception):
                        raw = base64.b64decode(b64)
                        break
    if raw is None:
        structured = result.get("structuredContent")
        if isinstance(structured, dict):
            b64 = structured.get("screenshot_png_b64")
            if isinstance(b64, str) and b64:
                with contextlib.suppress(Exception):
                    raw = base64.b64decode(b64)
    if raw and attach_image is not None:
        with contextlib.suppress(Exception):
            attach_image(raw)
    return raw


class _DriverClient:
    """One persistent `cua-driver mcp` stdio session owned by this kernel."""

    def __init__(self) -> None:
        self._process: asyncio.subprocess.Process | None = None
        self._executable: str | None = None
        self._socket: str | None = None
        self._lock = asyncio.Lock()
        self._next_id = 0
        self._stderr_tail = bytearray()
        self._stderr_task: asyncio.Task[None] | None = None
        self.session_name = f"albedo-{uuid.uuid4().hex[:8]}"

    def _running(self) -> bool:
        return self._process is not None and self._process.returncode is None

    async def _drain_stderr(self, stream: asyncio.StreamReader) -> None:
        try:
            while chunk := await stream.read(4096):
                self._stderr_tail.extend(chunk)
                del self._stderr_tail[:-STDERR_TAIL]
        except Exception:
            pass

    def _stderr_text(self) -> str:
        return bytes(self._stderr_tail).decode("utf-8", errors="replace").strip()

    async def _ensure_started(self, timeout: float) -> None:
        executable, socket = _resolve_config()
        if (
            self._running()
            and self._executable == executable
            and self._socket == socket
        ):
            return
        await self._stop_process()
        self.session_name = f"albedo-{uuid.uuid4().hex[:8]}"
        argv = [executable, "mcp"]
        if socket is not None:
            argv.extend(["--socket", socket])
        elif _macos_needs_direct(socket):
            argv.append("--direct")
        env = os.environ.copy()
        env.setdefault("DO_NOT_TRACK", "1")
        env.setdefault("CUA_TELEMETRY", "0")
        self._stderr_tail.clear()
        try:
            with albedo_trace.unobserved():
                process = await asyncio.create_subprocess_exec(
                    *argv,
                    stdin=asyncio.subprocess.PIPE,
                    stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.PIPE,
                    env=env,
                    limit=STREAM_LIMIT,
                )
        except OSError as error:
            raise CuaError(
                f"failed to start cua-driver ({executable}): {error}",
                code="launch_failed",
                executable=executable,
            ) from error
        self._process = process
        self._executable = executable
        self._socket = socket
        if process.stderr is not None:
            with albedo_trace.unobserved():
                self._stderr_task = asyncio.create_task(
                    self._drain_stderr(process.stderr)
                )
        try:
            await self._rpc(
                "initialize",
                {
                    "protocolVersion": "2025-06-18",
                    "capabilities": {},
                    "clientInfo": {"name": "albedo", "version": "1.0.0"},
                },
                timeout=min(timeout, STARTUP_TIMEOUT),
            )
        except Exception:
            await self._stop_process()
            raise

    async def _rpc(
        self, method: str, params: dict[str, Any], *, timeout: float
    ) -> dict[str, Any]:
        assert self._process is not None
        assert self._process.stdin is not None
        assert self._process.stdout is not None
        self._next_id += 1
        request_id = self._next_id
        line = (
            json.dumps(
                {
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "method": method,
                    "params": params,
                },
                separators=(",", ":"),
            ).encode("utf-8")
            + b"\n"
        )
        try:
            self._process.stdin.write(line)
            await asyncio.wait_for(self._process.stdin.drain(), timeout=timeout)
            while True:
                raw_line = await asyncio.wait_for(
                    self._process.stdout.readline(), timeout=timeout
                )
                if not raw_line:
                    stderr = self._stderr_text()
                    raise CuaError(
                        "cua-driver exited unexpectedly"
                        + (f": {stderr}" if stderr else ""),
                        code="connection_lost",
                        executable=self._executable,
                        stderr_tail=stderr,
                    )
                text = raw_line.decode("utf-8", errors="replace").strip()
                if not text:
                    continue
                try:
                    message = json.loads(text)
                except json.JSONDecodeError as error:
                    raise CuaError(
                        f"cua-driver returned invalid JSON: {text[:200]}",
                        code="protocol_error",
                    ) from error
                if not isinstance(message, dict):
                    continue
                if message.get("id") != request_id:
                    continue
                if "error" in message and message["error"] is not None:
                    err = message["error"]
                    msg = (
                        err.get("message", str(err))
                        if isinstance(err, dict)
                        else str(err)
                    )
                    raise CuaError(
                        str(msg),
                        code="rpc_error",
                        rpc_code=err.get("code") if isinstance(err, dict) else None,
                    )
                result = message.get("result")
                return result if isinstance(result, dict) else {"value": result}
        except asyncio.TimeoutError:
            await self._stop_process()
            raise CuaError(
                f"cua-driver {method} timed out after {timeout:g}s",
                code="timeout",
            ) from None

    async def request(
        self, method: str, params: dict[str, Any], *, timeout: float = CALL_TIMEOUT
    ) -> dict[str, Any]:
        check_timeout(timeout)
        async with self._lock:
            await self._ensure_started(timeout)
            return await self._rpc(method, params, timeout=timeout)

    async def call_tool(
        self,
        tool: str,
        arguments: dict[str, Any] | None = None,
        *,
        timeout: float = CALL_TIMEOUT,
        raw_envelope: bool = False,
    ) -> tuple[dict[str, Any], Record]:
        args = dict(arguments or {})
        albedo_trace.note("cua", tool, json.dumps(args, default=str)[:512])

        async def call(given: dict[str, object]) -> dict[str, Any]:
            return await self.request(
                "tools/call", {"name": tool, "arguments": given}, timeout=timeout
            )

        envelope = await hook.around("cua." + tool, args, call)
        if envelope.get("isError") is True:
            raise _extract_error(tool, envelope)
        structured = envelope.get("structuredContent")
        if isinstance(structured, dict):
            payload = dict(structured)
            payload.pop("screenshot_png_b64", None)
            record = cast(Record, _record(payload))
        else:
            texts = [
                item.get("text", "")
                for item in (envelope.get("content") or [])
                if isinstance(item, dict) and item.get("type") == "text"
            ]
            text = "\n".join(t for t in texts if t)
            if text:
                try:
                    parsed = json.loads(text)
                    record = (
                        cast(Record, _record(parsed))
                        if isinstance(parsed, dict)
                        else Record({"text": text, "value": _record(parsed)})
                    )
                except Exception:
                    record = Record({"text": text})
            else:
                record = Record({})
        if raw_envelope:
            return envelope, record
        return envelope, record

    async def _stop_process(self) -> None:
        process, self._process = self._process, None
        stderr_task, self._stderr_task = self._stderr_task, None
        if process is not None:
            if process.stdin is not None:
                with contextlib.suppress(Exception):
                    process.stdin.close()
            if process.returncode is None:
                with contextlib.suppress(Exception):
                    process.terminate()
                try:
                    await asyncio.wait_for(process.wait(), timeout=2.0)
                except asyncio.TimeoutError:
                    with contextlib.suppress(Exception):
                        process.kill()
                    with contextlib.suppress(Exception):
                        await asyncio.wait_for(process.wait(), timeout=1.0)
        if stderr_task is not None:
            stderr_task.cancel()
            with contextlib.suppress(Exception):
                await stderr_task

    async def close(self) -> None:
        async with self._lock:
            if self._running():
                with contextlib.suppress(Exception):
                    await self._rpc(
                        "tools/call",
                        {
                            "name": "end_session",
                            "arguments": {"session": self.session_name},
                        },
                        timeout=2.0,
                    )
            await self._stop_process()


_CLIENT = _DriverClient()


def find(
    observation: dict[str, Any],
    *,
    role: str | None = None,
    label: str | None = None,
    name: str | None = None,
    text: str | None = None,
    value: str | None = None,
    enabled: bool | None = None,
    selected: bool | None = None,
    exact: bool = True,
    **fields: Any,
) -> list[Record]:
    """Filter `observation.elements` by role, label/name, text substring, value, or state."""
    elements = observation.get("elements")
    if not isinstance(elements, list):
        raise ValueError(
            "observation has no elements list; call cua.observe(window) first"
        )
    wanted_label = label if label is not None else name
    matches: list[Record] = []
    for raw in elements:
        if not isinstance(raw, dict):
            continue
        node = raw if isinstance(raw, Record) else cast(Record, _record(raw))
        if role is not None and node.get("role") != role:
            continue
        node_label = str(node.get("label") or "")
        node_value = str(node.get("value") or "")
        if wanted_label is not None:
            if exact and node_label != wanted_label:
                continue
            if not exact and wanted_label.lower() not in node_label.lower():
                continue
        if value is not None:
            if exact and node_value != value:
                continue
            if not exact and value.lower() not in node_value.lower():
                continue
        if text is not None:
            needle = text.lower()
            if needle not in node_label.lower() and needle not in node_value.lower():
                continue
        if enabled is not None and node.get("enabled") != enabled:
            continue
        if selected is not None and node.get("selected") != selected:
            continue
        if any(node.get(k) != v for k, v in fields.items()):
            continue
        matches.append(node)
    return matches


def one(observation: dict[str, Any], **query: Any) -> Record:
    """Return the single matching element from `observation`, or raise CuaError."""
    matches = find(observation, **query)
    if len(matches) != 1:
        raise CuaError(
            f"expected 1 matching element, found {len(matches)}",
            code="selection_error",
            query=query,
            matches=[
                {
                    "element_token": item.get("element_token"),
                    "role": item.get("role"),
                    "label": item.get("label"),
                    "value": item.get("value"),
                }
                for item in matches[:10]
            ],
        )
    return matches[0]


def render(observation: dict[str, Any], *, max_chars: int = 8000) -> str:
    """Format a window or desktop observation as a bounded, human-readable tree."""
    if max_chars < 128:
        raise ValueError("max_chars must be at least 128")
    header_parts = []
    if observation.get("snapshot_id"):
        header_parts.append(f"Snapshot {observation['snapshot_id']}")
    if observation.get("app_name"):
        header_parts.append(str(observation["app_name"]))
    if observation.get("window_title"):
        header_parts.append(
            json.dumps(str(observation["window_title"]), ensure_ascii=False)
        )
    if observation.get("pid") and observation.get("window_id"):
        header_parts.append(
            f"pid={observation['pid']} window_id={observation['window_id']}"
        )
    elif observation.get("screenshot_width") and observation.get("screenshot_height"):
        header_parts.append(
            f"{observation['screenshot_width']}x{observation['screenshot_height']}"
        )
    lines = [" | ".join(header_parts) if header_parts else "Observation"]
    if observation.get("degraded"):
        lines.append(f"DEGRADED: {observation.get('degraded_reason') or 'unknown'}")
    if observation.get("truncated"):
        lines.append(
            f"TRUNCATED: {observation.get('truncation_hint') or observation.get('truncation_reason') or 'true'}"
        )
    for key in ("dialogs", "popups"):
        items = observation.get(key)
        if isinstance(items, list) and items:
            lines.append(f"{key.upper()}: {json.dumps(items, ensure_ascii=False)}")
    elements = observation.get("elements")
    if isinstance(elements, list) and elements:
        for item in elements:
            if not isinstance(item, dict):
                continue
            depth = int(item.get("depth") or 0)
            token = item.get("element_token") or "-"
            role = item.get("role") or "element"
            label = item.get("label")
            line = f"{'  ' * min(depth, 6)}[{token}] {role}"
            if label is not None and label != "":
                line += f" {json.dumps(str(label), ensure_ascii=False)}"
            for attr in ("value", "enabled", "selected"):
                if item.get(attr) is not None and item.get(attr) != "":
                    line += f" {attr}={json.dumps(item[attr], ensure_ascii=False)}"
            frame = item.get("screenshot_frame") or item.get("frame")
            if isinstance(frame, dict) and {"x", "y", "w", "h"} <= set(frame):
                line += (
                    f" @({frame['x']:g},{frame['y']:g} {frame['w']:g}x{frame['h']:g})"
                )
            lines.append(line)
    elif (
        isinstance(observation.get("tree_markdown"), str)
        and observation["tree_markdown"].strip()
    ):
        lines.append(observation["tree_markdown"].strip())
    text = "\n".join(lines)
    if len(text) <= max_chars:
        return text
    suffix = "\n[RENDER TRUNCATED; structured observation is unchanged]"
    return text[: max_chars - len(suffix)] + suffix


class Cua:
    """Native desktop GUI control backed by `cua-driver`."""

    def configure(
        self,
        *,
        executable: str | os.PathLike[str] | None = None,
        socket: str | os.PathLike[str] | None = None,
    ) -> Record:
        """Set or validate the `cua-driver` executable and optional daemon socket."""
        resolved_exec, resolved_socket = _resolve_config(
            executable=executable, socket=socket
        )
        if executable is not None:
            configured["executable"] = resolved_exec
        if socket is not None:
            configured["socket"] = resolved_socket
        return Record({"executable": resolved_exec, "socket": resolved_socket})

    async def tools(self, *, timeout: float = CALL_TIMEOUT) -> list[Record]:
        """List the tools advertised by the running `cua-driver` MCP server."""
        result = await _CLIENT.request("tools/list", {}, timeout=timeout)
        tools = result.get("tools")
        if not isinstance(tools, list):
            return []
        return [
            Record(
                {
                    "name": item.get("name", ""),
                    "description": item.get("description", ""),
                    "inputSchema": _record(item.get("inputSchema", {})),
                }
            )
            for item in tools
            if isinstance(item, dict)
        ]

    async def call(
        self,
        tool: str,
        arguments: dict[str, Any] | None = None,
        *,
        timeout: float = CALL_TIMEOUT,
        **kwargs: Any,
    ) -> Record:
        """Call any `cua-driver` tool by name; keyword arguments merge into `arguments`."""
        merged = {**(arguments or {}), **kwargs}
        if "session" not in merged and tool not in (
            "list_apps",
            "list_windows",
            "list_sessions",
        ):
            merged["session"] = _CLIENT.session_name
        envelope, record = await _CLIENT.call_tool(
            tool, merged, timeout=timeout, raw_envelope=True
        )
        _attach_from_result(envelope)
        return record

    async def apps(self, *, timeout: float = CALL_TIMEOUT) -> list[Record]:
        """List running and launchable desktop applications (`list_apps`)."""
        _, result = await _CLIENT.call_tool("list_apps", {}, timeout=timeout)
        items = result.get("apps")
        return list(items) if isinstance(items, list) else []

    async def windows(
        self,
        pid: int | dict[str, Any] | None = None,
        *,
        on_screen_only: bool | None = None,
        timeout: float = CALL_TIMEOUT,
    ) -> list[Window]:
        """List desktop windows as bound `Window` handles, optionally filtered to one `pid`."""
        args: dict[str, Any] = {}
        if isinstance(pid, dict):
            if "pid" in pid and pid["pid"] is not None:
                args["pid"] = int(pid["pid"])
        elif pid is not None:
            args["pid"] = int(pid)
        if on_screen_only is not None:
            args["on_screen_only"] = bool(on_screen_only)
        _, result = await _CLIENT.call_tool("list_windows", args, timeout=timeout)
        items = result.get("windows")
        if not isinstance(items, list):
            return []
        return [_as_window(item) for item in items if isinstance(item, dict)]

    async def window(
        self,
        target: Any = None,
        window_id: int | None = None,
        *,
        app: str | None = None,
        title: str | None = None,
        pid: int | None = None,
        on_screen_only: bool | None = None,
        exact: bool = False,
        timeout: float = CALL_TIMEOUT,
    ) -> Window:
        """Return a bound `Window` handle from a record, `(pid, window_id)`, or a window search."""
        if (
            target is not None
            and not isinstance(target, str)
            and title is None
            and app is None
            and pid is None
        ):
            try:
                p, w = _window_ids(target, window_id)
                base = dict(target) if isinstance(target, dict) else {}
                base["pid"] = p
                base["window_id"] = w
                return _as_window(base)
            except (ValueError, TypeError):
                if isinstance(target, dict) and isinstance(target.get("pid"), int):
                    pid = int(target["pid"])
                elif isinstance(target, int) and not isinstance(target, bool):
                    pid = int(target)
                else:
                    raise
        query_app = (
            app if app is not None else (target if isinstance(target, str) else None)
        )
        wins = await self.windows(pid, on_screen_only=on_screen_only, timeout=timeout)
        matches: list[Window] = []
        for win in wins:
            if window_id is not None and win.get("window_id") != int(window_id):
                continue
            win_app = str(win.get("app_name") or "")
            win_title = str(win.get("title") or "")
            if query_app is not None:
                if exact and win_app != query_app and win_title != query_app:
                    continue
                if (
                    not exact
                    and query_app.lower() not in win_app.lower()
                    and query_app.lower() not in win_title.lower()
                ):
                    continue
            if title is not None:
                if exact and win_title != title:
                    continue
                if not exact and title.lower() not in win_title.lower():
                    continue
            matches.append(win)
        if not matches:
            raise CuaError(
                "no matching window found",
                code="window_not_found",
                app=query_app,
                title=title,
                pid=pid,
                window_id=window_id,
            )
        return matches[0]

    async def launch(
        self,
        name_or_bundle_id: str | None = None,
        *,
        bundle_id: str | None = None,
        name: str | None = None,
        launch_path: str | None = None,
        urls: list[str] | None = None,
        creates_new_application_instance: bool | None = None,
        additional_arguments: list[str] | None = None,
        timeout: float = CALL_TIMEOUT,
        **options: Any,
    ) -> Record:
        """Launch an application in the background without stealing focus (`launch_app`)."""
        args: dict[str, Any] = dict(options)
        if name_or_bundle_id is not None:
            if (
                "." in name_or_bundle_id
                and " " not in name_or_bundle_id
                and not name_or_bundle_id.startswith("/")
                and not name_or_bundle_id.lower().endswith(".exe")
            ):
                args.setdefault("bundle_id", name_or_bundle_id)
            else:
                args.setdefault("name", name_or_bundle_id)
        if bundle_id is not None:
            args["bundle_id"] = bundle_id
        if name is not None:
            args["name"] = name
        if launch_path is not None:
            args["launch_path"] = launch_path
        if urls is not None:
            args["urls"] = list(urls)
        if creates_new_application_instance is not None:
            args["creates_new_application_instance"] = bool(
                creates_new_application_instance
            )
        if additional_arguments is not None:
            args["additional_arguments"] = list(additional_arguments)
        _, result = await _CLIENT.call_tool("launch_app", args, timeout=timeout)
        if (
            isinstance(result.get("pid"), int)
            and isinstance(result.get("windows"), list)
            and len(result["windows"]) == 1
            and isinstance(result["windows"][0], dict)
            and isinstance(result["windows"][0].get("window_id"), int)
        ):
            enriched = dict(result)
            enriched.setdefault("window_id", int(result["windows"][0]["window_id"]))
            return _as_window(enriched)
        return result

    async def observe(
        self,
        window_or_pid: Any,
        window_id: int | None = None,
        *,
        query: str | None = None,
        include_screenshot: bool = True,
        include_accessibility_tree: bool = True,
        tree_format: str = "elements",
        max_elements: int | None = None,
        max_depth: int | None = None,
        max_image_dimension: int | None = None,
        since: str | None = None,
        screenshot_out_file: str | os.PathLike[str] | None = None,
        timeout: float = CALL_TIMEOUT,
    ) -> Observation:
        """Snapshot one window (`get_window_state`) and attach its screenshot to the cell."""
        pid, wid = _window_ids(window_or_pid, window_id)
        args: dict[str, Any] = {
            "pid": pid,
            "window_id": wid,
            "session": _CLIENT.session_name,
            "include_screenshot": bool(include_screenshot),
            "include_accessibility_tree": bool(include_accessibility_tree),
            "tree_format": tree_format,
        }
        if query is not None:
            args["query"] = query
        if max_elements is not None:
            args["max_elements"] = int(max_elements)
        if max_depth is not None:
            args["max_depth"] = int(max_depth)
        if max_image_dimension is not None:
            args["max_image_dimension"] = int(max_image_dimension)
        if since is not None:
            args["since"] = since
        with albedo_trace.unobserved():
            scratch_dir = tempfile.TemporaryDirectory(prefix="albedo-cua-")
        try:
            with albedo_trace.unobserved():
                out_path = (
                    Path(screenshot_out_file).expanduser().resolve()
                    if screenshot_out_file is not None
                    else Path(scratch_dir.name) / "window.png"
                )
                if include_screenshot:
                    out_path.parent.mkdir(parents=True, exist_ok=True)
                    args["screenshot_out_file"] = str(out_path)
            envelope, result = await _CLIENT.call_tool(
                "get_window_state", args, timeout=timeout, raw_envelope=True
            )
            if include_screenshot:
                _attach_from_result(envelope, out_path)
                if screenshot_out_file is None and result.get(
                    "screenshot_file_path"
                ) == str(out_path):
                    result.pop("screenshot_file_path", None)
        finally:
            with albedo_trace.unobserved():
                scratch_dir.cleanup()
        return _as_observation(result)

    async def desktop(
        self,
        *,
        max_image_dimension: int | None = None,
        screenshot_out_file: str | os.PathLike[str] | None = None,
        timeout: float = CALL_TIMEOUT,
    ) -> Observation:
        """Capture the primary desktop (`get_desktop_state`) and attach its screenshot."""
        args: dict[str, Any] = {"session": _CLIENT.session_name}
        if max_image_dimension is not None:
            args["max_image_dimension"] = int(max_image_dimension)
        with albedo_trace.unobserved():
            scratch_dir = tempfile.TemporaryDirectory(prefix="albedo-cua-")
        try:
            with albedo_trace.unobserved():
                out_path = (
                    Path(screenshot_out_file).expanduser().resolve()
                    if screenshot_out_file is not None
                    else Path(scratch_dir.name) / "desktop.png"
                )
                out_path.parent.mkdir(parents=True, exist_ok=True)
                args["screenshot_out_file"] = str(out_path)
            envelope, result = await _CLIENT.call_tool(
                "get_desktop_state", args, timeout=timeout, raw_envelope=True
            )
            _attach_from_result(envelope, out_path)
            if screenshot_out_file is None and result.get(
                "screenshot_file_path"
            ) == str(out_path):
                result.pop("screenshot_file_path", None)
        finally:
            with albedo_trace.unobserved():
                scratch_dir.cleanup()
        return _as_observation(result)

    async def zoom(
        self,
        target: Any,
        x1: float,
        y1: float,
        x2: float,
        y2: float,
        *,
        window_id: int | None = None,
        timeout: float = CALL_TIMEOUT,
    ) -> Record:
        """Crop `[x1, y1, x2, y2]` of a window at native retina resolution (`zoom`) and attach it."""
        pid, wid = _window_ids(target, window_id)
        envelope, result = await _CLIENT.call_tool(
            "zoom",
            {
                "pid": pid,
                "window_id": wid,
                "x1": float(x1),
                "y1": float(y1),
                "x2": float(x2),
                "y2": float(y2),
                "session": _CLIENT.session_name,
            },
            timeout=timeout,
            raw_envelope=True,
        )
        _attach_from_result(envelope)
        return result

    async def focus(
        self,
        target: Any,
        *,
        window_id: int | None = None,
        timeout: float = CALL_TIMEOUT,
    ) -> Record:
        """Bring an application or window to the foreground (`bring_to_front`)."""
        pid, wid = _pid_and_optional_wid(target, window_id)
        args: dict[str, Any] = {"pid": pid, "session": _CLIENT.session_name}
        if wid is not None:
            args["window_id"] = wid
        _, result = await _CLIENT.call_tool("bring_to_front", args, timeout=timeout)
        return result

    async def kill(
        self,
        target: Any,
        *,
        timeout: float = CALL_TIMEOUT,
    ) -> Record:
        """Terminate an application process by `pid` or window/app record (`kill_app`)."""
        pid, _ = _pid_and_optional_wid(target)
        _, result = await _CLIENT.call_tool(
            "kill_app",
            {"pid": pid, "session": _CLIENT.session_name},
            timeout=timeout,
        )
        return result

    async def clipboard(
        self,
        text: str | None = None,
        *,
        include_text: bool = True,
        file_path: str | os.PathLike[str] | None = None,
        image_path: str | os.PathLike[str] | None = None,
        timeout: float = CALL_TIMEOUT,
    ) -> Record:
        """Read the system clipboard (`clipboard_read`), or write `text` / `file_path` / `image_path` (`clipboard_write`)."""
        if text is None and file_path is None and image_path is None:
            _, result = await _CLIENT.call_tool(
                "clipboard_read",
                {
                    "include_text": bool(include_text),
                    "session": _CLIENT.session_name,
                },
                timeout=timeout,
            )
            return result
        args: dict[str, Any] = {"session": _CLIENT.session_name}
        if text is not None:
            args["text"] = str(text)
        if file_path is not None:
            args["file_path"] = str(Path(file_path).expanduser().resolve())
        if image_path is not None:
            args["image_path"] = str(Path(image_path).expanduser().resolve())
        _, result = await _CLIENT.call_tool("clipboard_write", args, timeout=timeout)
        return result

    async def permissions(
        self,
        *,
        prompt: bool = False,
        probe_direct_capture: bool | None = None,
        timeout: float = CALL_TIMEOUT,
    ) -> Record:
        """Inspect Accessibility and Screen Recording grants (`check_permissions`)."""
        args: dict[str, Any] = {
            "prompt": bool(prompt),
            "session": _CLIENT.session_name,
        }
        if probe_direct_capture is not None:
            args["probe_direct_capture"] = bool(probe_direct_capture)
        _, result = await _CLIENT.call_tool("check_permissions", args, timeout=timeout)
        return result

    async def health(
        self,
        *,
        include: list[str] | None = None,
        skip: list[str] | None = None,
        timeout: float = CALL_TIMEOUT,
    ) -> Record:
        """Run `cua-driver` health checks (`health_report`)."""
        args: dict[str, Any] = {"session": _CLIENT.session_name}
        if include is not None:
            args["include"] = [str(item) for item in include]
        if skip is not None:
            args["skip"] = [str(item) for item in skip]
        _, result = await _CLIENT.call_tool("health_report", args, timeout=timeout)
        return result

    async def start_recording(
        self,
        output_dir: str | os.PathLike[str],
        *,
        record_video: bool = False,
        include_accessibility_tree: bool = True,
        state_timeout_ms: int | None = None,
        timeout: float = CALL_TIMEOUT,
    ) -> Record:
        """Start per-turn trajectory and optional ScreenCaptureKit MP4 recording (`start_recording`)."""
        resolved_dir = str(Path(output_dir).expanduser().resolve())
        args: dict[str, Any] = {
            "output_dir": resolved_dir,
            "record_video": bool(record_video),
            "include_accessibility_tree": bool(include_accessibility_tree),
            "session": _CLIENT.session_name,
        }
        if state_timeout_ms is not None:
            args["state_timeout_ms"] = int(state_timeout_ms)
        _, result = await _CLIENT.call_tool("start_recording", args, timeout=timeout)
        return result

    async def stop_recording(self, *, timeout: float = CALL_TIMEOUT) -> Record:
        """Stop active trajectory/video recording and flush artifacts (`stop_recording`)."""
        _, result = await _CLIENT.call_tool(
            "stop_recording",
            {"session": _CLIENT.session_name},
            timeout=timeout,
        )
        return result

    async def recording_state(self, *, timeout: float = CALL_TIMEOUT) -> Record:
        """Inspect current trajectory/video recording status (`get_recording_state`)."""
        _, result = await _CLIENT.call_tool(
            "get_recording_state",
            {"session": _CLIENT.session_name},
            timeout=timeout,
        )
        return result

    def render(self, observation: dict[str, Any], *, max_chars: int = 8000) -> str:
        """Render an observation's accessibility elements as bounded text."""
        return render(observation, max_chars=max_chars)

    def find(self, observation: dict[str, Any], **query: Any) -> list[Record]:
        """Find matching accessibility elements in a window observation."""
        return find(observation, **query)

    def one(self, observation: dict[str, Any], **query: Any) -> Record:
        """Require exactly one matching accessibility element in a window observation."""
        return one(observation, **query)

    async def click(
        self,
        target: Any,
        element_or_x: Any = None,
        y: float | None = None,
        *,
        element_token: str | None = None,
        button: str | None = None,
        count: int | None = None,
        delivery_mode: str | None = None,
        timeout: float = CALL_TIMEOUT,
        **options: Any,
    ) -> Record:
        """Click an `element_token` (or element record) or `(x, y)` on `target`."""
        spec = _target_spec(target)
        args: dict[str, Any] = {
            **options,
            "target": spec,
            "delivery_mode": _default_delivery(spec, delivery_mode),
            "session": _CLIENT.session_name,
        }
        token = element_token or _element_token(element_or_x)
        if token is not None:
            if y is not None:
                raise ValueError("cannot combine an element token with a y coordinate")
            args["element_token"] = token
        elif element_or_x is not None and y is not None:
            args["x"] = float(element_or_x)
            args["y"] = float(y)
        elif "x" in args and "y" in args:
            args["x"] = float(args["x"])
            args["y"] = float(args["y"])
        else:
            raise ValueError(
                "click requires an element_token (or element record) or x and y coordinates"
            )
        if button is not None:
            args["button"] = button
        if count is not None:
            args["count"] = int(count)
        _, result = await _CLIENT.call_tool("click", args, timeout=timeout)
        return result

    async def _secondary_click(
        self,
        tool: str,
        target: Any,
        element_or_x: Any = None,
        y: float | None = None,
        *,
        element_token: str | None = None,
        delivery_mode: str | None = None,
        timeout: float = CALL_TIMEOUT,
        **options: Any,
    ) -> Record:
        spec = _target_spec(target)
        if spec.get("kind") == "desktop":
            return await self.click(
                target,
                element_or_x,
                y,
                element_token=element_token,
                button="right" if tool == "right_click" else None,
                count=2 if tool == "double_click" else None,
                delivery_mode=delivery_mode,
                timeout=timeout,
                **options,
            )
        args: dict[str, Any] = {
            **options,
            "pid": int(spec["pid"]),
            "delivery_mode": _default_delivery(spec, delivery_mode),
            "session": _CLIENT.session_name,
        }
        token = element_token or _element_token(element_or_x)
        if token is not None:
            if y is not None:
                raise ValueError("cannot combine an element token with a y coordinate")
            args["element_token"] = token
        elif element_or_x is not None and y is not None:
            args["window_id"] = int(spec["window_id"])
            args["x"] = float(element_or_x)
            args["y"] = float(y)
        elif "x" in args and "y" in args:
            args["window_id"] = int(spec["window_id"])
            args["x"] = float(args["x"])
            args["y"] = float(args["y"])
        else:
            raise ValueError(
                f"{tool} requires an element_token (or element record) or x and y coordinates"
            )
        _, result = await _CLIENT.call_tool(tool, args, timeout=timeout)
        return result

    async def double_click(
        self,
        target: Any,
        element_or_x: Any = None,
        y: float | None = None,
        *,
        element_token: str | None = None,
        delivery_mode: str | None = None,
        timeout: float = CALL_TIMEOUT,
        **options: Any,
    ) -> Record:
        """Double-click an element or `(x, y)` on `target` (`double_click`)."""
        return await self._secondary_click(
            "double_click",
            target,
            element_or_x,
            y,
            element_token=element_token,
            delivery_mode=delivery_mode,
            timeout=timeout,
            **options,
        )

    async def right_click(
        self,
        target: Any,
        element_or_x: Any = None,
        y: float | None = None,
        *,
        element_token: str | None = None,
        delivery_mode: str | None = None,
        timeout: float = CALL_TIMEOUT,
        **options: Any,
    ) -> Record:
        """Right-click an element or `(x, y)` on `target` (`right_click`)."""
        return await self._secondary_click(
            "right_click",
            target,
            element_or_x,
            y,
            element_token=element_token,
            delivery_mode=delivery_mode,
            timeout=timeout,
            **options,
        )

    async def move(
        self,
        target: Any,
        x: float,
        y: float,
        *,
        timeout: float = CALL_TIMEOUT,
        **options: Any,
    ) -> Record:
        """Move the agent cursor to `(x, y)` on `target` (`move_cursor`)."""
        spec = _target_spec(target)
        args: dict[str, Any] = {
            **options,
            "target": spec,
            "x": float(x),
            "y": float(y),
            "session": _CLIENT.session_name,
        }
        _, result = await _CLIENT.call_tool("move_cursor", args, timeout=timeout)
        return result

    async def drag(
        self,
        target: Any,
        from_x: float,
        from_y: float,
        to_x: float,
        to_y: float,
        *,
        delivery_mode: str | None = None,
        duration_ms: int | None = None,
        steps: int | None = None,
        button: str | None = None,
        timeout: float = CALL_TIMEOUT,
        **options: Any,
    ) -> Record:
        """Drag from `(from_x, from_y)` to `(to_x, to_y)` on `target` (`drag`)."""
        spec = _target_spec(target)
        args: dict[str, Any] = {
            **options,
            "target": spec,
            "from_x": float(from_x),
            "from_y": float(from_y),
            "to_x": float(to_x),
            "to_y": float(to_y),
            "session": _CLIENT.session_name,
        }
        if delivery_mode is not None:
            args["delivery_mode"] = _default_delivery(spec, delivery_mode)
        if duration_ms is not None:
            args["duration_ms"] = int(duration_ms)
        if steps is not None:
            args["steps"] = int(steps)
        if button is not None:
            args["button"] = button
        _, result = await _CLIENT.call_tool("drag", args, timeout=timeout)
        return result

    async def scroll(
        self,
        target: Any,
        x: float,
        y: float,
        direction: str = "down",
        *,
        amount: int | None = None,
        by: str | None = None,
        delivery_mode: str | None = None,
        timeout: float = CALL_TIMEOUT,
        **options: Any,
    ) -> Record:
        """Scroll `up`, `down`, `left`, or `right` at `(x, y)` on `target` (`scroll`)."""
        spec = _target_spec(target)
        args: dict[str, Any] = {
            **options,
            "target": spec,
            "x": float(x),
            "y": float(y),
            "direction": direction,
            "session": _CLIENT.session_name,
        }
        if amount is not None:
            args["amount"] = int(amount)
        if by is not None:
            args["by"] = by
        if delivery_mode is not None:
            args["delivery_mode"] = _default_delivery(spec, delivery_mode)
        _, result = await _CLIENT.call_tool("scroll", args, timeout=timeout)
        return result

    async def type_text(
        self,
        target: Any,
        text: str,
        *,
        element: Any = None,
        element_token: str | None = None,
        x: float | None = None,
        y: float | None = None,
        delivery_mode: str | None = None,
        timeout: float = CALL_TIMEOUT,
        **options: Any,
    ) -> Record:
        """Insert `text` into `target` (optionally addressing `element` or `(x, y)`)."""
        spec = _target_spec(target)
        args: dict[str, Any] = {
            **options,
            "target": spec,
            "text": str(text),
            "session": _CLIENT.session_name,
        }
        token = element_token or _element_token(element)
        if token is not None:
            args["element_token"] = token
        if x is not None and y is not None:
            args["x"] = float(x)
            args["y"] = float(y)
        if delivery_mode is not None:
            args["delivery_mode"] = _default_delivery(spec, delivery_mode)
        _, result = await _CLIENT.call_tool("type_text", args, timeout=timeout)
        return result

    async def set_value(
        self,
        target: Any,
        value: str,
        *,
        element: Any = None,
        element_token: str | None = None,
        timeout: float = CALL_TIMEOUT,
        **options: Any,
    ) -> Record:
        """Set a native control's value by `element_token` (`set_value`)."""
        args: dict[str, Any] = {
            **options,
            "value": str(value),
            "session": _CLIENT.session_name,
        }
        token = element_token or _element_token(element) or _element_token(target)
        if token is not None:
            args["element_token"] = token
            if (
                isinstance(target, dict)
                and isinstance(target.get("pid"), int)
                and target["pid"] > 0
            ):
                args["pid"] = int(target["pid"])
        else:
            raise ValueError(
                "set_value requires an element record or element_token= from cua.observe()"
            )
        _, result = await _CLIENT.call_tool("set_value", args, timeout=timeout)
        return result

    async def press_key(
        self,
        target: Any,
        key: str,
        *,
        modifiers: list[str] | None = None,
        delivery_mode: str | None = None,
        timeout: float = CALL_TIMEOUT,
        **options: Any,
    ) -> Record:
        """Send one key press to `target` (`press_key`)."""
        spec = _target_spec(target)
        args: dict[str, Any] = {
            **options,
            "target": spec,
            "key": str(key),
            "session": _CLIENT.session_name,
        }
        if modifiers is not None:
            args["modifiers"] = [str(m) for m in modifiers]
        if delivery_mode is not None:
            args["delivery_mode"] = _default_delivery(spec, delivery_mode)
        _, result = await _CLIENT.call_tool("press_key", args, timeout=timeout)
        return result

    async def hotkey(
        self,
        target: Any,
        *keys: str | list[str] | tuple[str, ...],
        delivery_mode: str | None = None,
        timeout: float = CALL_TIMEOUT,
        **options: Any,
    ) -> Record:
        """Send a multi-key chord (at least 2 keys, e.g. `'cmd', 's'`) to `target` (`hotkey`)."""
        flat: list[str] = []
        for item in keys:
            if isinstance(item, (list, tuple)):
                flat.extend(str(k) for k in item)
            else:
                flat.append(str(item))
        if len(flat) < 2:
            raise ValueError("hotkey requires at least two keys")
        spec = _target_spec(target)
        args: dict[str, Any] = {
            **options,
            "target": spec,
            "keys": flat,
            "session": _CLIENT.session_name,
        }
        if delivery_mode is not None:
            args["delivery_mode"] = _default_delivery(spec, delivery_mode)
        _, result = await _CLIENT.call_tool("hotkey", args, timeout=timeout)
        return result

    async def menu(
        self,
        target: Any,
        *path: str | list[str] | tuple[str, ...],
        window_id: int | None = None,
        timeout: float = CALL_TIMEOUT,
    ) -> Record:
        """Invoke an application menu path such as `'File', 'Save'` (`invoke_menu`)."""
        pid, wid = _window_ids(target, window_id)
        flat: list[str] = []
        for item in path:
            if isinstance(item, (list, tuple)):
                flat.extend(str(part) for part in item)
            else:
                flat.append(str(item))
        if not flat:
            raise ValueError("menu requires at least one menu label")
        _, result = await _CLIENT.call_tool(
            "invoke_menu",
            {
                "pid": pid,
                "window_id": wid,
                "path": flat,
                "session": _CLIENT.session_name,
            },
            timeout=timeout,
        )
        return result

    async def frame(
        self,
        target: Any,
        x: float,
        y: float,
        width: float,
        height: float,
        *,
        window_id: int | None = None,
        timeout: float = CALL_TIMEOUT,
    ) -> Record:
        """Set a top-level window's geometry (`set_window_frame`)."""
        pid, wid = _window_ids(target, window_id)
        _, result = await _CLIENT.call_tool(
            "set_window_frame",
            {
                "pid": pid,
                "window_id": wid,
                "x": float(x),
                "y": float(y),
                "width": float(width),
                "height": float(height),
                "session": _CLIENT.session_name,
            },
            timeout=timeout,
        )
        return result

    async def verify(
        self,
        target: Any,
        expect: list[dict[str, Any]] | dict[str, Any],
        *,
        window_id: int | None = None,
        timeout_ms: int | None = None,
        stable_samples: int | None = None,
        include_screenshot: bool = False,
        timeout: float = CALL_TIMEOUT,
    ) -> Record:
        """Check 1..8 postcondition predicates against a window (`verify_state`)."""
        pid, wid = _window_ids(target, window_id)
        predicates = [expect] if isinstance(expect, dict) else list(expect)
        if not predicates:
            raise ValueError("verify requires at least one predicate in expect")
        args: dict[str, Any] = {
            "pid": pid,
            "window_id": wid,
            "expect": predicates,
            "include_screenshot": bool(include_screenshot),
            "session": _CLIENT.session_name,
        }
        if timeout_ms is not None:
            args["timeout_ms"] = int(timeout_ms)
        if stable_samples is not None:
            args["stable_samples"] = int(stable_samples)
        envelope, result = await _CLIENT.call_tool(
            "verify_state", args, timeout=timeout, raw_envelope=True
        )
        if include_screenshot:
            _attach_from_result(envelope)
        return result

    async def close(self) -> None:
        """End the active `cua-driver` session and close its stdio process."""
        await _CLIENT.close()

    def __repr__(self) -> str:
        return (
            "<cua api: apps(), windows(), window(), launch(), observe(), desktop(), "
            "zoom(), focus(), kill(), clipboard(), permissions(), health(), "
            "start_recording(), stop_recording(), recording_state(), "
            "render(), find(), one(), click(), double_click(), right_click(), "
            "move(), drag(), scroll(), type_text(), set_value(), press_key(), "
            "hotkey(), menu(), frame(), verify(), tools(), call(), configure(), close()>"
        )


cua = Cua()
sys.modules["cua"] = sys.modules[__name__]


async def _cleanup() -> None:
    await _CLIENT.close()


def setup(api: PythonApi) -> dict[str, object]:
    global attach_image
    attach_image = api.attach_image
    api.on_shutdown(_cleanup)
    return {"cua": cua, "CuaError": CuaError}
