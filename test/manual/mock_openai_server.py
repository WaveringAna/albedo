"""A local OpenAI-compatible streaming server for transport benchmarks.

Run explicitly: python3 test/manual/mock_openai_server.py [port] [cert key]
The base URL picks the stream: http://127.0.0.1:PORT/<rate>/<tokens>/v1
streams <tokens> text deltas at <rate> tokens per second (0 for as fast as
the socket takes them), one SSE event per write, over HTTP/1.1 chunked
encoding on kept-alive connections. With a certificate and key it serves
https instead. Any request to /timings returns the send time (ns,
CLOCK_REALTIME) of every delta of the last stream, so a client can compute
per-token latency.
"""

import asyncio
import json
import ssl
import sys
import time

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
timings: list[int] = []


def sse(name: str | None, payload: object) -> bytes:
    data = json.dumps(payload, separators=(",", ":"))
    head = f"event: {name}\n" if name else ""
    return f"{head}data: {data}\n\n".encode()


def chunked(body: bytes) -> bytes:
    return b"%x\r\n%s\r\n" % (len(body), body)


def message(text: str, status: str) -> dict:
    content = [{"type": "output_text", "text": text, "annotations": [], "logprobs": []}]
    return {
        "id": "msg_0001",
        "type": "message",
        "status": status,
        "role": "assistant",
        "content": content,
    }


def responses(tokens: list[str]):
    created = {
        "id": "resp_0001",
        "object": "response",
        "status": "in_progress",
        "model": "mock",
        "output": [],
    }
    yield (
        None,
        sse(
            "response.created",
            {"type": "response.created", "sequence_number": 0, "response": created},
        ),
    )
    added = {
        "type": "response.output_item.added",
        "sequence_number": 1,
        "output_index": 0,
        "item": message("", "in_progress"),
    }
    yield None, sse("response.output_item.added", added)
    for i, token in enumerate(tokens):
        delta = {
            "type": "response.output_text.delta",
            "sequence_number": i + 2,
            "item_id": "msg_0001",
            "output_index": 0,
            "content_index": 0,
            "delta": token,
            "logprobs": [],
            "obfuscation": "x7Qp2LmN",
        }
        yield i, sse("response.output_text.delta", delta)
    full = message("".join(tokens), "completed")
    done = {
        "type": "response.output_item.done",
        "sequence_number": len(tokens) + 2,
        "output_index": 0,
        "item": full,
    }
    yield None, sse("response.output_item.done", done)
    usage = {
        "input_tokens": 1200,
        "input_tokens_details": {"cached_tokens": 1000},
        "output_tokens": len(tokens),
        "output_tokens_details": {"reasoning_tokens": 0},
        "total_tokens": 1200 + len(tokens),
    }
    final = {**created, "status": "completed", "output": [full], "usage": usage}
    yield (
        None,
        sse(
            "response.completed",
            {
                "type": "response.completed",
                "sequence_number": len(tokens) + 3,
                "response": final,
            },
        ),
    )


def chat(tokens: list[str]):
    def chunk(delta: dict, finish: str | None) -> dict:
        choice = {"index": 0, "delta": delta, "logprobs": None, "finish_reason": finish}
        return {
            "id": "chatcmpl-0001",
            "object": "chat.completion.chunk",
            "created": 1700000000,
            "model": "mock",
            "service_tier": "default",
            "system_fingerprint": "fp_0001",
            "choices": [choice],
            "usage": None,
            "obfuscation": "x7Qp2LmN",
        }

    yield (
        None,
        sse(None, chunk({"role": "assistant", "content": "", "refusal": None}, None)),
    )
    for i, token in enumerate(tokens):
        yield i, sse(None, chunk({"content": token}, None))
    yield None, sse(None, chunk({}, "stop"))
    usage = {
        "prompt_tokens": 1200,
        "completion_tokens": len(tokens),
        "prompt_tokens_details": {"cached_tokens": 1000},
    }
    yield (
        None,
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
    yield None, b"data: [DONE]\n\n"


async def stream(writer: asyncio.StreamWriter, path: str) -> None:
    _, rate, count, *_ = path.split("/")
    tokens = [WORDS[i % len(WORDS)] for i in range(int(count))]
    events = chat(tokens) if path.endswith("/chat/completions") else responses(tokens)
    head = "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ntransfer-encoding: chunked\r\n\r\n"
    writer.write(head.encode())
    timings.clear()
    interval = 1 / float(rate) if float(rate) > 0 else 0.0
    started = time.monotonic()
    for index, event in events:
        if index is not None and interval:
            delay = started + index * interval - time.monotonic()
            if delay > 0:
                await asyncio.sleep(delay)
        if index is not None:
            timings.append(time.time_ns())
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
            if path.endswith("/timings"):
                body = json.dumps(timings).encode()
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
