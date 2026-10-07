"""A local streaming model server for transport benchmarks.

Run explicitly: python3 test/manual/mock_openai_server.py [port] [cert key]
The base URL picks the stream: http://127.0.0.1:PORT/<rate>/<tokens>[/<option>...]/v1
streams <tokens> deltas at <rate> per second (0 for as fast as the socket
takes them), one SSE event per write, over HTTP/1.1 chunked encoding on
kept-alive connections. Options: t<percent> streams that share of the
deltas as one python tool call's arguments after the text, and s<id> names
the stream so parallel streams keep separate timings. The route picks the
wire format: /responses, /chat/completions, or Anthropic's /messages. With
a certificate and key it serves https instead. A request to /timings/<id>
(or /timings for stream 0) returns the send time (ns, CLOCK_REALTIME) of
every delta of that stream's last response, so a client can compute
per-token latency.
"""

import asyncio
import json
import random
import ssl
import sys
import time
from collections.abc import Iterator

WORDS = [
    "the",
    " quick",
    " brown",
    " fox",
    " jumps",
    " over",
    " lazy",
    " dog",
    ".",
    "\n",
]
timings: dict[str, list[int]] = {}

# Each stream yields (is_delta, event); deltas are paced and timed.
Events = Iterator[tuple[bool, bytes]]


def sse(name: str | None, payload: object) -> bytes:
    data = json.dumps(payload, separators=(",", ":"))
    head = f"event: {name}\n" if name else ""
    return f"{head}data: {data}\n\n".encode()


def chunked(body: bytes) -> bytes:
    return b"%x\r\n%s\r\n" % (len(body), body)


