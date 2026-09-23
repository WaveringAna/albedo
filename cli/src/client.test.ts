import assert from "node:assert/strict"
import test from "node:test"
import { createChatClient, WorkspaceMissingError, type StreamEvent } from "./client.js"

const page=(cursor:number,events:unknown[]) => `data: ${JSON.stringify({cursor,events})}\n\n`
test("send returns the daemon's authoritative queued state", async () => {
  const responses = [false, true]
  const client = createChatClient({ baseUrl: "http://localhost", agentId: "session", fetchImpl: async () =>
    new Response(JSON.stringify({ ok: true, queued: responses.shift() }), { status: 202 }) })
  assert.deepEqual(await client.send("first"), { ok: true, queued: false })
  assert.deepEqual(await client.send("steer"), { ok: true, queued: true })
  const client2 = createChatClient({ baseUrl: "http://localhost", agentId: "session", fetchImpl: async () =>
    new Response(page(1, [{ type: "compacted", evicted: 12, summary: "facts" }, { type: "compacted", evicted: -1, summary: "no" }, { type: "compacted", evicted: 5, summary: "x".repeat(60_001) }]), { headers: { "content-type": "text/event-stream" } }) })
  const compacted: StreamEvent[] = []
  await client2.stream({ onEvent: event => compacted.push(event) })
  assert.deepEqual(compacted, [{ type: "compacted", evicted: 12, summary: "facts" }])

  const older = createChatClient({ baseUrl: "http://localhost", agentId: "session", fetchImpl: async () => new Response(null, { status: 202 }) })
  assert.deepEqual(await older.send("legacy"), { ok: true, queued: false })
})

test("daemon thinking events stay a distinct type from assistant text",async()=>{
  const page=`data: ${JSON.stringify({cursor:1,events:[{type:"thinking",text:"weighing options"},{type:"text",text:"answer"},{type:"message",role:"assistant",text:"answer"}]})}\n\n`
  const events:StreamEvent[]=[]
  const client=createChatClient({baseUrl:"http://localhost",agentId:"session",fetchImpl:async()=>new Response(page,{headers:{"content-type":"text/event-stream"}})})
  await client.stream({onEvent:event=>events.push(event)})
  assert.deepEqual(events,[{type:"thinking",text:"weighing options"},{type:"text",text:"answer"},{type:"message",role:"assistant",text:"answer"}])
})

test("daemon pages preserve live Python previews, native tool args, traces and reconnect cursors",async()=>{
  const urls:string[]=[]
  const code="from pathlib import Path\nPath('demo.py').write_text('hello')"
  const args=JSON.stringify({code,timeout_ms:1000})
  const frames=page(1,[{type:"reset"},{type:"user",text:"work",source:"chat",triggeredAt:""}])
    +page(2,[{type:"arguments_delta",callId:"call",text:args.slice(0,40)}])
    +page(3,[{type:"arguments_delta",callId:"call",text:args.slice(40)}])
    +page(4,[{type:"tool",name:"python",args,result:"ok",trace:{activities:[{kind:"read",target:"demo.py"}],changes:[]}},{type:"message",role:"assistant",text:"done"}])
  const events:StreamEvent[]=[]
  const client=createChatClient({baseUrl:"http://localhost",agentId:"session",fetchImpl:async url=>{
    urls.push(String(url))
    return new Response(urls.length===1?frames:page(4,[]),{headers:{"content-type":"text/event-stream"}})
  }})
  await client.stream({onEvent:event=>events.push(event)})
  await client.stream({onEvent:event=>events.push(event)})
  assert.equal(events[0]?.type,"reset")
  assert.ok(events.some(event=>event.type==="tool_progress" && event.progress?.code?.text.includes("demo.py")))
  const tool=events.find(event=>event.type==="tool")
  assert.equal(tool?.type==="tool" && tool.args.code,code)
  assert.equal(tool?.type==="tool" && tool.trace?.activities[0]?.target,"demo.py")
  assert.deepEqual(events.at(-1),{type:"message",role:"assistant",text:"done"})
  assert.match(urls[1]!,/sessions\/session\/stream\?after_seq=4$/)
})

