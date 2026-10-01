"""Plain-data observation schemas, selection, and rendering. No browser I/O here."""

from __future__ import annotations

import json
from typing import Any, NotRequired, TypedDict

from .errors import SelectionError


class Node(TypedDict):
    id: str
    ref: str | None
    role: str
    name: str
    frame_id: str
    parent: str | None
    depth: int
    value: NotRequired[Any]
    href: NotRequired[str]
    disabled: NotRequired[bool]
    checked: NotRequired[Any]
    selected: NotRequired[bool]
    expanded: NotRequired[bool]
    readonly: NotRequired[bool]
    focused: NotRequired[bool]
    required: NotRequired[bool]
    level: NotRequired[int]
    attributes: NotRequired[dict[str, str]]
    name_truncated: NotRequired[bool]


class Observation(TypedDict):
    snapshot_id: str
    target_id: str
    url: str
    title: str
    captured_at: str
    capture_ms: float
    nodes: list[Node]
    frames: list[dict[str, Any]]
    coverage: dict[str, Any]


# Deliberately exclude value, style, inline handlers and arbitrary data attributes.
IDENTITY_ATTRIBUTES = (
    "id",
    "name",
    "type",
    "href",
    "role",
    "aria-label",
    "data-testid",
)


def attributes_from_snapshot(data: dict[str, Any]) -> dict[int, dict[str, str]]:
    strings = data.get("strings", [])
    result = {}
    for document in data.get("documents", []):
        nodes = document.get("nodes", {})
        for backend_id, attrs in zip(
            nodes.get("backendNodeId", []), nodes.get("attributes", [])
        ):
            pairs = {
                strings[attrs[i]]: strings[attrs[i + 1]]
                for i in range(0, len(attrs), 2)
            }
            result[backend_id] = {
                k: pairs[k] for k in IDENTITY_ATTRIBUTES if k in pairs
            }
    return result


def attributes_from_node(node: dict[str, Any]) -> dict[str, str]:
    flat = node.get("attributes", [])
    attrs = dict(zip(flat[::2], flat[1::2]))
    return {k: attrs[k] for k in IDENTITY_ATTRIBUTES if k in attrs}


def ax_properties(node: dict[str, Any]) -> dict[str, Any]:
    return {
        p["name"]: p.get("value", {}).get("value") for p in node.get("properties", [])
    }


def walk_ax(
    nodes: list[dict[str, Any]],
) -> list[tuple[dict[str, Any], str | None, int]]:
    """Reorder Chrome's breadth-first response into reading order, keeping context."""
    by_id = {n["nodeId"]: n for n in nodes}
    roots = [n for n in nodes if n.get("parentId") not in by_id]
    stack = [(n, None, 0) for n in reversed(roots)]
    seen = set()
    result = []
    while stack:
        node, parent, depth = stack.pop()
        key = node["nodeId"]
        if key in seen:
            continue
        seen.add(key)
        role = node.get("role", {}).get("value", "")
        name = node.get("name", {}).get("value", "")
        keep = not node.get("ignored") and role != "InlineTextBox"
        if role in ("none", "generic", "LabelText") and not name:
            keep = False
        if keep:
            result.append((node, parent, depth))
        for child in reversed(node.get("childIds", [])):
            if child in by_id:
                stack.append((by_id[child], key if keep else parent, depth + int(keep)))
    return result


def find(
    observation: Observation,
    *,
    role: str | None = None,
    name: str | None = None,
    text: str | None = None,
    frame_id: str | None = None,
    exact: bool = True,
    **fields: Any,
) -> list[Node]:
    """Pure selection. Exact names are case-sensitive; text is a substring filter."""
    result = []
    for node in observation["nodes"]:
        if role is not None and node["role"] != role:
            continue
        if frame_id is not None and node["frame_id"] != frame_id:
            continue
        if name is not None and not (
            node["name"] == name if exact else name in node["name"]
        ):
            continue
        if (
            text is not None
            and text not in node["name"]
            and text not in str(node.get("value", ""))
        ):
            continue
        if any(node.get(k) != v for k, v in fields.items()):
            continue
        result.append(node)
    return result


def one(observation: Observation, **query: Any) -> Node:
    """Require exactly one match; never choose the first ambiguous element."""
    matches = find(observation, **query)
    if len(matches) != 1:
        raise SelectionError(
            f"Expected one node, found {len(matches)}.",
            query=query,
            matches=[
                {
                    "ref": n["ref"],
                    "role": n["role"],
                    "name": n["name"],
                    "frame_id": n["frame_id"],
                }
                for n in matches[:10]
            ],
            observation_complete=observation["coverage"].get("complete", False),
        )
    return matches[0]


def render(observation: Observation, *, max_chars: int = 8000) -> str:
    """Bounded, escaped text view. The input observation is never changed."""
    if max_chars < 128:
        raise ValueError("max_chars must be at least 128")

    def quote(value: Any) -> str:
        return json.dumps(value, ensure_ascii=False)

    lines = [f"Snapshot {observation['snapshot_id']} | {quote(observation['url'])}"]
    if not observation["coverage"].get("complete"):
        lines.append(
            "COVERAGE INCOMPLETE: " + quote(observation["coverage"].get("warnings", []))
        )
    by_id = {n["id"]: n for n in observation["nodes"]}
    for node in observation["nodes"]:
        parent = by_id.get(node["parent"])
        if node["role"] == "text" and parent and parent["name"] == node["name"]:
            continue
        label = f"[{node['ref']}]" if node["ref"] else "[-]"
        line = f"{'  ' * min(node['depth'], 5)}{label} {node['role']} {quote(node['name'])}"
        for key in (
            "value",
            "href",
            "disabled",
            "checked",
            "selected",
            "expanded",
            "required",
        ):
            if key in node:
                line += f" {key}={quote(node[key])}"
        if node.get("name_truncated"):
            line += " [name truncated]"
        if len(observation["frames"]) > 1:
            line += f" frame={node['frame_id']}"
        lines.append(line)
    text = "\n".join(lines)
    if len(text) <= max_chars:
        return text
    suffix = "\n[RENDER TRUNCATED; structured observation is unchanged]"
    return text[: max_chars - len(suffix)] + suffix