def split(text: str, parts: int) -> list[str]:
    """text in at most parts nonempty pieces of about equal size."""
    if parts <= 0:
        return []
    size = -(-len(text) // parts)
    chunks = [text[i * size : (i + 1) * size] for i in range(parts)]
    return [chunk for chunk in chunks if chunk] or [text]


def plan(count: int, tool_percent: int) -> tuple[list[str], list[str], str]:
    """count deltas: text words, then tool_percent of them as pieces of one
    python call's arguments, and those arguments whole."""
    calls = count * tool_percent // 100
    words = [WORDS[i % len(WORDS)] for i in range(count - calls)]
    code = " ".join(f"print({i})" for i in range(max(calls, 1)))
    arguments = json.dumps({"code": code})
    return words, split(arguments, calls) if calls else [], arguments


def message(text: str, status: str) -> dict:
    content = [{"type": "output_text", "text": text, "annotations": [], "logprobs": []}]
    return {
        "id": "msg_0001",
        "type": "message",
        "status": status,
        "role": "assistant",
        "content": content,
    }


def function_call(arguments: str, status: str) -> dict:
    return {
        "id": "fc_0001",
        "type": "function_call",
        "status": status,
        "call_id": "call_0001",
        "name": "python",
        "arguments": arguments,
    }


def responses(words: list[str], calls: list[str], arguments: str) -> Events:
    sequence = iter(range(1_000_000))

    def event(kind: str, **fields: object) -> bytes:
        return sse(kind, {"type": kind, "sequence_number": next(sequence), **fields})

    created = {
        "id": "resp_0001",
        "object": "response",
        "status": "in_progress",
        "model": "mock",
        "output": [],
    }
    yield False, event("response.created", response=created)
    yield (
        False,
        event(
            "response.output_item.added",
            output_index=0,
            item=message("", "in_progress"),
        ),
    )
    for word in words:
        yield (
            True,
            event(
                "response.output_text.delta",
                item_id="msg_0001",
                output_index=0,
                content_index=0,
                delta=word,
                logprobs=[],
                obfuscation="x7Qp2LmN",
            ),
        )
    output = [message("".join(words), "completed")]
    yield False, event("response.output_item.done", output_index=0, item=output[0])
    if calls:
        yield (
            False,
            event(
                "response.output_item.added",
                output_index=1,
                item=function_call("", "in_progress"),
            ),
        )
        for chunk in calls:
            yield (
                True,
                event(
                    "response.function_call_arguments.delta",
                    item_id="fc_0001",
                    output_index=1,
                    delta=chunk,
                    obfuscation="x7Qp2LmN",
                ),
            )
        output.append(function_call(arguments, "completed"))
        yield False, event("response.output_item.done", output_index=1, item=output[1])
    usage = {
        "input_tokens": 1200,
        "input_tokens_details": {"cached_tokens": 1000},
        "output_tokens": len(words) + len(calls),
        "output_tokens_details": {"reasoning_tokens": 0},
    }
    final = {**created, "status": "completed", "output": output, "usage": usage}
    yield False, event("response.completed", response=final)


def chat(words: list[str], calls: list[str], _arguments: str) -> Events:
    def chunk(delta: dict, finish: str | None = None) -> bytes:
        choice = {"index": 0, "delta": delta, "logprobs": None, "finish_reason": finish}
        return sse(
            None,
            {
                "id": "chatcmpl-0001",
                "object": "chat.completion.chunk",
                "created": 1700000000,
                "model": "mock",
                "service_tier": "default",
                "system_fingerprint": "fp_0001",
                "choices": [choice],
                "usage": None,
                "obfuscation": "x7Qp2LmN",
            },
        )

    yield False, chunk({"role": "assistant", "content": "", "refusal": None})
    for word in words:
        yield True, chunk({"content": word})
    if calls:
        opened = {
            "index": 0,
            "id": "call_0001",
            "type": "function",
            "function": {"name": "python", "arguments": ""},
        }
        yield False, chunk({"tool_calls": [opened]})
        for piece in calls:
            yield (
                True,
                chunk({"tool_calls": [{"index": 0, "function": {"arguments": piece}}]}),
            )
    yield False, chunk({}, "tool_calls" if calls else "stop")
    usage = {
        "prompt_tokens": 1200,
        "completion_tokens": len(words) + len(calls),
        "prompt_tokens_details": {"cached_tokens": 1000},
    }
    yield (
        False,
        sse(
            None,
            {
                "id": "chatcmpl-0001",
                "object": "chat.completion.chunk",
                "choices": [],
                "usage": usage,
            },
        ),
    )
    yield False, b"data: [DONE]\n\n"


def messages(words: list[str], calls: list[str], _arguments: str) -> Events:
    def event(kind: str, **fields: object) -> bytes:
        return sse(kind, {"type": kind, **fields})

    start = {
        "id": "msg_0001",
        "type": "message",
        "role": "assistant",
        "model": "mock",
        "content": [],
        "stop_reason": None,
        "usage": {
            "input_tokens": 200,
            "cache_read_input_tokens": 1000,
            "output_tokens": 1,
        },
    }
    yield False, event("message_start", message=start)
    yield (
        False,
        event(
            "content_block_start", index=0, content_block={"type": "text", "text": ""}
        ),
    )
    for word in words:
        yield (
            True,
            event(
                "content_block_delta",
                index=0,
                delta={"type": "text_delta", "text": word},
            ),
        )
    yield False, event("content_block_stop", index=0)
    if calls:
        block = {"type": "tool_use", "id": "toolu_0001", "name": "python", "input": {}}
        yield False, event("content_block_start", index=1, content_block=block)
        for piece in calls:
            yield (
                True,
                event(
                    "content_block_delta",
                    index=1,
                    delta={"type": "input_json_delta", "partial_json": piece},
                ),
            )
        yield False, event("content_block_stop", index=1)
    delta = {"stop_reason": "tool_use" if calls else "end_turn", "stop_sequence": None}
    yield (
        False,
        event(
            "message_delta",
            delta=delta,
            usage={"output_tokens": len(words) + len(calls)},
        ),
    )
    yield False, event("message_stop")


async def stream(writer: asyncio.StreamWriter, path: str) -> None:
    segments = path.split("/")
    rate, count = float(segments[1]), int(segments[2])
    options = segments[3 : segments.index("v1")]
    name = next((option[1:] for option in options if option.startswith("s")), "0")
    share = int(next((option[1:] for option in options if option.startswith("t")), "0"))
    wire = (
        chat
        if path.endswith("/chat/completions")
        else messages
        if path.endswith("/messages")
        else responses
    )
    head = "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ntransfer-encoding: chunked\r\n\r\n"
    writer.write(head.encode())
    sent = timings[name] = []
    interval = 1 / rate if rate > 0 else 0.0
    # A random phase, so parallel streams do not all send in the same instant.
    started = time.monotonic() + random.random() * interval
    for is_delta, event in wire(*plan(count, share)):
        if is_delta and interval:
            delay = started + len(sent) * interval - time.monotonic()
            if delay > 0:
                await asyncio.sleep(delay)
        if is_delta:
            sent.append(time.time_ns())
        writer.write(chunked(event))
        await writer.drain()
    writer.write(b"0\r\n\r\n")
    await writer.drain()


async def handle(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    try:
        while request := (await reader.readuntil(b"\r\n")).decode():
            _, path, _ = request.split(" ", 2)
            length = 0
            while (line := await reader.readuntil(b"\r\n")) != b"\r\n":
                name, _, value = line.decode().partition(":")
                if name.strip().lower() == "content-length":
                    length = int(value)
            await reader.readexactly(length)
            if path.startswith("/timings"):
                body = json.dumps(
                    timings.get(path.removeprefix("/timings").strip("/") or "0", [])
                ).encode()
                head = f"HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {len(body)}\r\n\r\n"
                writer.write(head.encode() + body)
            else:
                await stream(writer, path)
            await writer.drain()
    except (ConnectionError, asyncio.IncompleteReadError):
        pass
    finally:
        writer.close()


async def main(port: int, tls: list[str]) -> None:
    context = None
    if tls:
        context = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
        context.load_cert_chain(*tls)
    server = await asyncio.start_server(handle, "127.0.0.1", port, ssl=context)
    print(f"listening on {'https' if tls else 'http'}://127.0.0.1:{port}", flush=True)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main(int(sys.argv[1]) if len(sys.argv) > 1 else 8765, sys.argv[2:4]))
