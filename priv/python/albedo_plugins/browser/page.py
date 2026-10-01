"""Semantic observations and deliberately explicit actions, on a live CDP page."""

from __future__ import annotations

from typing import SupportsIndex
from collections.abc import Callable

import asyncio
import base64
import contextlib
import copy
import math
import time
import uuid
from collections import OrderedDict
from contextlib import asynccontextmanager
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, TYPE_CHECKING

from . import javascript as js
from .errors import (
    ActionOutcomeUnknown,
    BrowserError,
    ConnectionLost,
    JavaScriptError,
    NotActionable,
    ProtocolError,
    SelectionError,
    StaleReference,
    UnsupportedOperation,
    WaitTimeout,
    TargetGone,
    RecoveryError,
)
from .observation import (
    Node,
    Observation,
    attributes_from_node,
    attributes_from_snapshot,
    ax_properties,
    find,
    walk_ax,
)
from .events import EventScope
from .recovery import PageCDPSession

if TYPE_CHECKING:
    from .session import Browser
from .transport import CDPSession, JSON, positive


_attach_image: Callable[[bytes], str] | None = None


def register_attach_image(callback: Callable[[bytes], str] | None) -> None:
    global _attach_image
    _attach_image = callback


def now() -> str:
    return datetime.now(timezone.utc).isoformat()


@dataclass
class _Session:
    cdp: CDPSession
    target_id: str
    root_frame: str = ""
    generation: int = 0
    ready: bool = False
    error: str | None = None


@dataclass(frozen=True)
class _Reference:
    session_id: str
    frame_id: str
    generation: int
    backend_id: int
    role: str
    name: str
    attributes: dict[str, str]


