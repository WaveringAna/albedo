"""Bounded frame capture and reference construction. Page owns retention and lifetime."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from .errors import ProtocolError
from .transport import CDPSession, JSON
from .observation import Node, attributes_from_snapshot, ax_properties, walk_ax


@dataclass
class FrameSession:
    cdp: CDPSession
    target_id: str
    root_frame: str = ""
    generation: int = 0
    ready: bool = False
    error: str | None = None


@dataclass(frozen=True)
class Reference:
    session_id: str
    frame_id: str
    generation: int
    backend_id: int
    role: str
    name: str
    attributes: dict[str, str]


@dataclass(frozen=True)
class CaptureLimits:
    snapshot_id: str
    max_nodes: int
    max_text: int
    max_depth: int


@dataclass
class CapturedFrames:
    rows: list[Node]
    references: dict[str, Reference]
    warnings: list[JSON]


async def capture_frames(
    frames: list[dict[str, Any]],
    sessions: dict[str, FrameSession],
    limits: CaptureLimits,
) -> CapturedFrames:
    warnings: list[JSON] = []
    dom_by_session = {}
    refs: dict[str, Reference] = {}
    rows: list[Node] = []
    for frame in frames:
        if len(rows) >= limits.max_nodes:
            warnings.append(
                {"kind": "frame_omitted_by_node_limit", "frame_id": frame["id"]}
            )
            continue
        sid = frame["session_id"]
        state = sessions[sid]
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
                        "depth": limits.max_depth,
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
            warnings.append({"kind": "depth_or_tree_omission", "frame_id": frame["id"]})
        ids: dict[str, str] = {}
        for ax, parent, depth in nodes:
            if len(rows) >= limits.max_nodes:
                warnings.append({"kind": "node_limit", "frame_id": frame["id"]})
                break
            row_id = f"{limits.snapshot_id}:{len(rows) + 1}"
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
                "name": name[: limits.max_text],
                "frame_id": frame["id"],
                "parent": ids.get(parent),
                "depth": depth,
            }
            if len(name) > limits.max_text:
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
                if (
                    isinstance(row["value"], str)
                    and len(row["value"]) > limits.max_text
                ):
                    row["value"] = row["value"][: limits.max_text]
                    warnings.append({"kind": "value_truncated", "node": row_id})
            if ref and backend is not None:
                refs[ref] = Reference(
                    sid, frame["id"], generation, backend, role, name, dict(attrs)
                )
            rows.append(row)
        if state.generation != generation:
            warnings.append(
                {"kind": "document_changed_during_capture", "frame_id": frame["id"]}
            )
    return CapturedFrames(rows, refs, warnings)