test("completed call previews release state without losing another call or reconnecting deltas", async () => {
  const a = JSON.stringify({ code: "read('first.py')" })
  const b = JSON.stringify({ code: "read('second.py')" })
  let requests = 0
  const frames = [page(1, [
    { type: "arguments_delta", callId: "a", text: a },
    { type: "arguments_delta", callId: "b", text: b.slice(0, 15) },
    { type: "tool", callId: "a", name: "python", args: a, result: "done" },
  ]), page(2, [
    { type: "arguments_delta", callId: "b", text: b.slice(15) },
    { type: "tool_progress", progress: { callId: "b", name: "python", phase: "running" } },
    { type: "tool", callId: "b", name: "python", args: b, result: "done" },
  ])]
  const client = createChatClient({ baseUrl: "http://localhost", agentId: "session",
    fetchImpl: async () => new Response(frames[requests++], { headers: { "content-type": "text/event-stream" } }),
  })
  const events: StreamEvent[] = []
  const options = { onEvent: (event: StreamEvent) => { events.push(event) } }
  await client.stream(options)
  await client.stream(options)
  assert(events.some(event => event.type === "tool_progress" && event.progress?.code?.text === "read('second.py')"))
  const running = events.findIndex(event => event.type === "tool_progress" && event.progress?.phase === "running")
  assert.deepEqual(events[running-1], { type: "tool_progress", progress: null })
  assert.equal(events.at(-1)?.type, "tool")
})


test("usage preserves the original completion time and model through a reset snapshot", async () => {
  const usage = { type: "usage", model: "gpt-5", promptTokens: 1000, completionTokens: 100, totalTokens: 1100, cachedPromptTokens: 800, recordedAt: 1_700_000_000_000 }
  const client = createChatClient({ baseUrl: "http://localhost", agentId: "session", fetchImpl: async () => new Response(page(3, [{ type: "reset" }, usage]), { headers: { "content-type": "text/event-stream" } }) })
  const events: StreamEvent[] = []
  await client.stream({ onEvent: event => events.push(event) })
  const observed = events.find(event => event.type === "usage")
  assert.equal(observed?.recordedAt, usage.recordedAt)
  assert.equal(observed?.model, usage.model)
  assert.equal(observed?.cachedPromptTokens, 800)
  assert.equal(observed?.promptTokens, 1000)
})


test("message timestamps survive the wire without inventing missing or invalid dates", async () => {
  const message = { type: "message", role: "assistant", text: "answer" }
  const user = { type: "user", text: "question", source: "chat", triggeredAt: "", clientId: "sender", timestamp: 1_700_000_000_000 }
  const events: StreamEvent[] = []
  const client = createChatClient({ baseUrl: "http://localhost", agentId: "session", fetchImpl: async () => new Response(page(1, [user, { ...message, timestamp: user.timestamp + 1000 }, message, { ...message, timestamp: "wrong" }]), { headers: { "content-type": "text/event-stream" } }) })
  await client.stream({ onEvent: event => events.push(event) })
  assert.deepEqual(events, [user, { ...message, timestamp: user.timestamp + 1000 }, message, message])
})

test("unfinished argument previews are bounded across reconnects and recover from a snapshot", async () => {
  for (const [count, text] of [[33, '{"code":"'], [3, 'x'.repeat(700_000)]] as const) {
    const urls: string[] = []
    const client = createChatClient({ baseUrl: "http://localhost", agentId: "session", fetchImpl: async url => {
      urls.push(String(url))
      const cursor = urls.length
      return new Response(page(cursor, cursor <= count
        ? [{ type: "arguments_delta", callId: `call-${cursor}`, text }]
        : [{ type: "reset" }, { type: "message", role: "assistant", text: "recovered" }]))
    } })
    for (let i = 1; i < count; i++) await client.stream({ onEvent: () => {} })
    await assert.rejects(client.stream({ onEvent: () => {} }), /previews exceed client limit/)
    const events: StreamEvent[] = []
    await client.stream({ onEvent: event => events.push(event) })
    assert.match(urls.at(-1)!, /after_seq=-1$/)
    assert.deepEqual(events.at(-1), { type: "message", role: "assistant", text: "recovered" })
  }
})

