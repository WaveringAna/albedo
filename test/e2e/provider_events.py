"""Scripted upstream events for real-daemon workflows. No daemon wire fixtures."""


def chat_events(reply, arguments, call_id, chunk_size):
    if reply.reasoning:
        yield (
            {
                "id": "fixture",
                "choices": [
                    {
                        "index": 0,
                        "delta": {"reasoning_content": reply.reasoning},
                        "finish_reason": None,
                    }
                ],
            }
        )
    if reply.kind == "python":
        for offset in range(0, len(arguments), chunk_size):
            tool_call: dict[str, object] = {
                "index": 0,
                "function": {"arguments": arguments[offset : offset + chunk_size]},
            }
            if offset == 0:
                tool_call.update(
                    {
                        "id": call_id,
                        "type": "function",
                        "function": {
                            "name": reply.tool_name,
                            "arguments": arguments[:chunk_size],
                        },
                    }
                )
            delta = {"tool_calls": [tool_call]}
            yield (
                {
                    "id": "fixture",
                    "choices": [{"index": 0, "delta": delta, "finish_reason": None}],
                }
            )
        yield (
            {
                "id": "fixture",
                "choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}],
            }
        )
    else:
        for offset in range(0, len(reply.value), chunk_size):
            yield (
                {
                    "id": "fixture",
                    "choices": [
                        {
                            "index": 0,
                            "delta": {
                                "content": reply.value[offset : offset + chunk_size]
                            },
                            "finish_reason": None,
                        }
                    ],
                }
            )
        yield (
            {
                "id": "fixture",
                "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
            }
        )


def responses_events(reply, arguments, call_id, chunk_size):
    yield ({"type": "response.created", "response": {"id": "fixture"}})
    output = []
    if reply.reasoning:
        yield (
            {
                "type": "response.reasoning_summary_text.delta",
                "output_index": 0,
                "summary_index": 0,
                "delta": reply.reasoning,
            }
        )
        output.append(
            {
                "id": "reasoning",
                "type": "reasoning",
                "summary": [{"type": "summary_text", "text": reply.reasoning}],
            }
        )
    if reply.kind == "python":
        yield (
            {
                "type": "response.output_item.added",
                "output_index": 0,
                "item": {
                    "id": "call",
                    "type": "function_call",
                    "call_id": call_id,
                    "name": reply.tool_name,
                },
            }
        )
        for offset in range(0, len(arguments), chunk_size):
            yield (
                {
                    "type": "response.function_call_arguments.delta",
                    "output_index": 0,
                    "delta": arguments[offset : offset + chunk_size],
                }
            )
        output.append(
            {
                "id": "call",
                "type": "function_call",
                "call_id": call_id,
                "name": reply.tool_name,
                "arguments": arguments,
                "status": "completed",
            }
        )
    else:
        for offset in range(0, len(reply.value), chunk_size):
            yield (
                {
                    "type": "response.output_text.delta",
                    "output_index": 0,
                    "content_index": 0,
                    "delta": reply.value[offset : offset + chunk_size],
                }
            )
        output.append(
            {
                "id": "message",
                "type": "message",
                "role": "assistant",
                "status": "completed",
                "content": [
                    {
                        "type": "output_text",
                        "text": reply.value,
                        "annotations": [],
                    }
                ],
            }
        )
    completed = {"id": "fixture", "status": "completed", "output": output}
    if reply.usage is not None:
        completed["usage"] = reply.usage
    yield ({"type": "response.completed", "response": completed})