class Page:
    def __init__(
        self, browser: Browser, target_id: str, session_id: str, *, owned: bool
    ) -> None:
        self.browser = browser
        self.target_id = target_id
        self.cdp = PageCDPSession(self, session_id)
        self.owned = owned
        self._sessions = {session_id: _Session(self.cdp, target_id)}
        self._tasks: set[asyncio.Task[None]] = set()
        self._snapshots: OrderedDict[str, dict[str, _Reference]] = OrderedDict()
        self._lock = asyncio.Lock()
        self._settings_lock = asyncio.Lock()
        self._settings: dict[str, JSON] = {}
        self._recovering = False
        self._destroyed = False
        self.last_recovery: JSON | None = None
        self._closed = False
        self._main_frame = ""
        self.last_action: JSON | None = None
        self._frame_sessions: dict[str, str | None] = {}
        self._frame_info: dict[str, JSON] = {}

    async def _initialize(self) -> None:
        session_id = self.cdp.session_id
        assert session_id is not None
        await self._init_session(self._sessions[session_id])
        self._main_frame = self._sessions[session_id].root_frame

    async def _init_session(self, state: _Session) -> None:
        try:
            for domain in ("Page", "DOM", "Runtime", "Accessibility"):
                await state.cdp.send(f"{domain}.enable")
            await state.cdp.send("Page.setLifecycleEventsEnabled", {"enabled": True})
            tree = await state.cdp.send("Page.getFrameTree")
            state.root_frame = tree["frameTree"]["frame"]["id"]
            await state.cdp.send(
                "Target.setAutoAttach",
                {
                    "autoAttach": True,
                    "waitForDebuggerOnStart": False,
                    "flatten": True,
                    "filter": [{"type": "iframe", "exclude": False}, {"exclude": True}],
                },
            )
            state.ready = True
        except Exception as exc:
            state.error = type(exc).__name__ + ": " + str(exc)
            if state.cdp.session_id == self.cdp.session_id:
                raise

    def _on_event(self, method: str, params: JSON, session_id: str) -> None:
        state = self._sessions.get(session_id)
        if (
            method
            in {
                "DOM.documentUpdated",
                "Runtime.executionContextsCleared",
                "Page.frameNavigated",
            }
            and state
        ):
            state.generation += 1
        if method == "Page.frameDetached" and params.get("reason") != "swap" and state:
            state.generation += 1
        if (
            method == "Target.attachedToTarget"
            and params.get("targetInfo", {}).get("type") == "iframe"
        ):
            sid = params["sessionId"]
            if sid in self._sessions:
                return
            child = _Session(
                CDPSession(self.browser._connection, sid),
                params["targetInfo"]["targetId"],
            )
            self._sessions[sid] = child
            self.browser._routes[sid] = self
            task = asyncio.create_task(
                self._init_session(child), name="browser-iframe-init"
            )
            self._tasks.add(task)
            task.add_done_callback(self._tasks.discard)

    def _detached(self, sid: str) -> None:
        state = self._sessions.pop(sid, None)
        if state is not None:
            state.generation += 1
        if sid == self.cdp.session_id:
            self._invalidate()

    def _invalidate(self, *, destroyed: bool = False) -> None:
        """Invalidate a whole attachment, including child sessions and references."""
        self._closed = True
        self._destroyed = self._destroyed or destroyed
        self._snapshots.clear()
        for task in self._tasks:
            task.cancel()
        for sid, state in tuple(self._sessions.items()):
            state.generation += 1
            state.cdp.connection.detach_session(sid)
            if self.browser._routes.get(sid) is self:
                self.browser._routes.pop(sid, None)
        self._sessions.clear()
        self._frame_sessions.clear()
        self._frame_info.clear()
        self._main_frame = ""

    async def _stop_tasks(self) -> None:
        tasks = list(self._tasks)
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)

    @property
    def attached(self) -> bool:
        """Local attachment status, not a network health probe."""
        return (
            not self._closed
            and not self._destroyed
            and not self._recovering
            and not self.cdp.connection.closed
            and self.cdp.connection is self.browser._connection
        )

    @property
    def recovery_settings(self) -> list[JSON]:
        """Copy of acknowledged, replayable root-page settings; not browser state."""
        return copy.deepcopy(list(self._settings.values()))

    def _check(self) -> None:
        if self._destroyed:
            raise TargetGone(
                "The original tab is closed; reattachment cannot recreate it.",
                target_id=self.target_id,
            )
        if not self.attached:
            failure = self.cdp.connection._closed
            raise ConnectionLost(
                "This page handle is detached or disconnected; use await page.reattach().",
                target_id=self.target_id,
                recovery="await page.reattach()",
                connection_error=failure.to_dict() if failure else None,
            )

    async def reattach(
        self,
        *,
        timeout: float = 15,
        restore_settings: bool = True,
        max_message_bytes: int | None = None,
    ) -> Page:
        """Recover this exact target and Python object, without navigating or retrying actions.

        Reopens a lost browser socket when needed, retaining headers and process
        ownership. Other tabs on that socket require their own explicit reattach.
        Healthy handles are no-ops. References and event streams from a replaced
        session remain invalid. Only the documented acknowledged settings replay.
        """
        positive(timeout, "timeout")
        if not isinstance(restore_settings, bool):
            raise TypeError("restore_settings must be a bool")
        if max_message_bytes is not None and (
            isinstance(max_message_bytes, bool)
            or not isinstance(max_message_bytes, int)
            or max_message_bytes < 1024
        ):
            raise ValueError("max_message_bytes must be an integer of at least 1024")
        try:
            async with asyncio.timeout(timeout):
                # The browser lock serializes connection replacement, attaching,
                # disconnecting and closing. Then serialize with actions/settings.
                async with self.browser._lifecycle_lock:
                    async with self._lock:
                        async with self._settings_lock:
                            return await self._reattach_locked(
                                restore_settings=restore_settings,
                                max_message_bytes=max_message_bytes,
                            )
        except TimeoutError as exc:
            raise RecoveryError(
                "Reattachment exceeded its deadline; no action was replayed.",
                target_id=self.target_id,
                timeout=timeout,
            ) from exc

    async def _reattach_locked(
        self, *, restore_settings: bool, max_message_bytes: int | None
    ) -> Page:
        if self._destroyed:
            raise TargetGone(
                "The original tab is closed; no replacement was created.",
                target_id=self.target_id,
            )
        if self.browser._close_task is not None:
            raise ConnectionLost(
                "Browser.close() was called; use a new browser handle."
            )
        connection = self.browser._connection
        if (
            not connection.closed
            and max_message_bytes is not None
            and max_message_bytes != connection.max_message_bytes
        ):
            raise ValueError(
                "Changing max_message_bytes requires a lost or explicitly disconnected browser socket"
            )
        if self.attached:
            return self
        other = self.browser._pages.get(self.target_id)
        if other is not None and other is not self:
            raise RecoveryError(
                "Another page handle now owns this target's attachment; use that handle.",
                target_id=self.target_id,
            )
        receipt: JSON = {
            "status": "recovering",
            "target_id": self.target_id,
            "old_session_id": self.cdp.session_id,
            "restored_methods": [],
            "event_history_gap": True,
            "started_at": now(),
            "transport_reconnected": False,
        }
        self.last_recovery = receipt
        self._recovering = True
        new_sid: str | None = None
        attach_started = False
        # _invalidate() kills the previous session's event streams and references.
        self._invalidate()
        try:
            await self._stop_tasks()
            receipt["transport_reconnected"] = await self.browser._ensure_connection(
                max_message_bytes
            )
            targets = await self.browser.pages()
            if not any(t["targetId"] == self.target_id for t in targets):
                self._destroyed = True
                raise TargetGone(
                    "The original target no longer exists; no new tab was created.",
                    target_id=self.target_id,
                )
            attach_started = True
            try:
                result = await self.browser.cdp.send(
                    "Target.attachToTarget",
                    {
                        "targetId": self.target_id,
                        "flatten": True,
                    },
                )
            except ProtocolError as exc:
                # A protocol rejection acknowledges that no attachment succeeded.
                attach_started = False
                if self._destroyed or not any(
                    t["targetId"] == self.target_id for t in await self.browser.pages()
                ):
                    self._destroyed = True
                    raise TargetGone(
                        "The target closed during reattachment; no replacement was created.",
                        target_id=self.target_id,
                    ) from exc
                raise
            new_sid = result["sessionId"]
            self.cdp = PageCDPSession(self, new_sid)
            self._sessions = {new_sid: _Session(self.cdp, self.target_id)}
            self.browser._pages[self.target_id] = self
            self.browser._routes[new_sid] = self
            # _closed stays True until initialization and settings both succeed.
            await self._initialize()
            if restore_settings:
                for item in self.recovery_settings:
                    try:
                        # Bypass recording: restoration is not a new configuration.
                        await self.cdp.connection.send(
                            item["method"], item["params"], session_id=new_sid
                        )
                    except BrowserError as exc:
                        raise RecoveryError(
                            "Emulation restoration failed; this handle remains detached.",
                            target_id=self.target_id,
                            failed_method=item["method"],
                            restored_methods=list(receipt["restored_methods"]),
                            cause=exc.to_dict(),
                        ) from exc
                    receipt["restored_methods"].append(item["method"])
            if (
                self.cdp.connection.closed
                or new_sid not in self._sessions
                or self._destroyed
            ):
                raise ConnectionLost(
                    "Target detached again during reattachment.",
                    target_id=self.target_id,
                )
            self._closed = False
            receipt.update(
                status="reattached",
                new_session_id=new_sid,
                finished_at=now(),
                settings_restored=restore_settings,
            )
            return self
        except BaseException as exc:
            receipt.update(
                status="cancelled"
                if isinstance(exc, asyncio.CancelledError)
                else "failed",
                error=type(exc).__name__,
                finished_at=now(),
            )
            self._invalidate()
            # Bounded cleanup survives repeated interruption. Never close the tab.
            from .launch import _finish_cleanup

            async def cleanup() -> None:
                await self._stop_tasks()
                if new_sid is not None and not self.browser._connection.closed:
                    try:
                        await self.browser.cdp.send(
                            "Target.detachFromTarget", {"sessionId": new_sid}, timeout=2
                        )
                    except BrowserError:
                        # Cannot prove cleanup of the failed attachment. Release
                        # every session on this socket, while preserving tabs.
                        receipt["transport_disconnected_for_cleanup"] = True
                        await self.browser._disconnect()
                elif attach_started and not self.browser._connection.closed:
                    # The attach may have succeeded but its session ID was lost.
                    # Closing the socket releases unknown sessions without closing
                    # their tabs. Other page handles must explicitly reattach too.
                    receipt["transport_disconnected_for_cleanup"] = True
                    await self.browser._disconnect()

            await _finish_cleanup(
                asyncio.create_task(cleanup(), name="browser-reattach-cleanup")
            )
            raise
        finally:
            self._recovering = False

    def descriptor(self) -> JSON:
        """Serializable reconnect data; no sockets, headers or actionable references."""
        return {"endpoint": self.browser.endpoint, "target_id": self.target_id}

    def events(self, method: str, **options: Any) -> EventScope:
        """Root-target events only; for OOPIFs use frame_cdp() with EventScope."""
        return EventScope(self.cdp, method, **options)

    async def frames(self) -> list[JSON]:
        self._check()
        for _ in range(4):
            tasks = list(self._tasks)
            if not tasks:
                break
            await asyncio.gather(*tasks)
        frames: dict[str, JSON] = {}
        routes: dict[str, str | None] = {}
        # Root target first; an OOPIF's own session takes precedence over its placeholder.
        states = sorted(
            self._sessions.values(),
            key=lambda s: s.cdp.session_id != self.cdp.session_id,
        )
        for state in states:
            if not state.ready:
                continue
            try:
                tree = (await state.cdp.send("Page.getFrameTree"))["frameTree"]
            except ProtocolError:
                continue
            stack = [(tree, None)]
            while stack:
                entry, parent = stack.pop()
                f = entry["frame"]
                fid = f["id"]
                old = frames.get(fid, {})
                frames[fid] = {
                    "id": fid,
                    "parent_id": f.get("parentId", parent or old.get("parent_id")),
                    "url": f.get("url", ""),
                    "name": f.get("name", ""),
                    "session_id": state.cdp.session_id,
                    "out_of_process": state.cdp.session_id != self.cdp.session_id,
                }
                routes[fid] = state.cdp.session_id
                for child in reversed(entry.get("childFrames", [])):
                    stack.append((child, fid))
        self._frame_sessions = routes
        self._frame_info = frames
        return list(frames.values())

    async def frame_cdp(self, frame_id: str) -> CDPSession:
        await self.frames()
        sid = self._frame_sessions.get(frame_id)
        if sid is None:
            raise UnsupportedOperation("Frame is not attached.", frame_id=frame_id)
        return self._sessions[sid].cdp

    async def observe(
        self,
        *,
        max_nodes: int = 1500,
        max_text: int = 1500,
        max_depth: int = 50,
        frame_id: str | None = None,
        retain: int = 8,
    ) -> Observation:
        """Capture AX + safe DOM attributes into JSON-compatible records.

        max_nodes bounds retained records, NOT Chromium's full per-frame AX capture.
        max_depth and the connection's message-size ceiling bound other dimensions.
        Coverage reports omissions/races. Capture is not atomic with page scripts.
        """
        if min(max_nodes, max_text, max_depth, retain) < 1 or retain > 64:
            raise ValueError(
                "Capture limits must be positive; retain must be at most 64"
            )
        self._check()
        started = time.monotonic()
        snapshot_id = "s" + uuid.uuid4().hex[:12]
        frames = await self.frames()
        chosen = [f for f in frames if frame_id is None or f["id"] == frame_id]
        if not chosen:
            raise UnsupportedOperation(
                "Requested frame was not found.", frame_id=frame_id
            )
        warnings: list[JSON] = []
        for state in self._sessions.values():
            if not state.ready:
                warnings.append(
                    {
                        "kind": "frame_not_ready",
                        "target_id": state.target_id,
                        "error": state.error,
                    }
                )
        dom_by_session = {}
        refs: dict[str, _Reference] = {}
        rows: list[Node] = []
        for frame in chosen:
            if len(rows) >= max_nodes:
                warnings.append(
                    {"kind": "frame_omitted_by_node_limit", "frame_id": frame["id"]}
                )
                continue
            sid = frame["session_id"]
            state = self._sessions[sid]
            generation = state.generation
            try:
                if sid not in dom_by_session:
                    dom_by_session[sid] = attributes_from_snapshot(
                        await state.cdp.send(
                            "DOMSnapshot.captureSnapshot",
                            {"computedStyles": []},
                        )
                    )
                raw = (
                    await state.cdp.send(
                        "Accessibility.getFullAXTree",
                        {
                            "frameId": frame["id"],
                            "depth": max_depth,
                        },
                    )
                )["nodes"]
            except ProtocolError as exc:
                warnings.append(
                    {
                        "kind": "frame_unavailable",
                        "frame_id": frame["id"],
                        "error": exc.to_dict(),
                    }
                )
                continue
            attributes = dom_by_session[sid]
            nodes = walk_ax(raw)
            raw_ids = {n["nodeId"] for n in raw}
            if any(c not in raw_ids for n in raw for c in n.get("childIds", [])):
                warnings.append(
                    {"kind": "depth_or_tree_omission", "frame_id": frame["id"]}
                )
            ids: dict[str, str] = {}
            for ax, parent, depth in nodes:
                if len(rows) >= max_nodes:
                    warnings.append({"kind": "node_limit", "frame_id": frame["id"]})
                    break
                row_id = f"{snapshot_id}:{len(rows) + 1}"
                ids[ax["nodeId"]] = row_id
                role = str(ax.get("role", {}).get("value", ""))
                name = str(ax.get("name", {}).get("value", ""))
                backend = ax.get("backendDOMNodeId")
                attrs = attributes.get(backend, {})
                actionable = bool(
                    backend
                    and backend in attributes
                    and role not in {"StaticText", "RootWebArea", "InlineTextBox"}
                )
                ref = row_id if actionable else None
                row: Node = {
                    "id": row_id,
                    "ref": ref,
                    "role": "text" if role == "StaticText" else role,
                    "name": name[:max_text],
                    "frame_id": frame["id"],
                    "parent": ids.get(parent),
                    "depth": depth,
                }
                if len(name) > max_text:
                    row["name_truncated"] = True
                    warnings.append({"kind": "text_truncated", "node": row_id})
                props = ax_properties(ax)
                for key in (
                    "disabled",
                    "checked",
                    "selected",
                    "expanded",
                    "required",
                    "readonly",
                    "focused",
                    "level",
                ):
                    if key in props:
                        row[key] = props[key]
                if attrs:
                    row["attributes"] = dict(attrs)
                    if "href" in attrs:
                        row["href"] = attrs["href"]
                if "value" in ax:
                    value = ax["value"].get("value")
                    row["value"] = (
                        "[redacted]" if attrs.get("type") == "password" else value
                    )
                    if isinstance(row["value"], str) and len(row["value"]) > max_text:
                        row["value"] = row["value"][:max_text]
                        warnings.append({"kind": "value_truncated", "node": row_id})
                if ref and backend is not None:
                    refs[ref] = _Reference(
                        sid, frame["id"], generation, backend, role, name, dict(attrs)
                    )
                rows.append(row)
            if state.generation != generation:
                warnings.append(
                    {"kind": "document_changed_during_capture", "frame_id": frame["id"]}
                )
        self._snapshots[snapshot_id] = refs
        while len(self._snapshots) > retain:
            self._snapshots.popitem(last=False)
        title = await self.evaluate("document.title")
        return {
            "snapshot_id": snapshot_id,
            "target_id": self.target_id,
            "url": self._frame_info.get(self._main_frame, {}).get("url", ""),
            "title": title,
            "captured_at": now(),
            "capture_ms": round((time.monotonic() - started) * 1000, 1),
            "nodes": rows,
            "frames": frames,
            "coverage": {
                "complete": not warnings,
                "warnings": warnings,
                "scope_frame_id": frame_id,
                "atomic": False,
                "max_nodes_is_retention_limit": True,
            },
        }

    def _ref(self, ref: str | Node) -> tuple[str, _Reference, _Session]:
        self._check()
        key = ref.get("ref") if isinstance(ref, dict) else ref
        if not isinstance(key, str) or ":" not in key:
            raise StaleReference("This node has no actionable reference.")
        record = self._snapshots.get(key.split(":", 1)[0], {}).get(key)
        if record is None:
            raise StaleReference(
                "Reference is unknown, evicted, or from another connection.", ref=key
            )
        state = self._sessions.get(record.session_id)
        if state is None or state.generation != record.generation:
            raise StaleReference(
                "Document or frame changed after observation.", ref=key
            )
        return key, record, state

    async def _call(
        self,
        cdp: CDPSession,
        object_id: str,
        function: str,
        *,
        arguments: list[JSON] | None = None,
    ) -> Any:
        response = await cdp.send(
            "Runtime.callFunctionOn",
            {
                "objectId": object_id,
                "functionDeclaration": function,
                "arguments": arguments or [],
                "returnByValue": True,
                "awaitPromise": True,
            },
        )
        return self._value(response)

    @staticmethod
    def _value(response: JSON) -> Any:
        if "exceptionDetails" in response:
            detail = response["exceptionDetails"]
            raise JavaScriptError(
                "Page JavaScript threw an exception.",
                description=detail.get("exception", {}).get(
                    "description", detail.get("text")
                ),
            )
        result = response.get("result", {})
        if "unserializableValue" in result:
            raise JavaScriptError(
                "Result is not JSON-serializable; convert it explicitly in JavaScript.",
                value=result["unserializableValue"],
            )
        if "objectId" in result:
            raise JavaScriptError(
                "Result did not serialize by value; return plain JSON data."
            )
        return result.get("value")

    @asynccontextmanager
    async def _resolved(self, ref: str | Node):
        key, record, state = self._ref(ref)
        object_id = None
        try:
            try:
                node = (
                    await state.cdp.send(
                        "DOM.describeNode", {"backendNodeId": record.backend_id}
                    )
                )["node"]
                if attributes_from_node(node) != record.attributes:
                    raise StaleReference(
                        "Element identity attributes changed.", ref=key
                    )
                ax = (
                    await state.cdp.send(
                        "Accessibility.getPartialAXTree",
                        {
                            "backendNodeId": record.backend_id,
                            "fetchRelatives": False,
                        },
                    )
                )["nodes"]
                current = next(
                    (n for n in ax if n.get("backendDOMNodeId") == record.backend_id),
                    None,
                )
                if (
                    current is None
                    or current.get("ignored")
                    or current.get("role", {}).get("value") != record.role
                    or current.get("name", {}).get("value", "") != record.name
                ):
                    raise StaleReference(
                        "Element role or accessible name changed.", ref=key
                    )
                obj = (
                    await state.cdp.send(
                        "DOM.resolveNode", {"backendNodeId": record.backend_id}
                    )
                )["object"]
                object_id = obj.get("objectId")
                if not object_id:
                    raise StaleReference("Element no longer resolves.", ref=key)
                status = await self._call(state.cdp, object_id, js.STATE)
                self._ref(key)
                if not status.get("connected"):
                    raise StaleReference("Element was detached.", ref=key)
            except ProtocolError as exc:
                raise StaleReference(
                    "Element no longer resolves in its original document.", ref=key
                ) from exc
            yield key, record, state, object_id, status
        finally:
            if object_id and not self.browser._connection.closed:
                with contextlib.suppress(BrowserError):
                    await state.cdp.send(
                        "Runtime.releaseObject", {"objectId": object_id}, timeout=2
                    )

    @asynccontextmanager
    async def _action(self, action: str, ref: str | Node | None = None):
        async with self._lock:
            self._check()
            receipt: JSON = {
                "action": action,
                "ref": ref.get("ref") if isinstance(ref, dict) else ref,
                "status": "preparing",
                "may_have_executed": False,
                "started_at": now(),
            }
            self.last_action = receipt
            try:
                yield receipt
                receipt["status"] = "input_dispatched"
                receipt["finished_at"] = now()
            except BaseException as exc:
                receipt["status"] = (
                    "outcome_unknown" if receipt["may_have_executed"] else "rejected"
                )
                receipt["error"] = type(exc).__name__
                receipt["finished_at"] = now()
                if receipt["may_have_executed"] and isinstance(exc, Exception):
                    raise ActionOutcomeUnknown(
                        "Action may have happened. Observe application state before retrying.",
                        receipt=copy.deepcopy(receipt),
                        cause=exc.to_dict()
                        if isinstance(exc, BrowserError)
                        else str(exc),
                    ) from exc
                if receipt["may_have_executed"]:
                    exc.add_note(
                        "Browser input may have been dispatched; inspect page.last_action and observe before retrying."
                    )
                raise

    async def evaluate(
        self,
        expression: str,
        *,
        frame_id: str | None = None,
        timeout: float | None = None,
    ) -> Any:
        """Evaluate an expression or a zero-argument function; await promises; return data.

        This is a raw escape hatch: it may mutate the page and bypasses action locking.
        Explicitly invoke functions taking arguments in the supplied expression.
        """
        self._check()
        cdp = self.cdp
        params: JSON = {
            "expression": f"(async () => {{ const v = ({expression}\n); return typeof v === 'function' ? await v() : await v; }})()",
            "returnByValue": True,
            "awaitPromise": True,
        }
        if frame_id is not None:
            cdp = await self.frame_cdp(frame_id)
            # Isolated worlds avoid guessing a frame's default executionContextId.
            world = await cdp.send(
                "Page.createIsolatedWorld",
                {
                    "frameId": frame_id,
                    "worldName": "prime-browser-evaluate",
                },
            )
            params["contextId"] = world["executionContextId"]
        result = await cdp.send("Runtime.evaluate", params, timeout=timeout)
        return self._value(result)

    async def goto(
        self, url: str, *, wait: str = "domcontentloaded", timeout: float = 30
    ) -> JSON:
        if wait not in {"commit", "domcontentloaded", "load"}:
            raise ValueError("wait must be commit, domcontentloaded, or load")
        positive(timeout, "timeout")
        async with self._action("goto") as receipt:
            try:
                async with asyncio.timeout(timeout):
                    # Subscribe first: lifecycle events may precede the navigate reply.
                    async with self.events(
                        "Page.lifecycleEvent", enable=False
                    ) as events:
                        receipt["may_have_executed"] = True
                        result = await self.cdp.send(
                            "Page.navigate", {"url": url}, timeout=timeout
                        )
                        if result.get("errorText") or result.get("isDownload"):
                            raise BrowserError(
                                "Navigation failed or became a download.", result=result
                            )
                        loader = result.get("loaderId")
                        if wait != "commit" and loader:
                            milestone = (
                                "DOMContentLoaded"
                                if wait == "domcontentloaded"
                                else "load"
                            )
                            await events.next(
                                where=lambda e: (
                                    e.get("loaderId") == loader
                                    and e.get("name") == milestone
                                ),
                                timeout=timeout,
                            )
                        receipt["navigation"] = result
                        receipt["milestone"] = wait
            except TimeoutError as exc:
                raise WaitTimeout(
                    "Navigation did not reach its milestone before the deadline."
                ) from exc
        return copy.deepcopy(receipt)

    async def wait_for(
        self,
        *,
        timeout: float = 10,
        interval: float = 0.15,
        state: str = "present",
        **query: Any,
    ) -> Node | None:
        """Poll semantic state; no input is dispatched. 'absent' requires full coverage."""
        positive(timeout, "timeout")
        positive(interval, "interval")
        if state not in {"present", "absent"}:
            raise ValueError("state must be present or absent")
        if not query:
            raise ValueError(
                "Supply a semantic query such as role='button', name='Save'"
            )
        last_coverage = None
        try:
            async with asyncio.timeout(timeout):
                while True:
                    snapshot = await self.observe(frame_id=query.get("frame_id"))
                    matches = find(snapshot, **query)
                    last_coverage = snapshot["coverage"]
                    if state == "absent" and not matches:
                        if last_coverage["complete"]:
                            return None
                    elif state == "present" and matches:
                        if len(matches) != 1:
                            raise SelectionError(
                                "State query is ambiguous.",
                                count=len(matches),
                                query=query,
                            )
                        return matches[0]
                    await asyncio.sleep(interval)
        except TimeoutError as exc:
            raise WaitTimeout(
                "Semantic condition was not met.",
                query=query,
                state=state,
                last_coverage=last_coverage,
            ) from exc

    async def _hit(self, cdp: CDPSession, x: float, y: float, viewport: JSON) -> JSON:
        # DOM hit testing uses document coordinates; Input uses viewport coordinates.
        try:
            return await cdp.send(
                "DOM.getNodeForLocation",
                {
                    "x": int(x + viewport["pageX"]),
                    "y": int(y + viewport["pageY"]),
                    "includeUserAgentShadowDOM": True,
                },
            )
        except ProtocolError as exc:
            raise NotActionable("No hit-testable node at this point.") from exc

    async def _to_main_point(
        self, state: _Session, x: float, y: float
    ) -> tuple[float, float]:
        """Cross OOPIF boundaries, checking each frame's embedding for occlusion."""
        visited = set()
        while state.cdp.session_id != self.cdp.session_id:
            if state.root_frame in visited:
                raise UnsupportedOperation("Cycle in the frame ancestry map.")
            visited.add(state.root_frame)
            parent_id = self._frame_info.get(state.root_frame, {}).get("parent_id")
            parent_sid = self._frame_sessions.get(parent_id)
            parent = self._sessions.get(parent_sid)
            if parent is None:
                raise StaleReference("Frame ancestry changed; observe again.")
            owner = await parent.cdp.send(
                "DOM.getFrameOwner", {"frameId": state.root_frame}
            )
            await parent.cdp.send(
                "DOM.scrollIntoViewIfNeeded", {"backendNodeId": owner["backendNodeId"]}
            )
            box = (
                await parent.cdp.send(
                    "DOM.getBoxModel", {"backendNodeId": owner["backendNodeId"]}
                )
            )["model"]["content"]
            # Scale/translate are supported. Do not guess perspective/rotation geometry.
            if (
                abs(box[0] - box[6]) > 0.25
                or abs(box[2] - box[4]) > 0.25
                or abs(box[1] - box[3]) > 0.25
                or abs(box[5] - box[7]) > 0.25
                or box[2] <= box[0]
                or box[7] <= box[1]
            ):
                raise UnsupportedOperation(
                    "Rotated, mirrored or perspective-transformed cross-process frames are not supported."
                )
            size = self._value(
                await state.cdp.send(
                    "Runtime.evaluate",
                    {
                        "expression": "({width:innerWidth,height:innerHeight})",
                        "returnByValue": True,
                    },
                )
            )
            if not size or size["width"] <= 0 or size["height"] <= 0:
                raise NotActionable("Frame has no visible viewport.")
            x = box[0] + x * (box[2] - box[0]) / size["width"]
            y = box[1] + y * (box[7] - box[1]) / size["height"]
            metrics = await parent.cdp.send("Page.getLayoutMetrics")
            viewport = metrics["cssLayoutViewport"]
            if not (
                0 <= x < viewport["clientWidth"] and 0 <= y < viewport["clientHeight"]
            ):
                raise NotActionable(
                    "Frame click point is clipped by its parent viewport."
                )
            hit = await self._hit(parent.cdp, x, y, viewport)
            if hit.get("backendNodeId") != owner["backendNodeId"]:
                raise NotActionable("An ancestor frame is obscured by another element.")
            state = parent
        return x, y

    async def _click_point(
        self, record: _Reference, state: _Session, object_id: str
    ) -> tuple[float, float]:
        await state.cdp.send(
            "DOM.scrollIntoViewIfNeeded", {"backendNodeId": record.backend_id}
        )
        quads = (
            await state.cdp.send(
                "DOM.getContentQuads", {"backendNodeId": record.backend_id}
            )
        )["quads"]
        metrics = await state.cdp.send("Page.getLayoutMetrics")
        viewport = metrics["cssLayoutViewport"]
        if metrics["cssVisualViewport"].get("scale", 1) != 1:
            raise UnsupportedOperation(
                "Pinch-zoomed viewports are not supported by high-level click."
            )
        width, height = viewport["clientWidth"], viewport["clientHeight"]
        covering: JSON = {}
        for quad in quads:
            xs, ys = quad[0::2], quad[1::2]
            left, right = max(0, min(xs)), min(width, max(xs))
            top, bottom = max(0, min(ys)), min(height, max(ys))
            if right - left < 1 or bottom - top < 1:
                continue
            x, y = (left + right) / 2, (top + bottom) / 2
            try:
                hit = await self._hit(state.cdp, x, y, viewport)
            except NotActionable:
                continue
            matched = hit.get("backendNodeId") == record.backend_id
            if not matched:
                obj = (
                    await state.cdp.send(
                        "DOM.resolveNode", {"backendNodeId": hit["backendNodeId"]}
                    )
                )["object"].get("objectId")
                if obj:
                    try:
                        matched = bool(
                            await self._call(
                                state.cdp,
                                object_id,
                                js.CONTAINS,
                                arguments=[{"objectId": obj}],
                            )
                        )
                    except (JavaScriptError, ProtocolError):
                        pass
                    finally:
                        await state.cdp.send("Runtime.releaseObject", {"objectId": obj})
            if matched:
                return await self._to_main_point(state, x, y)
            covering = await self._ax_summary(state, hit.get("backendNodeId"))
        raise NotActionable(
            "No unobstructed, visible click point was found"
            + ("; something else is over the target." if covering else "."),
            **({"covering": covering} if covering else {}),
        )

    async def _ax_summary(self, state: _Session, backend_id: int | None) -> JSON:
        """Name what is over a target, so "something covers it" is actionable."""
        if backend_id is None:
            return {}
        try:
            nodes = (
                await state.cdp.send(
                    "Accessibility.getPartialAXTree",
                    {
                        "backendNodeId": backend_id,
                        "fetchRelatives": False,
                    },
                )
            )["nodes"]
        except ProtocolError:
            return {"backendNodeId": backend_id}
        node = next((n for n in nodes if n.get("backendDOMNodeId") == backend_id), None)
        if node is None:
            return {"backendNodeId": backend_id}
        return {
            "backendNodeId": backend_id,
            "role": str(node.get("role", {}).get("value", "")),
            "name": str(node.get("name", {}).get("value", ""))[:80],
        }

    async def click(self, ref: str | Node, *, button: str = "left") -> JSON:
        if button not in {"left", "right", "middle"}:
            raise ValueError("button must be left, right, or middle")
        async with self._action("click", ref) as receipt:
            async with self._resolved(ref) as (key, record, state, obj, status):
                if status["disabled"]:
                    raise NotActionable("Element is disabled.", ref=key)
                x, y = await self._click_point(record, state, obj)
                self._ref(key)
                receipt["may_have_executed"] = True
                pressed = False
                try:
                    await self.cdp.send(
                        "Input.dispatchMouseEvent",
                        {"type": "mouseMoved", "x": x, "y": y},
                    )
                    pressed = True
                    await self.cdp.send(
                        "Input.dispatchMouseEvent",
                        {
                            "type": "mousePressed",
                            "x": x,
                            "y": y,
                            "button": button,
                            "clickCount": 1,
                        },
                    )
                    await self.cdp.send(
                        "Input.dispatchMouseEvent",
                        {
                            "type": "mouseReleased",
                            "x": x,
                            "y": y,
                            "button": button,
                            "clickCount": 1,
                        },
                    )
                    pressed = False
                finally:
                    if pressed and not self.browser._connection.closed:
                        with contextlib.suppress(Exception):
                            await self.cdp.send(
                                "Input.dispatchMouseEvent",
                                {
                                    "type": "mouseReleased",
                                    "x": x,
                                    "y": y,
                                    "button": button,
                                    "clickCount": 1,
                                },
                                timeout=1,
                            )
        return copy.deepcopy(receipt)

    async def fill(self, ref: str | Node, text: str) -> JSON:
        if not isinstance(text, str):
            raise TypeError("text must be a string")
        async with self._action("fill", ref) as receipt:
            async with self._resolved(ref) as (key, record, state, obj, status):
                if status["disabled"] or status["readonly"] or not status["visible"]:
                    held = [
                        name
                        for name, value in (
                            ("disabled", status["disabled"]),
                            ("read-only", status["readonly"]),
                            ("not visible", not status["visible"]),
                        )
                        if value
                    ]
                    raise NotActionable(
                        f"Field is {' and '.join(held)}.",
                        ref=key,
                        disabled=status["disabled"],
                        readonly=status["readonly"],
                    )
                supported = (
                    status["tag"] == "textarea"
                    or status["editable"]
                    or (
                        status["tag"] == "input"
                        and status["type"]
                        in {"text", "search", "url", "tel", "email", "password"}
                    )
                )
                if not supported:
                    raise UnsupportedOperation(
                        "fill supports text-like inputs, textarea and contenteditable only.",
                        tag=status["tag"],
                        type=status["type"],
                    )
                receipt["may_have_executed"] = True
                if not await self._call(state.cdp, obj, js.SELECT_TEXT):
                    raise NotActionable("Could not focus and select the field.")
                if text:
                    await state.cdp.send("Input.insertText", {"text": text})
                else:
                    await self._key(state.cdp, "Backspace")
                actual = await self._call(state.cdp, obj, js.READ_VALUE)
                if actual != text:
                    raise BrowserError(
                        "Field value did not match after input; no retry was attempted.",
                        expected_length=len(text),
                        actual_length=len(str(actual)),
                    )
        return copy.deepcopy(receipt)

    async def _key(self, cdp: CDPSession, key: str) -> None:
        special = {
            "Enter": ("Enter", 13, "\r"),
            "Tab": ("Tab", 9, ""),
            "Escape": ("Escape", 27, ""),
            "Backspace": ("Backspace", 8, ""),
            "Delete": ("Delete", 46, ""),
            "ArrowLeft": ("ArrowLeft", 37, ""),
            "ArrowUp": ("ArrowUp", 38, ""),
            "ArrowRight": ("ArrowRight", 39, ""),
            "ArrowDown": ("ArrowDown", 40, ""),
            "Home": ("Home", 36, ""),
            "End": ("End", 35, ""),
            "PageUp": ("PageUp", 33, ""),
            "PageDown": ("PageDown", 34, ""),
            "Space": ("Space", 32, " "),
        }
        if key not in special:
            raise ValueError(
                "Unsupported key; use named keys or raw Input.dispatchKeyEvent for chords"
            )
        code, vk, text = special[key]
        params = {
            "key": " " if key == "Space" else key,
            "code": code,
            "windowsVirtualKeyCode": vk,
        }
        try:
            await cdp.send(
                "Input.dispatchKeyEvent", {"type": "keyDown", **params, "text": text}
            )
        finally:
            if not self.browser._connection.closed:
                await cdp.send(
                    "Input.dispatchKeyEvent", {"type": "keyUp", **params}, timeout=2
                )

    async def press(self, key: str, *, ref: str | Node | None = None) -> JSON:
        if key not in {
            "Enter",
            "Tab",
            "Escape",
            "Backspace",
            "Delete",
            "ArrowLeft",
            "ArrowUp",
            "ArrowRight",
            "ArrowDown",
            "Home",
            "End",
            "PageUp",
            "PageDown",
            "Space",
        }:
            raise ValueError(
                "Unsupported key; use named keys or raw Input.dispatchKeyEvent for chords"
            )
        async with self._action("press", ref) as receipt:
            if ref is None:
                receipt["may_have_executed"] = True
                await self._key(self.cdp, key)
            else:
                async with self._resolved(ref) as (refkey, record, state, obj, status):
                    if status["disabled"] or not status["visible"]:
                        raise NotActionable(
                            "Element cannot receive keyboard input.", ref=refkey
                        )
                    receipt["may_have_executed"] = True
                    await state.cdp.send(
                        "DOM.focus", {"backendNodeId": record.backend_id}
                    )
                    await self._key(state.cdp, key)
        return copy.deepcopy(receipt)

    async def scroll(
        self,
        *,
        dy: float = 600,
        dx: float = 0,
        x: float | None = None,
        y: float | None = None,
    ) -> JSON:
        if not all(math.isfinite(v) for v in (dx, dy)):
            raise ValueError("Scroll deltas must be finite")
        async with self._action("scroll") as receipt:
            metrics = await self.cdp.send("Page.getLayoutMetrics")
            viewport = metrics.get("cssLayoutViewport", metrics["layoutViewport"])
            x = viewport["clientWidth"] / 2 if x is None else x
            y = viewport["clientHeight"] / 2 if y is None else y
            if not all(math.isfinite(v) for v in (x, y)):
                raise ValueError("Scroll coordinates must be finite")
            receipt["may_have_executed"] = True
            await self.cdp.send(
                "Input.dispatchMouseEvent",
                {
                    "type": "mouseWheel",
                    "x": x,
                    "y": y,
                    "deltaX": dx,
                    "deltaY": dy,
                },
            )
        return copy.deepcopy(receipt)

    async def screenshot(
        self,
        path: str | Path | None = None,
        *,
        full_page: bool = False,
        max_pixels: int = 16_000_000,
    ) -> Path:
        self._check()
        if max_pixels < 1:
            raise ValueError("max_pixels must be positive")
        metrics = await self.cdp.send("Page.getLayoutMetrics")
        viewport = metrics.get("cssLayoutViewport", metrics["layoutViewport"])
        params: JSON = {
            "format": "png",
            "fromSurface": True,
            "captureBeyondViewport": full_page,
        }
        if full_page:
            size = metrics.get("cssContentSize", metrics["contentSize"])
            width, height = size["width"], size["height"]
            params["clip"] = {
                "x": size["x"],
                "y": size["y"],
                "width": width,
                "height": height,
                "scale": 1,
            }
        else:
            width, height = viewport["clientWidth"], viewport["clientHeight"]
        ratio = await self.evaluate("devicePixelRatio")
        if width * height * ratio * ratio > max_pixels:
            raise UnsupportedOperation(
                "Screenshot exceeds pixel budget; use a viewport capture or raise max_pixels."
            )
        data = (await self.cdp.send("Page.captureScreenshot", params))["data"]
        destination = (
            Path(path)
            if path is not None
            else Path(".browser-artifacts") / (uuid.uuid4().hex + ".png")
        )
        destination = destination.expanduser().resolve()
        if destination.suffix.lower() != ".png":
            raise ValueError("Screenshot path must end in .png")
        raw = base64.b64decode(data, validate=True)
        if _attach_image is not None:
            try:
                _attach_image(raw)
            except Exception:
                pass

        def write() -> None:
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(raw)

        await asyncio.to_thread(write)
        return destination

    async def close(self, *, allow_existing: bool = False) -> None:
        self._check()
        if not self.owned and not allow_existing:
            raise UnsupportedOperation(
                "This tab was not created by this connection; pass allow_existing=True to explicitly close it."
            )
        await self.browser.cdp.send("Target.closeTarget", {"targetId": self.target_id})
        self._invalidate(destroyed=True)
        await self._stop_tasks()
        self.browser._pages.pop(self.target_id, None)

    def __reduce_ex__(self, protocol: SupportsIndex, /) -> Any:
        raise TypeError(
            "Live pages cannot be saved; save page.descriptor() and ordinary observations."
        )