test("detaching drops argument previews and resets the reconnect cursor", async () => {
  const controller = new AbortController()
  const urls: string[] = []
  const client = createChatClient({ baseUrl: "http://localhost", agentId: "session", fetchImpl: async url => {
    urls.push(String(url))
    return new Response(page(urls.length, [{ type: "arguments_delta", callId: "same", text: JSON.stringify({ code: urls.length === 1 ? "old()" : "new()" }) }]))
  } })
  await client.stream({ signal: controller.signal, onEvent: event => {
    if (event.type === "tool_progress" && event.progress) controller.abort()
  } })
  const events: StreamEvent[] = []
  await client.stream({ onEvent: event => events.push(event) })
  assert.match(urls[1]!, /after_seq=-1$/)
  assert(events.some(event => event.type === "tool_progress" && event.progress?.code?.text === "new()"))
})

test("canceling a chat lifetime aborts pending send and status requests", async () => {
  const controller = new AbortController()
  const client = createChatClient({ baseUrl: "http://localhost", agentId: "session", fetchImpl: async (_url, init) => {
    const signal = init?.signal
    assert(signal)
    return new Promise<Response>((_resolve, reject) => {
      signal.addEventListener("abort", () => reject(signal.reason), { once: true })
    })
  } })
  const sent = client.send("hello", controller.signal)
  const status = client.getStatus(controller.signal)
  controller.abort()
  await assert.rejects(sent, { name: "AbortError" })
  await assert.rejects(status, { name: "AbortError" })
})




test("send exposes a structured missing-workspace error", async () => {
  const client = createChatClient({ baseUrl: "http://localhost", agentId: "session", fetchImpl: async () =>
    new Response(JSON.stringify({ code: "workspace_missing", error: "workspace not found", workspace: "/gone" }), { status: 409, headers: { "content-type": "application/json" } }),
  })
  await assert.rejects(client.send("continue"), error => error instanceof WorkspaceMissingError && error.workspace === "/gone")
})

test("workspace replacement requires daemon capability and returns authoritative metadata", async () => {
  const requests: { url: string; body?: string }[] = []
  const client = createChatClient({ baseUrl: "http://localhost", agentId: "session", fetchImpl: async (input, init) => {
    requests.push({ url: String(input), ...(typeof init?.body === "string" ? { body: init.body } : {}) })
    if (String(input).endsWith("/health")) return Response.json({ capabilities: ["session_workspace"] })
    return Response.json({ workspace: "/actual/workspace", id: "session" })
  } })
  assert.deepEqual(await client.replaceWorkspace?.("/requested/workspace"), { workspace: "/actual/workspace" })
  assert.deepEqual(requests.map(request => request.url), ["http://localhost/health", "http://localhost/sessions/session/workspace"])
  assert.deepEqual(JSON.parse(requests[1]!.body!), { workspace: "/requested/workspace" })

  const old = createChatClient({ baseUrl: "http://localhost", agentId: "session", fetchImpl: async () => Response.json({ capabilities: [] }) })
  await assert.rejects(old.replaceWorkspace!("/new"), /daemon upgrade needed/)
})


test("send carries one bounded image attachment without changing auth or redirect handling", async () => {
  let request: RequestInit | undefined
  const client = createChatClient({ baseUrl: "http://localhost", agentId: "session", clientId: "sender", fetchImpl: async (_url, init) => {
    request = init
    return new Response("{}", { status: 200 })
  } })
  const image = { mimeType: "image/png" as const, data: "aGVsbG8=", width: 2, height: 3, bytes: 5 }
  await client.send("describe", undefined, image)
  assert.equal(request?.method, "POST")
  assert.deepEqual(JSON.parse(String(request?.body)), { content: "describe", image, clientId: "sender" })
})

test("user replay accepts bounded image metadata and drops payload-shaped or invalid metadata", async () => {
  const events: StreamEvent[] = []
  const frames = page(1, [
    { type: "user", text: "one", source: "chat", triggeredAt: "", image: { mimeType: "image/png", width: 2, height: 3, bytes: 5 } },
    { type: "user", text: "two", source: "chat", triggeredAt: "", image: { mimeType: "image/gif", width: 2, height: 3, bytes: 5, data: "secret" } },
  ])
  const client = createChatClient({ baseUrl: "http://localhost", agentId: "session", fetchImpl: async () => new Response(frames, { headers: { "content-type": "text/event-stream" } }) })
  await client.stream({ onEvent: event => events.push(event) })
  assert.deepEqual(events[0], { type: "user", text: "one", source: "chat", triggeredAt: "", image: { mimeType: "image/png", width: 2, height: 3, bytes: 5 } })
  assert.deepEqual(events[1], { type: "user", text: "two", source: "chat", triggeredAt: "" })
})
