"""Minimal line-delimited JSON-RPC MCP server used by mcp_integration.py."""

import json
import os
import sys
import time
from pathlib import Path

TOOLS = [
    {
        "name": "echo",
        "description": "Echo one message back",
        "inputSchema": {
            "type": "object",
            "required": ["message"],
            "properties": {"message": {"type": "string"}},
        },
    }
]


# Optional test controls: `delay` holds the handshake for that many seconds
# and `tools` replaces the catalogue, without changing the server's config.
CONTROL = Path(os.environ.get("FAKE_MCP_CONTROL") or "/nonexistent")


def control(name):
    path = CONTROL / name
    return path.read_text() if path.exists() else None


def reply(id, result=None, error=None):
    body = {"jsonrpc": "2.0", "id": id}
    body["error" if error else "result"] = error or result
    sys.stdout.write(json.dumps(body) + chr(10))
    sys.stdout.flush()


for line in sys.stdin:
    message = json.loads(line) if line.strip() else {}
    method, id = message.get("method"), message.get("id")
    if id is None:
        continue
    if method == "initialize":
        time.sleep(float(control("delay") or 0))
        reply(
            id,
            {
                "protocolVersion": "2025-06-18",
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "fake", "version": "1"},
            },
        )
    elif method == "tools/list":
        tools = control("tools")
        reply(id, {"tools": json.loads(tools) if tools else TOOLS})
    elif method == "tools/call":
        arguments = message["params"].get("arguments", {})
        if arguments.get("message") == "fail":
            reply(id, error={"code": -32000, "message": "the tool exploded"})
            continue
        reply(
            id,
            {
                "content": [
                    {
                        "type": "text",
                        "text": json.dumps(
                            {
                                "echoed": arguments.get("message"),
                                "secret": os.environ.get("FAKE_SECRET"),
                                "ambient": os.environ.get("ALBEDO_MCP_AMBIENT"),
                            }
                        ),
                    }
                ]
            },
        )
    elif method == "ping":
        reply(id, {})
    else:
        reply(id, error={"code": -32601, "message": "method not found"})

Path(os.environ["FAKE_MCP_CLOSED"]).write_text("closed")
